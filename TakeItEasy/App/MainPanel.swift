import AppKit
import SwiftUI

/// The app's one menu bar icon → a panel with the running modules' quick controls
/// and a tile grid to switch modules on and off (Control Center style).
final class MainPanel {
    private let registry: ModuleRegistry
    private let settings: SettingsWindow
    private var item: StatusItem?
    private var panel: TransientPanel?

    init(registry: ModuleRegistry, settings: SettingsWindow) {
        self.registry = registry
        self.settings = settings
        item = StatusItem(symbol: "wrench.and.screwdriver", accessibilityName: "take-it-easy") { [weak self] in self?.toggle() }
    }

    func toggle() {
        if let panel { return panel.close() }
        let view = MainPanelView(registry: registry) { [weak self] moduleID in
            self?.panel?.close()
            self?.settings.show(moduleID)
        }
        let panel = TransientPanel(content: view.environment(\.closePanel, ClosePanelAction { [weak self] in self?.panel?.close() }))
        panel.onClose = { self.panel = nil } // close() drops this closure, breaking the cycle
        self.panel = panel
        panel.show(offset: CGVector(dx: 0, dy: -12))
    }
}

private struct MainPanelView: View {
    let registry: ModuleRegistry
    /// Opens Settings, on a module's page when given its id.
    let openSettings: (String?) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: "take-it-easy").font(.headline)
                Spacer()
                Button { openSettings(nil) } label: { Image(systemName: "gearshape") }
                    .help(String(localized: "Impostazioni"))
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help(String(localized: "Esci"))
            }
            .buttonStyle(.borderless)

            ForEach(registry.modules.filter { registry.running.contains($0.id) }, id: \.id) { module in
                if let quick = module.quickView() {
                    quick
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
            }

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(registry.modules, id: \.id) { module in
                    ModuleTile(module: module, registry: registry) { openSettings(module.id) }
                }
            }
        }
        .panelChrome(width: 360)
    }
}

private struct ModuleTile: View {
    let module: any TIEModule
    let registry: ModuleRegistry
    let openSettings: () -> Void

    var body: some View {
        let on = registry.isEnabled(module)
        let issue = registry.issues[module.id]
        Button {
            Task { await registry.setEnabled(module, !on) }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: module.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 38, height: 38)
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Circle())
                    .overlay(alignment: .topTrailing) {
                        if issue != nil { Circle().fill(.orange).frame(width: 9, height: 9) }
                    }
                Text(module.name).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(issue ?? module.summary)
        .contextMenu {
            Button(String(localized: "Impostazioni di \(module.name)…"), action: openSettings)
        }
    }
}
