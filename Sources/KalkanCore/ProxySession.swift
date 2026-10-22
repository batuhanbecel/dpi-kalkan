import Foundation
import Network

/// Tek bir istemci bağlantısı: isteği okur, hedefe bağlanır, iki yönlü aktarır.
final class ProxySession: @unchecked Sendable {
    var onFragmented: ((String) -> Void)?
    var onFinish: ((String?) -> Void)?
    var onLog: ((String) -> Void)?

    private let client: NWConnection
    private var upstream: NWConnection?
    private let config: ProxyConfig
    private let resolver: DoHResolver
    private let strategies: StrategyCache
    private let queue = DispatchQueue(label: "dpikalkan.session")
    private var finished = false
    private var openDirections = 2
    private var target = "?"
    private var bytesUp = 0
    private var bytesDown = 0
    private var closeReason = ""

    private static let maxHeader = 32 * 1024
    private static let maxFirstFlight = 16 * 1024
    /// Bölünmüş ClientHello'ya bu süre içinde yanıt gelmezse sonraki yöntem denenir.
    private static let helloTimeout: DispatchTimeInterval = .seconds(5)

    init(client: NWConnection, config: ProxyConfig, resolver: DoHResolver, strategies: StrategyCache) {
        self.client = client
        self.config = config
        self.resolver = resolver
        self.strategies = strategies
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish(nil) }
        }
        client.start(queue: queue)
        readHeader(Data())
    }

    func close() {
        queue.async { self.finish(nil) }
    }

    // MARK: İstek başlığı

    private func readHeader(_ buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { return self.finish("İstemci okuma hatası: \(error.localizedDescription)") }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = buf[..<end.lowerBound]
                let rest = buf[end.upperBound...]
                self.handleRequest(head: String(decoding: head, as: UTF8.self), rest: Data(rest))
            } else if isComplete || buf.count > Self.maxHeader {
                self.finish(nil)
            } else {
                self.readHeader(buf)
            }
        }
    }

    private func handleRequest(head: String, rest: Data) {
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return reject("400 Bad Request") }
        let (method, target, version) = (parts[0], parts[1], parts[2])
        self.target = "\(method) \(target)"

        // Proxy'ye değil doğrudan sunucuya gelen istek: sistemin okuduğu PAC dosyası.
        if target.hasPrefix("/") {
            guard target.hasPrefix(PACScript.path) else { return reject("404 Not Found") }
            return respond(body: PACScript.make(config: config), contentType: "application/x-ns-proxy-autoconfig")
        }

        if method.uppercased() == "CONNECT" {
            guard let (host, port) = Self.splitHostPort(target, defaultPort: 443) else { return reject("400 Bad Request") }
            connectUpstream(host: host, port: port, onReady: { [weak self] in
                guard let self else { return }
                self.client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                self.readFirstFlight(rest, host: host, port: port)
            }, onFail: { [weak self] error in
                self?.reject("502 Bad Gateway")
                self?.onFinish?(error)
                self?.onFinish = nil
            })
            return
        }

        // Düz HTTP: mutlak URI'yi yol biçimine çevir, tek istek sonrası kapat.
        guard let url = URL(string: target), let host = url.host else { return reject("400 Bad Request") }
        let port = url.port ?? 80
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        lines[0] = "\(method) \(path) \(version)"
        lines.removeAll { line in
            let l = line.lowercased()
            return l.hasPrefix("proxy-connection:") || l.hasPrefix("connection:") || l.hasPrefix("keep-alive:")
        }
        lines.append("Connection: close")
        let request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + rest

        connectUpstream(host: host, port: UInt16(port), onReady: { [weak self] in
            guard let self, let upstream = self.upstream else { return }
            upstream.send(content: request, completion: .contentProcessed { _ in })
            self.startPiping()
        }, onFail: { [weak self] error in
            self?.reject("502 Bad Gateway")
            self?.onFinish?(error)
            self?.onFinish = nil
        })
    }

    private func reject(_ status: String) {
        client.send(content: Data("HTTP/1.1 \(status)\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in
            self?.finish(nil)
        })
    }

    private func respond(body: String, contentType: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(payload.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        client.send(content: Data(head.utf8) + payload, completion: .contentProcessed { [weak self] _ in
            self?.finish(nil)
        })
    }

    // MARK: Hedef bağlantısı

    /// Hedefe her zaman IP adresiyle bağlanır. Network.framework ad ile kurulan bağlantılarda sistem PAC'ini
    /// uyguluyor (`preferNoProxies` buna rağmen); PAC IP adreslerine DIRECT döndüğü için böylece kendi
    /// bağlantılarımız sistem geneli kipte proxy'ye geri dönmez.
    private func connectUpstream(host: String, port: UInt16, onReady: @escaping () -> Void, onFail: @escaping (String) -> Void) {
        let label = "\(host):\(port)"
        if config.useDoH {
            resolver.resolve(host) { [weak self] ip in
                self?.queue.async {
                    guard let ip else { return onFail("DoH çözülemedi: \(host)") }
                    self?.open([ip], port: port, label: label, lastError: nil, onReady: onReady, onFail: onFail)
                }
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let addresses = Self.lookup(host)
                self?.queue.async {
                    self?.open(addresses, port: port, label: label, lastError: "ad çözülemedi", onReady: onReady, onFail: onFail)
                }
            }
        }
    }

    /// Adresleri sırayla dener; biri bağlanınca `onReady`, hepsi başarısızsa `onFail`.
    private func open(_ addresses: [String], port: UInt16, label: String, lastError: String?,
                      onReady: @escaping () -> Void, onFail: @escaping (String) -> Void) {
        guard !finished else { return }
        guard let address = addresses.first else {
            return onFail("\(label) bağlanamadı: \(lastError ?? "adres yok")")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        let params = NWParameters(tls: nil, tcp: tcp)
        params.preferNoProxies = true
        let conn = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!, using: params)
        upstream = conn
        var didReady = false
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready where !didReady:
                didReady = true
                onReady()
            case .waiting(let error), .failed(let error):
                if !didReady {
                    didReady = true
                    conn.cancel()
                    self.open(Array(addresses.dropFirst()), port: port, label: label,
                              lastError: error.localizedDescription, onReady: onReady, onFail: onFail)
                } else if conn === self.upstream {
                    self.finish(nil)
                }
            default: break
            }
        }
        conn.start(queue: queue)
    }

    /// Sistem çözücüsüyle (getaddrinfo) adresleri, sistemin tercih sırasıyla döndürür.
    static func lookup(_ host: String) -> [String] {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1 { return [host] }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var result: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let ai = node?.pointee {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.ai_addr, ai.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: buf)
                if !result.contains(s) { result.append(s) }
            }
            node = ai.ai_next
        }
        return result
    }

    // MARK: İlk TLS paketi

    private func readFirstFlight(_ buffer: Data, host: String, port: UInt16) {
        let bytes = [UInt8](buffer)
        switch TLSFragmenter.parse(bytes) {
        case .needMoreData where bytes.count < Self.maxFirstFlight:
            client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if error != nil || (isComplete && (data?.isEmpty ?? true)) { return self.finish(nil) }
                self.readFirstFlight(buffer + (data ?? Data()), host: host, port: port)
            }
        case .clientHello(let info) where shouldFragment(host: host, sni: info.serverName):
            if let dir = ProcessInfo.processInfo.environment["KALKAN_DUMP_DIR"] {
                let name = "\(dir)/hello-\(info.serverName ?? host)-\(Int(Date().timeIntervalSince1970 * 1000)).bin"
                try? Data(bytes).write(to: URL(fileURLWithPath: name))
            }
            let key = (info.serverName ?? host).lowercased()
            let attempts = strategies.order(for: key, preferred: config.mode)
            sendHello(bytes, info: info, key: key, attempts: attempts, host: host, port: port)
        default:
            if buffer.isEmpty { return startPiping() }
            upstream?.send(content: buffer, completion: .contentProcessed { [weak self] _ in self?.startPiping() })
        }
    }

    private func shouldFragment(host: String, sni: String?) -> Bool {
        guard config.onlyListedDomains else { return true }
        return DomainList.matches(host, in: config.domains)
            || sni.map { DomainList.matches($0, in: config.domains) } == true
    }

    /// ClientHello'yu `attempts[0]` yöntemiyle böler. Sunucu yanıt vermeden kapatırsa (DPI sıfırlaması ya da
    /// TLS kayıt bölmeyi kabul etmeyen sunucu) aynı hello'yu yeni bağlantıda sıradaki yöntemle yeniden gönderir.
    private func sendHello(_ bytes: [UInt8], info: ClientHelloInfo, key: String, attempts: [FragmentMode], host: String, port: UInt16) {
        guard let mode = attempts.first, let conn = upstream else { return finish(nil) }
        let remaining = Array(attempts.dropFirst())
        let pieces = TLSFragmenter.fragment(bytes, info: info, mode: mode).map { Data($0) }

        let retry: () -> Void = { [weak self] in
            guard let self, !self.finished else { return }
            conn.cancel()
            guard !remaining.isEmpty else {
                self.closeReason += "[\(mode.rawValue) başarısız]"
                return self.finish("\(key): hiçbir yöntem işe yaramadı")
            }
            self.onLog?("\(key): \(mode.rawValue) yanıtsız kaldı, \(remaining[0].rawValue) deneniyor")
            self.connectUpstream(host: host, port: port, onReady: { [weak self] in
                self?.sendHello(bytes, info: info, key: key, attempts: remaining, host: host, port: port)
            }, onFail: { [weak self] error in
                self?.finish(error)
            })
        }

        sendSequentially(pieces) { [weak self] in
            guard let self else { return }
            var settled = false
            let timeout = DispatchWorkItem { if !settled { settled = true; retry() } }
            self.queue.asyncAfter(deadline: .now() + Self.helloTimeout, execute: timeout)

            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
                guard let self, !settled else { return }
                settled = true
                timeout.cancel()
                guard let data, !data.isEmpty,
                      data.first != 0x15 || remaining.isEmpty   // TLS uyarısı: sıradaki yöntem varsa onu dene
                else { return retry() }

                self.strategies.remember(mode, for: key)
                self.onFragmented?(key)
                self.bytesDown += data.count
                self.client.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil { return self.finish(nil) }
                    self.pipe(from: self.client, to: conn)
                    if isComplete { self.halfClose(self.client) } else { self.pipe(from: conn, to: self.client) }
                })
            }
        }
    }

    private func sendSequentially(_ pieces: [Data], then done: @escaping () -> Void) {
        guard let first = pieces.first, let upstream else { return done() }
        upstream.send(content: first, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            // Gönderim hatası da "yanıtsız" sayılır; ardından gelen receive başarısız olup yeniden denemeyi tetikler.
            let remaining = Array(pieces.dropFirst())
            if remaining.isEmpty || error != nil { return done() }
            self.queue.asyncAfter(deadline: .now() + .milliseconds(self.config.delayMs)) {
                self.sendSequentially(remaining, then: done)
            }
        })
    }

    // MARK: Aktarım

    private func startPiping() {
        guard let upstream else { return finish(nil) }
        pipe(from: client, to: upstream)
        pipe(from: upstream, to: client)
    }

    private func pipe(from source: NWConnection, to dest: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                if source === self.client { self.bytesUp += data.count } else { self.bytesDown += data.count }
                dest.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError != nil { return self.finish(nil) }
                    if isComplete { self.halfClose(dest) } else { self.pipe(from: source, to: dest) }
                })
            } else if isComplete || error != nil {
                if let error { self.closeReason += "[\(source === self.client ? "istemci" : "sunucu") hata: \(error)]" }
                else { self.closeReason += "[\(source === self.client ? "istemci" : "sunucu") kapattı]" }
                self.halfClose(dest)
            } else {
                self.pipe(from: source, to: dest)
            }
        }
    }

    private func halfClose(_ dest: NWConnection) {
        dest.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        openDirections -= 1
        if openDirections <= 0 { return finish(nil) }
        // Karşı taraf yarım kapalı bağlantıyı hiç kapatmazsa oturum (ve soketler) birikmesin.
        queue.asyncAfter(deadline: .now() + .seconds(60)) { [weak self] in self?.finish(nil) }
    }

    private func finish(_ error: String?) {
        guard !finished else { return }
        finished = true
        client.cancel()
        upstream?.cancel()
        if config.verbose {
            onLog?("\(target) ↑\(bytesUp) ↓\(bytesDown) \(closeReason)")
        }
        onFinish?(error)
        onFinish = nil
    }

    // MARK: Yardımcılar

    static func splitHostPort(_ s: String, defaultPort: UInt16) -> (String, UInt16)? {
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            let port = after.hasPrefix(":") ? UInt16(after.dropFirst()) : defaultPort
            return port.map { (host, $0) }
        }
        let parts = s.split(separator: ":")
        switch parts.count {
        case 1: return (String(parts[0]), defaultPort)
        case 2: return UInt16(parts[1]).map { (String(parts[0]), $0) }
        default: return nil
        }
    }
}
