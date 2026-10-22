import AppKit
import KalkanCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    let updater: Updater

    var body: some View {
        TabView {
            GeneralTab(model: model, updater: updater)
                .tabItem { Label("Genel", systemImage: "gearshape") }
            SitesTab(model: model)
                .tabItem { Label("Siteler", systemImage: "globe") }
            AdvancedTab(model: model)
                .tabItem { Label("Gelişmiş", systemImage: "slider.horizontal.3") }
            ActivityTab(model: model)
                .tabItem { Label("Etkinlik", systemImage: "chart.bar.xaxis") }
        }
        .frame(width: 480)
    }
}

// MARK: Genel

private struct GeneralTab: View {
    @Bindable var model: AppModel
    @Bindable var updater: Updater
    @State private var testHost = ""

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DPI Kalkan").font(.title3.weight(.semibold))
                        Text("Sürüm \(version)").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Koruma", isOn: Binding(get: { model.isRunning }, set: { model.setEnabled($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.vertical, 2)
            }

            Section {
                Toggle("Oturum açılışında başlat", isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }
                ))
                Toggle("Açılışta korumayı etkinleştir", isOn: $model.autoStart)
                Toggle("Sistem geneline uygula", isOn: $model.systemWide)
            }

            Section("Güncellemeler") {
                Toggle("Güncellemeleri otomatik denetle", isOn: $updater.automatic)
                HStack {
                    updateStatus
                    Spacer()
                    if let release = updater.available {
                        Button("Sürüm Notları") { NSWorkspace.shared.open(release.pageURL) }
                        Button("Güncelle") { Task { await updater.install() } }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Şimdi Denetle") { Task { await updater.check() } }
                            .disabled(updater.state == .checking || updater.state == .installing)
                    }
                }
            }

            Section("Erişim testi") {
                HStack {
                    TextField("Site", text: $testHost, prompt: Text("discord.com"))
                        .labelsHidden()
                        .onSubmit { model.testConnection(host: testHost) }
                    Button("Sına") { model.testConnection(host: testHost) }
                        .disabled(!model.isRunning || model.testState == .running)
                }
                switch model.testState {
                case .idle:
                    EmptyView()
                case .running:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Bağlanılıyor…").foregroundStyle(.secondary)
                    }
                case .ok(let s):
                    Label(s, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let s):
                    Label(s, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 500)
    }

    @ViewBuilder private var updateStatus: some View {
        switch updater.state {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Denetleniyor…").foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Güncelleniyor…").foregroundStyle(.secondary)
            }
        case .available(let release):
            Label("Sürüm \(release.version) hazır", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue)
        case .upToDate:
            Label("Güncel", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle:
            if let last = updater.lastCheck {
                Text("Son denetim: \(last.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
            } else {
                Text("Henüz denetlenmedi").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Siteler

private struct SitesTab: View {
    @Bindable var model: AppModel
    @State private var newDomain = ""

    var body: some View {
        Form {
            Section {
                Picker("Uygulanacak siteler", selection: $model.config.onlyListedDomains) {
                    Text("Tüm siteler").tag(false)
                    Text("Yalnızca listedekiler").tag(true)
                }
            }

            Section {
                ForEach(model.config.domains, id: \.self) { domain in
                    HStack {
                        Text(domain)
                        Spacer()
                        Button {
                            model.removeDomain(domain)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Kaldır")
                    }
                }
                HStack {
                    TextField("Site ekle", text: $newDomain, prompt: Text("ornek.com"))
                        .labelsHidden()
                        .onSubmit(add)
                    Button("Ekle", action: add)
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                HStack {
                    Text("Liste")
                    Spacer()
                    Button("Varsayılanlar") { model.resetDomains() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            .disabled(!model.config.onlyListedDomains)
        }
        .formStyle(.grouped)
        .frame(height: 460)
    }

    private func add() {
        model.addDomain(newDomain)
        newDomain = ""
    }
}

// MARK: Gelişmiş

private struct AdvancedTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Bölme yöntemi", selection: $model.config.mode) {
                    ForEach(FragmentMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Parça arası bekleme") {
                    Stepper("\(model.config.delayMs) ms", value: $model.config.delayMs, in: 0...200, step: 5)
                }
                LabeledContent("Port") {
                    TextField("Port", value: $model.config.port, format: .number.grouping(.never))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                }
            } footer: {
                Text("Bir site seçili yöntemi kabul etmezse proxy kendiliğinden TCP segment bölmeye geçer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 230)
    }
}

// MARK: Etkinlik

private struct ActivityTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                HStack {
                    stat("Aktif", model.stats.active)
                    stat("Toplam", model.stats.total)
                    stat("Bölünen", model.stats.fragmented)
                    stat("Hatalı", model.stats.failed)
                }
                .padding(.vertical, 4)
            }

            Section {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.logs.isEmpty ? "Kayıt yok" : model.logs.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(model.logs.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("son")
                    }
                    .frame(height: 210)
                    .onChange(of: model.logs.count) { proxy.scrollTo("son") }
                }
            } header: {
                HStack {
                    Text("Kayıt")
                    Spacer()
                    Button("Temizle") { model.clearLogs() }
                        .buttonStyle(.link)
                        .font(.callout)
                        .disabled(model.logs.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
