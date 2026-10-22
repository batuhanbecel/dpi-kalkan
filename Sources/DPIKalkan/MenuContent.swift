import AppKit
import SwiftUI

/// Menü çubuğu penceresi: Wi-Fi menüsündeki gibi başlıkta anahtar, altında durum ve birkaç satır.
struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("DPI Kalkan")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("Koruma", isOn: Binding(get: { model.isRunning }, set: { model.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 6)

            MenuSeparator()

            status
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

            MenuSeparator()

            MenuSectionHeader("Kapsam")
            MenuRow("Tüm siteler", checked: !model.config.onlyListedDomains) {
                model.config.onlyListedDomains = false
            }
            MenuRow("Yalnızca listedekiler", checked: model.config.onlyListedDomains) {
                model.config.onlyListedDomains = true
            }

            MenuSeparator()

            MenuRow("Ayarlar…", shortcut: "⌘,") { showSettings() }
                .keyboardShortcut(",")
            MenuRow("Çık", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.vertical, 6)
        .frame(width: 260)
    }

    private var status: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isRunning ? "checkmark.shield.fill" : "shield.slash.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.isRunning ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .background(Circle().fill(model.isRunning ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.isRunning ? "Koruma açık" : "Koruma kapalı")
                    .font(.system(size: 13))
                if let detail = model.statusDetail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(model.lastError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .lineLimit(1)
                }
            }
        }
    }

    private func showSettings() {
        openSettings()
        // Menü çubuğu uygulaması etkin olmadığından pencere arkada açılabiliyor; öne getir.
        DispatchQueue.main.async {
            NSApp.activate()
            NSApp.windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }?
                .makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: Menü öğeleri

private struct MenuSeparator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
    }
}

private struct MenuSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 3)
    }
}

private struct MenuRow: View {
    let title: String
    var checked: Bool?
    var shortcut: String?
    let action: () -> Void

    init(_ title: String, checked: Bool? = nil, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.checked = checked
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(checked ? 1 : 0)
                        .frame(width: 12)
                }
                Text(title)
                Spacer(minLength: 12)
                if let shortcut {
                    Text(shortcut).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 13))
        }
        .buttonStyle(MenuRowStyle())
    }
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .padding(.horizontal, 5)
        }
    }
}
