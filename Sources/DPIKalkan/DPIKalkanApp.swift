import AppKit
import SwiftUI

@main
struct DPIKalkanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            Image(nsImage: MenuBarIcon.image(active: delegate.model.isRunning))
                .accessibilityLabel(delegate.model.isRunning ? "DPI Kalkan açık" : "DPI Kalkan kapalı")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill` ve oturum kapanışı da sistem proxy'sini geri alan normal çıkıştan geçsin.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source

        #if DEBUG
        // Geliştirme: `DPIKalkan --preview` menü içeriğini sıradan bir pencerede gösterir (ekran görüntüsü için).
        if CommandLine.arguments.contains("--preview") {
            NSApp.setActivationPolicy(.regular)
            let window = NSWindow(contentViewController: NSHostingController(rootView: MenuContent(model: model)))
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
