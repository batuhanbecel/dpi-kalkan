import AppKit
import SwiftUI

/// Menü çubuğu penceresi: ortada büyük güç düğmesi, altında durum ve kapsam seçimi.
struct MenuContent: View {
    @Bindable var model: AppModel
    let updater: Updater
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)

            PowerButton(isOn: model.isRunning) { model.setEnabled(!model.isRunning) }
                .padding(.top, 18)

            status
                .padding(.top, 14)

            Picker("Kapsam", selection: $model.config.onlyListedDomains) {
                Text("Tüm siteler").tag(false)
                Text("Listedekiler").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 18)

            if UpdateBanner.isVisible(for: updater) {
                UpdateBanner(updater: updater)
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

            QuitRow()
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
        }
        .frame(width: 280)
        .animation(.easeInOut(duration: 0.25), value: UpdateBanner.isVisible(for: updater))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.isRunning ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
            Text("DPI Kalkan")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button(action: showSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",")
            .glassCircle()
            .help("Ayarlar")
        }
    }

    private var status: some View {
        VStack(spacing: 3) {
            Text(model.isRunning ? "Koruma açık" : "Koruma kapalı")
                .font(.system(size: 15, weight: .semibold))
                .contentTransition(.opacity)
            Text(model.statusDetail ?? "Açmak için dokun")
                .font(.system(size: 12))
                .foregroundStyle(model.lastError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .lineLimit(1)
                .padding(.horizontal, 16)
        }
        .animation(.easeInOut(duration: 0.25), value: model.isRunning)
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

// MARK: Güç düğmesi

/// Cam görünümlü yuvarlak düğme. Açıkken yeşil dolgu ve arkasında nefes alan yeşil bir parlama.
private struct PowerButton: View {
    let isOn: Bool
    let action: () -> Void
    @State private var breathe = false

    private let size: CGFloat = 108

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.30, green: 0.88, blue: 0.46), Color(red: 0.10, green: 0.62, blue: 0.30)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .opacity(isOn ? 1 : 0)
                Image(systemName: "power")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .shadow(color: .black.opacity(isOn ? 0.18 : 0), radius: 2, y: 1)
                    .symbolEffect(.bounce, value: isOn)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .glassCircle(interactive: true)
        .overlay {
            Circle()
                .strokeBorder(Color.green.opacity(isOn ? 0.55 : 0), lineWidth: 1)
        }
        .background {
            Circle()
                .fill(Color.green)
                .frame(width: size, height: size)
                .blur(radius: 26)
                .scaleEffect(breathe ? 1.22 : 1.0)
                .opacity(isOn ? (breathe ? 0.65 : 0.4) : 0)
        }
        .animation(.spring(duration: 0.45, bounce: 0.3), value: isOn)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) { breathe = true }
        }
        .accessibilityLabel(isOn ? "Korumayı kapat" : "Korumayı aç")
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: Güncelleme

/// Yeni sürüm varken, kurulurken ya da kurulum başarısız olunca görünen cam kart.
private struct UpdateBanner: View {
    let updater: Updater

    static func isVisible(for updater: Updater) -> Bool {
        switch updater.state {
        case .available, .installing: true
        case .failed: updater.fallbackPage != nil
        default: false
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            action
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassPanel()
    }

    private var title: String {
        switch updater.state {
        case .installing: "Güncelleniyor…"
        case .failed: "Güncellenemedi"
        default: "Güncelleme var"
        }
    }

    private var subtitle: String? {
        switch updater.state {
        case .available(let release): "Sürüm \(release.version)"
        case .failed(let message): message
        default: nil
        }
    }

    @ViewBuilder private var action: some View {
        switch updater.state {
        case .installing:
            ProgressView().controlSize(.small)
        case .failed:
            if let page = updater.fallbackPage {
                Button("Sayfayı Aç") { NSWorkspace.shared.open(page) }
                    .controlSize(.small)
            }
        default:
            ProminentButton("Güncelle") { Task { await updater.install() } }
        }
    }
}

private struct ProminentButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            Button(title, action: action).buttonStyle(.glassProminent).controlSize(.small)
        } else {
            Button(title, action: action).buttonStyle(.borderedProminent).controlSize(.small)
        }
    }
}

// MARK: Çıkış satırı

private struct QuitRow: View {
    @State private var hovering = false

    var body: some View {
        Button { NSApp.requestTermination() } label: {
            HStack {
                Text("Çık")
                Spacer()
                Text("⌘Q").foregroundStyle(.tertiary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q")
        .onHover { hovering = $0 }
    }
}

// MARK: Cam

private extension View {
    /// macOS 26 ve sonrasında Liquid Glass, öncesinde buzlu cam daire.
    @ViewBuilder
    func glassPanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.quaternary.opacity(0.6), in: shape)
        }
    }

    @ViewBuilder
    func glassCircle(interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(interactive), in: Circle())
        } else {
            background(.ultraThinMaterial, in: Circle())
        }
    }
}
