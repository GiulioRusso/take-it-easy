import ServiceManagement
import SwiftUI

/// Settings in a plain window we own (the SwiftUI Settings scene can't be opened from AppKit on macOS 14).
final class SettingsWindow {
    private let registry: ModuleRegistry
    private let selection = SettingsSelection()
    private var window: NSWindow?

    init(registry: ModuleRegistry) { self.registry = registry }

    /// `moduleID`: page to open; nil keeps the current one.
    func show(_ moduleID: String? = nil) {
        if let moduleID { selection.page = moduleID }
        if window == nil {
            let root = SettingsView(selection: selection).environment(registry)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = String(localized: "Impostazioni take-it-easy")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 720, height: 520))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

@Observable
final class SettingsSelection {
    static let general = "general"
    var page: String? = general
}

struct SettingsView: View {
    @Environment(ModuleRegistry.self) private var registry
    @Bindable var selection: SettingsSelection

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.page) {
                Label("Generali", systemImage: "gearshape").tag(SettingsSelection.general)
                Section("Moduli") {
                    ForEach(registry.modules, id: \.id) { module in
                        HStack {
                            Label(module.name, systemImage: module.symbol)
                            Spacer()
                            Circle()
                                .fill(registry.issues[module.id] != nil ? Color.orange
                                      : registry.isEnabled(module) ? Color.green : Color.clear)
                                .frame(width: 7, height: 7)
                        }
                        .tag(module.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            if let module = registry.modules.first(where: { $0.id == selection.page }) {
                ModulePage(module: module)
            } else {
                GeneralPage()
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

private struct ModulePage: View {
    @Environment(ModuleRegistry.self) private var registry
    let module: any TIEModule

    var body: some View {
        Form {
            Section {
                Toggle(isOn: registry.binding(for: module)) {
                    Label {
                        VStack(alignment: .leading) {
                            Text(module.name).font(.headline)
                            Text(module.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: module.symbol)
                    }
                }
                if let issue = registry.issues[module.id] {
                    Text(issue).font(.caption).foregroundStyle(.orange)
                }
            }
            if registry.isEnabled(module) {
                Section("Impostazioni") { module.settingsView() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(module.name)
    }
}

private struct GeneralPage: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Avvia al login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                Text("Clicca l'icona nella barra dei menu: in alto i controlli rapidi dei moduli accesi, in basso i riquadri per accenderli e spegnerli. Clic destro su un riquadro per le sue impostazioni.")
                    .font(.caption).foregroundStyle(.secondary)
                #if DEBUG
                Button("Prova toast") { Toast.show(String(localized: "Copiato · 42 parole")) }
                #endif
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Generali")
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
