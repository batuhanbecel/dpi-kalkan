import AppKit
import SwiftUI

@main
struct DPIKalkanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model, updater: delegate.updater)
        } label: {
            Image(nsImage: MenuBarIcon.image(active: delegate.model.isRunning))
                .accessibilityLabel(delegate.model.isRunning ? "DPI Kalkan açık" : "DPI Kalkan kapalı")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: delegate.model, updater: delegate.updater)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let updater = Updater()
    /// Aynı uygulama zaten çalışıyor; bu örnek hiçbir şeye dokunmadan kapanır.
    private let isDuplicate: Bool
    private var termSource: DispatchSourceSignal?

    override init() {
        let id = Bundle.main.bundleIdentifier ?? ""
        isDuplicate = !id.isEmpty && NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0 != NSRunningApplication.current }
        model = AppModel(startProtection: !isDuplicate)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isDuplicate else { return NSApp.requestTermination() }
        updater.schedule()

        // `kill` ve oturum kapanışı da sistem proxy'sini geri alan normal çıkıştan geçsin.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.requestTermination() }
        source.resume()
        termSource = source

        #if DEBUG
        // Geliştirme: `--update-now` güncelleme akışını arayüzsüz uçtan uca dener.
        if CommandLine.arguments.contains("--update-now") {
            Task {
                await updater.check()
                await updater.install()
            }
        }
        // Geliştirme: `DPIKalkan --preview` menü içeriğini sıradan bir pencerede gösterir (ekran görüntüsü için).
        if CommandLine.arguments.contains("--preview") {
            NSApp.setActivationPolicy(.regular)
            let window = NSWindow(contentViewController: NSHostingController(rootView: MenuContent(model: model, updater: updater)))
            window.title = "Menü önizleme"
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            previewWindow = window
        }
        #endif
    }

    #if DEBUG
    private var previewWindow: NSWindow?
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.prepareToQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

extension NSApplication {
    /// Çıkışı ana kuyruk işlerinin dışından, run loop üzerinden başlatır. `applicationShouldTerminate`
    /// `.terminateLater` döndürdüğü için AppKit çıkışı beklerken iç içe bir olay döngüsü açar; `terminate`
    /// bir Task ya da GCD bloğu içinden çağrılırsa çıkış hazırlığı ana kuyrukta sıra bekler ve uygulama kilitlenir.
    func requestTermination() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }
}

/// Menü çubuğundaki kalkan simgesi ve "DPI" yazısı. Şablon görüntü olduğu için açık/koyu menü
/// çubuğuna uyar; kapalıyken kalkan üstü çizili ve soluk görünür.
enum MenuBarIcon {
    static func image(active: Bool) -> NSImage {
        let alpha: CGFloat = active ? 1 : 0.45
        let symbol = NSImage(systemSymbolName: active ? "shield.lefthalf.filled" : "shield.slash",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold)) ?? NSImage()
        let text = NSAttributedString(string: "DPI", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .bold),
            .foregroundColor: NSColor.black.withAlphaComponent(alpha),
            .kern: 0.3,
        ])
        let textSize = text.size()
        let gap: CGFloat = 3
        let height: CGFloat = 17
        let width = ceil(symbol.size.width + gap + textSize.width)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let symbolRect = NSRect(x: 0, y: (rect.height - symbol.size.height) / 2,
                                    width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: alpha)
            text.draw(at: NSPoint(x: symbol.size.width + gap, y: (rect.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }
}
