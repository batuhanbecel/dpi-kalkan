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
            guard let server else { return }
            // Açık bağlantıları kesmemek için yalnızca port değişince yeni sunucuya geçilir.
            if oldValue.port != config.port { return restart() }
            server.update(config: config)
            if isRunning, systemWide,
               oldValue.onlyListedDomains != config.onlyListedDomains || oldValue.domains != config.domains {
                applySystemProxy()   // PAC içeriği değişti
            }
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
    /// Kapatılmış ama açık bağlantıları hâlâ süren sunucular; bağlantılar bitince bırakılır.
    private var retired: [ProxyServer] = []
    private var lastToggle = Date.distantPast
    /// Sistem proxy ayarını bu süreç mi yazdı; yalnızca o zaman geri alınır (başka örneğin ayarına dokunulmaz).
    private var systemProxyApplied = false
    /// PAC adresine eklenir; macOS önbelleğe aldığı eski PAC'i bırakıp yenisini okusun diye.
    private var pacVersion = Int(Date().timeIntervalSince1970)
    private let proxyQueue = DispatchQueue(label: "dpikalkan.systemproxy")

    /// `startProtection` false ise (ör. ikinci kez açılan örnek) proxy ve sistem ayarlarına hiç dokunulmaz.
    init(startProtection: Bool = true) {
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
        guard startProtection else { return }
        // Önceki oturum düzgün kapanmadıysa kalan sistem ayarlarını temizle.
        if autoStart { start() } else { proxyQueue.async { SystemProxy.disable() } }
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
        // Cam düğme tek basışı iki kez iletebiliyor; hemen ardından gelen ikinci geçişi yok say.
        guard Date().timeIntervalSince(lastToggle) > 0.4 else { return }
        lastToggle = Date()
        enabled ? start() : stop()
    }

    func start() {
        guard server == nil else { return }
        lastError = nil
        let server = ProxyServer(config: config)
        server.onStateChange = { [weak self, weak server] running, error in
            Task { @MainActor in
                guard let self, let server, self.server === server else { return }
                self.isRunning = running
                if running, self.systemWide { self.applySystemProxy() }
                if let error {
                    self.lastError = error
                    self.server = nil
                    self.removeSystemProxy()
                }
            }
        }
        server.onStats = { [weak self, weak server] s in
            Task { @MainActor in
                guard let self, let server, self.server === server else { return }
                self.stats = s
            }
        }
        server.onLog = { [weak self] line in Task { @MainActor in self?.appendLog(line) } }
        server.onDrained = { [weak self, weak server] in
            Task { @MainActor in self?.retired.removeAll { $0 === server } }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Korumayı kapatır. Sistem ayarı hemen kalkar, yeni bağlantılar doğrudan gider; açık bağlantılar
    /// (ör. bir indirme ya da sohbet akışı) kesilmeden kendi bitene kadar sürer.
    func stop() {
        removeSystemProxy()
        retire()
        isRunning = false
        stats.active = 0
    }

    private func retire() {
        guard let server else { return }
        self.server = nil
        retired.append(server)
        server.drain()
    }

    /// Çıkmadan önce: sistem ayarını kaldırır ve açık bağlantılara en fazla iki saniye bitme süresi tanır.
    func prepareToQuit() async {
        if systemProxyApplied {
            systemProxyApplied = false
            await withCheckedContinuation { done in
                proxyQueue.async { SystemProxy.disable(); done.resume() }
            }
        }
        retire()
        isRunning = false
        let deadline = Date().addingTimeInterval(2)
        while !retired.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Uygulama kapanırken: sistem ayarları geri alınmadan çıkılmasın diye eşzamanlı.
    func shutdown() {
        server?.stop()
        server = nil
        retired.forEach { $0.stop() }
        retired.removeAll()
        if systemProxyApplied {
            systemProxyApplied = false
            proxyQueue.sync { SystemProxy.disable() }
        }
    }

    private func restart() {
        retire()
        // Sistem proxy'si yerinde kalır; yeni sunucu hazır olunca yeni porta göre yenilenir.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            start()
        }
    }

    private func applySystemProxy() {
        systemProxyApplied = true
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
        guard systemProxyApplied else { return }
        systemProxyApplied = false
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
