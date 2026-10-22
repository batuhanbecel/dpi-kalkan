import AppKit
import KalkanCore
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppModel {
    enum TestState: Equatable {
        case idle, running, ok(String), failed(String)
    }

    private(set) var isRunning = false
    private(set) var stats = ProxyStats()
    private(set) var logs: [String] = []
    private(set) var lastError: String?
    var testState: TestState = .idle

    var config: ProxyConfig {
        didSet {
            guard oldValue != config else { return }
            saveConfig()
            if server != nil { restart() }
        }
    }

    var autoStart: Bool {
        didSet { UserDefaults.standard.set(autoStart, forKey: "autoStart") }
    }

    var systemWide: Bool {
        didSet {
            UserDefaults.standard.set(systemWide, forKey: "systemWide")
            guard isRunning else { return }
            if systemWide { applySystemProxy() } else { removeSystemProxy() }
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Oturum açılışı ayarlanamadı: \(error.localizedDescription)"
            }
        }
    }

    /// Menüde gösterilen tek satırlık durum.
    var statusDetail: String? {
        if let lastError { return lastError }
        guard isRunning else { return nil }
        let scope = config.onlyListedDomains ? "\(config.domains.count) site" : "Tüm siteler"
        return stats.active > 0 ? "\(scope) · \(stats.active) bağlantı" : scope
    }

    private var server: ProxyServer?
    /// PAC adresine eklenir; macOS önbelleğe aldığı eski PAC'i bırakıp yenisini okusun diye.
    private var pacVersion = Int(Date().timeIntervalSince1970)
    private let proxyQueue = DispatchQueue(label: "dpikalkan.systemproxy")

    init() {
        let d = UserDefaults.standard
        var c = ProxyConfig()
        if let p = d.object(forKey: "port") as? Int, let port = UInt16(exactly: p) { c.port = port }
        // Eski "mode" anahtarı kayıt başı bölme yokken kaydedildi; yeni varsayılan geçerli olsun diye okunmuyor.
        if let m = d.string(forKey: "fragmentMode").flatMap(FragmentMode.init(rawValue:)) { c.mode = m }
        if let ms = d.object(forKey: "delayMs") as? Int { c.delayMs = ms }
        // "onlyListed" eski sürümde varsayılan olarak açıktı; yeni sürümde tüm siteler varsayılan.
        if d.object(forKey: "scopeListed") != nil { c.onlyListedDomains = d.bool(forKey: "scopeListed") }
        if let list = d.stringArray(forKey: "domains"), !list.isEmpty { c.domains = list }
        config = c
        autoStart = d.object(forKey: "autoStart") as? Bool ?? true
        systemWide = d.object(forKey: "systemWide") as? Bool ?? true
        // Önceki oturum düzgün kapanmadıysa kalan sistem ayarlarını temizle.
        if autoStart { start() } else { removeSystemProxy() }
    }

    private func saveConfig() {
        let d = UserDefaults.standard
        d.set(Int(config.port), forKey: "port")
        d.set(config.mode.rawValue, forKey: "fragmentMode")
        d.set(config.delayMs, forKey: "delayMs")
        d.set(config.onlyListedDomains, forKey: "scopeListed")
        d.set(config.domains, forKey: "domains")
    }

    // MARK: Koruma

    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    func start() {
        guard server == nil else { return }
        lastError = nil
        let server = ProxyServer(config: config)
        server.onStateChange = { [weak self] running, error in
            Task { @MainActor in
                guard let self, self.server === server else { return }
                self.isRunning = running
                if running, self.systemWide { self.applySystemProxy() }
                if let error {
                    self.lastError = error
                    self.server = nil
                    self.removeSystemProxy()
                }
            }
        }
        server.onStats = { [weak self] s in Task { @MainActor in self?.stats = s } }
        server.onLog = { [weak self] line in Task { @MainActor in self?.appendLog(line) } }
        do {
            try server.start()
            self.server = server
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        removeSystemProxy()
        server?.stop()
        server = nil
        isRunning = false
        stats.active = 0
    }

    /// Uygulama kapanırken: sistem ayarları geri alınmadan çıkılmasın diye eşzamanlı.
    func shutdown() {
        server?.stop()
        server = nil
        proxyQueue.sync { SystemProxy.disable() }
    }

    private func restart() {
        server?.stop()
        server = nil
        // Dinleyicinin portu bırakması için kısa bekleme. Sistem proxy'si yerinde kalır, hazır olunca yenilenir.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            start()
        }
    }

    private func applySystemProxy() {
        pacVersion += 1
        let (port, version) = (config.port, pacVersion)
        proxyQueue.async {
            do {
                try SystemProxy.enable(port: port, version: version)
            } catch {
                Task { @MainActor in self.lastError = error.localizedDescription }
            }
        }
    }

    private func removeSystemProxy() {
        proxyQueue.async { SystemProxy.disable() }
    }

    // MARK: Siteler

    func addDomain(_ input: String) {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        s = String(s.prefix { $0 != "/" && $0 != ":" })
        if s.hasPrefix("*.") { s.removeFirst(2) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        guard s.contains("."), !config.domains.contains(s) else { return }
        config.domains.append(s)
    }

    func removeDomain(_ domain: String) {
        config.domains.removeAll { $0 == domain }
    }

    func resetDomains() {
        config.domains = DomainList.defaults
    }

    // MARK: Etkinlik

    private func appendLog(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        logs.append("\(stamp)  \(line)")
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    func clearLogs() {
        logs.removeAll()
    }

    /// Proxy üzerinden siteye istek atar; herhangi bir HTTP yanıtı erişim sayılır.
    func testConnection(host input: String) {
        let host = input.trimmingCharacters(in: .whitespaces).isEmpty ? "discord.com" : input
        let urlString = host.contains("://") ? host : "https://\(host)"
        guard let url = URL(string: urlString), url.host != nil else {
            testState = .failed("Geçersiz adres")
            return
        }
        testState = .running
        let port = Int(config.port)
        Task {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 12
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: "127.0.0.1",
                kCFNetworkProxiesHTTPPort: port,
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort: port,
            ]
            let session = URLSession(configuration: cfg)
            defer { session.invalidateAndCancel() }
            do {
                let start = Date()
                _ = try await session.data(from: url)
                testState = .ok("Erişilebilir · \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            } catch {
                testState = .failed("Erişilemedi")
            }
        }
    }
}
