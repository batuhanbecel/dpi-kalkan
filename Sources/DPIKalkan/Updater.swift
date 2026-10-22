import AppKit
import KalkanCore
import Observation
import Security

/// GitHub sürümlerinden yeni sürümü denetler; istenirse indirir, imzasını doğrular,
/// uygulamayı yerinde değiştirir ve yeniden başlatır.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle, checking, upToDate, installing
        case available(ReleaseInfo)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastCheck: Date?
    /// Kurulum başarısız olursa kullanıcıya sürüm sayfası gösterilir.
    private(set) var fallbackPage: URL?

    var automatic: Bool {
        didSet {
            UserDefaults.standard.set(automatic, forKey: "autoUpdateCheck")
            schedule()
        }
    }

    var available: ReleaseInfo? {
        if case .available(let release) = state { return release }
        return nil
    }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private var timer: Timer?
    private static let interval: TimeInterval = 6 * 3600

    init() {
        automatic = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true
        lastCheck = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date
    }

    /// Açılıştan kısa süre sonra, ardından altı saatte bir sessizce denetler.
    func schedule() {
        timer?.invalidate()
        timer = nil
        guard automatic else { return }
        let due = max(10, Self.interval - Date().timeIntervalSince(lastCheck ?? .distantPast))
        timer = Timer.scheduledTimer(withTimeInterval: due, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.check(userInitiated: false)
                self?.schedule()
            }
        }
    }

    func check(userInitiated: Bool = true) async {
        switch state {
        case .checking, .installing: return
        default: break
        }
        state = .checking
        var request = URLRequest(url: UpdateFeed.latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DPIKalkan/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let release = UpdateFeed.parse(data) else {
                throw UpdateError("Sürüm bilgisi alınamadı")
            }
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: "lastUpdateCheck")
            state = UpdateFeed.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
        } catch {
            // Arka plandaki denetim hatası menüde gürültü yapmasın.
            state = userInitiated ? .failed("Güncellemeler denetlenemedi") : .idle
        }
    }

    func install() async {
        guard let release = available else { return }
        guard let asset = release.assetURL else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        state = .installing
        fallbackPage = nil
        do {
            let target = Bundle.main.bundleURL
            let newApp = try await download(asset)
            try verify(newApp, replacing: target)
            do {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: newApp)
            } catch {
                throw UpdateError("Uygulama klasörüne yazılamadı")
            }
            relaunch(target)
        } catch {
            fallbackPage = release.pageURL
            state = .failed((error as? UpdateError)?.message ?? "Güncelleme indirilemedi")
        }
    }

    // MARK: Adımlar

    private func download(_ url: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Güncelleme indirilemedi") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DPIKalkanUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: file, to: zip)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, dir.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0,
              let app = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" })
        else { throw UpdateError("Arşiv açılamadı") }
        return app
    }

    /// İmza geçerli olmalı; çalışan uygulama bir geliştirici kimliğiyle imzalıysa yeni sürüm de aynı ekipten olmalı.
    private func verify(_ newApp: URL, replacing current: URL) throws {
        guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("İndirilen uygulama tanınmadı")
        }
        let newTeam = try signingTeam(of: newApp, validate: true)
        if let currentTeam = try? signingTeam(of: current, validate: false), currentTeam != newTeam {
            throw UpdateError("İmza eşleşmiyor")
        }
    }

    private func signingTeam(of url: URL, validate: Bool) throws -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("İmza okunamadı")
        }
        if validate {
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
            guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { throw UpdateError("İmza geçersiz") }
        }
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Bu süreç kapanınca yeni sürümü açan küçük bir kabuk bırakır, sonra normal çıkışı başlatır.
    private func relaunch(_ app: URL) {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                           "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try? shell.run()
        NSApp.requestTermination()
    }
}

private struct UpdateError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
