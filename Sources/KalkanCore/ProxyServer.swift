import Foundation
import Network

public struct ProxyConfig: Equatable, Sendable {
    public var port: UInt16 = 8881
    public var mode: FragmentMode = .recordHeader
    /// İki parça arasındaki bekleme (ms). DPI'nin parçaları birleştirmemesi için.
    public var delayMs: Int = 10
    /// Açıksa yalnızca `domains` listesindeki siteler proxy'den geçer ve bölünür; kapalıysa tüm siteler.
    public var onlyListedDomains: Bool = false
    public var domains: [String] = DomainList.defaults
    public var useDoH: Bool = false
    /// Her oturum kapanışında hedef ve aktarılan bayt sayısını kaydeder.
    public var verbose: Bool = false

    public init() {}
}

public struct ProxyStats: Equatable, Sendable {
    public var active = 0
    public var total = 0
    public var fragmented = 0
    public var failed = 0

    public init() {}
}

/// 127.0.0.1 üzerinde çalışan HTTP proxy (CONNECT + düz HTTP).
/// Tünelin ilk TLS paketini (ClientHello) bölerek SNI tabanlı engeli aşar.
public final class ProxyServer: @unchecked Sendable {
    public let config: ProxyConfig
    public var onStats: ((ProxyStats) -> Void)?
    public var onLog: ((String) -> Void)?
    public var onStateChange: ((Bool, String?) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dpikalkan.listener")
    private let resolver = DoHResolver()
    private let strategies = StrategyCache()
    private var stats = ProxyStats()
    private var sessions: [ObjectIdentifier: ProxySession] = [:]

    public init(config: ProxyConfig) {
        self.config = config
    }

    public func start() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: config.port)!)

        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onStateChange?(true, nil)
                self?.log("Proxy 127.0.0.1:\(self?.config.port ?? 0) üzerinde dinliyor")
            case .failed(let error):
                self?.onStateChange?(false, error.localizedDescription)
                self?.log("Proxy hatası: \(error.localizedDescription)")
                self?.stop()
            case .cancelled:
                self?.onStateChange?(false, nil)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            sessions.values.forEach { $0.close() }
            sessions.removeAll()
        }
    }

    private func accept(_ conn: NWConnection) {
        let session = ProxySession(client: conn, config: config, resolver: resolver, strategies: strategies)
        let id = ObjectIdentifier(session)
        sessions[id] = session
        updateStats { $0.active += 1; $0.total += 1 }

        session.onFragmented = { [weak self] _ in
            self?.queue.async { self?.updateStats { $0.fragmented += 1 } }
        }
        session.onLog = { [weak self] line in self?.queue.async { self?.log(line) } }
        session.onFinish = { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.sessions[id] = nil
                self.updateStats {
                    $0.active -= 1
                    if error != nil { $0.failed += 1 }
                }
                if let error { self.log(error) }
            }
        }
        session.start()
    }

    private func updateStats(_ change: (inout ProxyStats) -> Void) {
        change(&stats)
        let snapshot = stats
        onStats?(snapshot)
    }

    private func log(_ message: String) {
        onLog?(message)
    }
}
