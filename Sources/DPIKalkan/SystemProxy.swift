import Foundation
import KalkanCore

/// Proxy'yi sistem geneline uygular:
/// - Tarayıcılar ve Electron uygulamaları için her ağ hizmetine PAC adresi yazılır (`networksetup`).
///   PAC "PROXY …; DIRECT" döndürdüğü için uygulama kapanırsa bağlantılar doğrudan devam eder.
/// - Sistem proxy'sini okumayan uygulamalar (Discord güncelleyicisi, terminal araçları) için
///   launchd ortam değişkenleri ayarlanır; bunlar yalnızca sonradan açılan uygulamalara geçer.
enum SystemProxy {
    private static let envKeys = ["HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"]
    private static let networksetup = "/usr/sbin/networksetup"
    private static let launchctl = "/bin/launchctl"
    /// Kullanıcının bizden önceki PAC adresleri; kapatırken geri yüklenir.
    private static let savedKey = "previousAutoProxyURLs"

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func enable(port: UInt16, version: Int) throws {
        let pac = PACScript.url(port: port, version: version)
        var saved = UserDefaults.standard.dictionary(forKey: savedKey) as? [String: String] ?? [:]
        var applied = 0
        for service in services() {
            if let current = autoProxyURL(service), !isOurs(current) { saved[service] = current }
            if run(networksetup, "-setautoproxyurl", service, pac) != nil { applied += 1 }
        }
        UserDefaults.standard.set(saved, forKey: savedKey)
        guard applied > 0 else { throw Failure(errorDescription: "Sistem proxy ayarı yazılamadı") }

        let proxy = "http://127.0.0.1:\(port)"
        for key in envKeys { run(launchctl, "setenv", key, proxy) }
        run(launchctl, "setenv", "NO_PROXY", "localhost,127.0.0.1,::1")
    }

    static func disable() {
        let saved = UserDefaults.standard.dictionary(forKey: savedKey) as? [String: String] ?? [:]
        for service in services() {
            guard let current = autoProxyURL(service), isOurs(current) else { continue }
            if let previous = saved[service] {
                run(networksetup, "-setautoproxyurl", service, previous)
            } else {
                run(networksetup, "-setautoproxystate", service, "off")
            }
        }
        UserDefaults.standard.removeObject(forKey: savedKey)

        for key in envKeys + ["NO_PROXY"] {
            let value = run(launchctl, "getenv", key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if key == "NO_PROXY" || value.hasPrefix("http://127.0.0.1:") { run(launchctl, "unsetenv", key) }
        }
    }

    // MARK: Yardımcılar

    private static func isOurs(_ url: String) -> Bool {
        url.hasPrefix("http://127.0.0.1:") && url.contains(PACScript.path)
    }

    /// Etkin ağ hizmetleri (Wi-Fi, Ethernet, …). Devre dışı olanlar `*` ile başlar.
    private static func services() -> [String] {
        guard let out = run(networksetup, "-listallnetworkservices") else { return [] }
        return out.split(separator: "\n").dropFirst().map(String.init).filter { !$0.hasPrefix("*") }
    }

    /// Etkin bir PAC adresi varsa döndürür.
    private static func autoProxyURL(_ service: String) -> String? {
        guard let out = run(networksetup, "-getautoproxyurl", service) else { return nil }
        var url: String?, enabled = false
        for line in out.split(separator: "\n") {
            if line.hasPrefix("URL: ") { url = String(line.dropFirst(5)) }
            if line.hasPrefix("Enabled: ") { enabled = line.hasSuffix("Yes") }
        }
        guard enabled, let url, url != "(null)" else { return nil }
        return url
    }

    /// Komutu çalıştırır; başarılıysa çıktısını, değilse nil döndürür.
    @discardableResult
    private static func run(_ tool: String, _ args: String...) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let out = String(decoding: data, as: UTF8.self)
        // networksetup hata durumunda da 0 dönebiliyor; hatayı metinden yakala.
        return out.hasPrefix("** Error") ? nil : out
    }
}
