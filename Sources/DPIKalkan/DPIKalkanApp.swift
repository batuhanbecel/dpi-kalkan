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
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

/// Menü çubuğundaki "DPI" yazısı. Şablon görüntü olduğu için açık/koyu menü çubuğuna uyar;
/// kapalıyken saydamlaşır.
enum MenuBarIcon {
    static func image(active: Bool) -> NSImage {
        let text = NSAttributedString(string: "DPI", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .bold),
            .foregroundColor: NSColor.black.withAlphaComponent(active ? 1 : 0.35),
            .kern: 0.4,
        ])
        let size = text.size()
        let image = NSImage(size: NSSize(width: ceil(size.width), height: 16), flipped: false) { rect in
            text.draw(at: NSPoint(x: 0, y: (rect.height - size.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }
}
