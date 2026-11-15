import AppKit
import SwiftUI

/// Compact system monitor: in the main panel (or its own menu bar icon). Samples once a second, only while shown.
final class ResourceManagerModule: TIEModule {
    let id = "resources"
    let name = String(localized: "Resource Manager")
    let summary = String(localized: "CPU, memoria, batterie, potenza, GPU, rete e dischi esterni a colpo d'occhio.")
    let symbol = "cpu"
    let requiredPermissions: [TIEPermission] = []

    private let model = ResourceModel()
    private lazy var pin = PinnableStatusItem(moduleID: id, symbol: symbol, name: name) { [weak self] in self?.toggle() }
    private var panel: TransientPanel?

    init() {
        #if DEBUG
        ResourceSampler.selfCheck()
        #endif
    }

    func start() throws { pin.start() }

    func stop() {
        panel?.close()
        pin.stop()
    }

    func settingsView() -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 6) {
            PinToggle(pin)
            Text("Misura solo mentre il pannello è aperto.").font(.caption).foregroundStyle(.secondary)
        })
    }

    func quickView() -> AnyView? { AnyView(ResourceView(model: model, compact: true)) }

    func toggle() {
        if let panel { return panel.close() }
        let panel = TransientPanel(content: ResourceView(model: model).panelChrome(width: 300))
        panel.onClose = { self.panel = nil } // close() drops this closure, breaking the cycle
        self.panel = panel
        panel.show(offset: CGVector(dx: 0, dy: -12))
    }
}

@Observable
final class ResourceModel {
    private(set) var snapshot = ResourceSnapshot()
    private var sampler = ResourceSampler()
    private var sampling = false
    private(set) var ejecting: Set<URL> = []
    private(set) var ejectError: String?
    var showApps = false
    var showMemoryApps = false
    var showDetails = false
    /// Views currently showing the stats; the first one resets the rate baselines.
    private var viewers = 0

    /// Samples every second for as long as the calling view's `.task` lives.
    func sampleWhileVisible() async {
        viewers += 1
        defer { viewers -= 1 }
        if viewers == 1 { reset() }
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// New sampler: rates restart from a clean baseline each time the panel opens.
    func reset() {
        sampler = ResourceSampler()
        snapshot = ResourceSnapshot()
    }

    func refresh() {
        guard !sampling else { return }
        sampling = true
        let sampler = sampler
        let apps = Dictionary(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .map { ($0.processIdentifier, $0.localizedName ?? "") }, uniquingKeysWith: { a, _ in a })
        Task {
            // IORegistry walks, the process list and the volume list take a few ms: keep them off the main thread.
            let next = await Task.detached(priority: .utility) { sampler.sample(apps: apps) }.value
            snapshot = next
            sampling = false
        }
    }

    func eject(_ disk: ResourceSnapshot.Disk) {
        ejecting.insert(disk.url)
        ejectError = nil
        let url = disk.url
        Task {
            do {
                try await Task.detached { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }.value
            } catch {
                ejectError = String(localized: "Impossibile espellere «\(disk.name)»: \(error.localizedDescription)")
            }
            ejecting.remove(url)
            refresh()
        }
    }
}

private struct ResourceView: View {
    let model: ResourceModel
    /// Main panel: CPU and memory only, the rest under "Dettagli".
    var compact = false

    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 10) {
            row(String(localized: "CPU"), "cpu", fraction: s.cpu, text: percent(s.cpu))
            row(String(localized: "Memoria"), "memorychip", fraction: Double(s.memoryUsed) / Double(max(s.memoryTotal, 1)),
                text: memoryText(s))
            if compact {
                DisclosureGroup(String(localized: "Dettagli"), isExpanded: Binding(get: { model.showDetails }, set: { model.showDetails = $0 })) {
                    VStack(alignment: .leading, spacing: 10) { details(s) }.padding(.top, 6)
                }
                .font(.callout)
            } else {
                details(s)
            }
        }
        .task { await model.sampleWhileVisible() }
    }

    /// Everything below the CPU and memory bars (folded away in the main panel).
    @ViewBuilder private func details(_ s: ResourceSnapshot) -> some View {
        if !s.cores.isEmpty {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(s.cores.indices, id: \.self) { i in
                    Capsule().fill(color(s.cores[i]))
                        .frame(width: 6, height: max(2, 22 * s.cores[i]))
                }
            }
            .frame(height: 22, alignment: .bottom)
            .padding(.leading, 26)
        }
        appList(String(localized: "Uso CPU per app"), expanded: Binding(get: { model.showApps }, set: { model.showApps = $0 }),
                rows: s.apps,
                empty: s.cpu == nil ? String(localized: "Misuro…") : String(localized: "Nessuna app sta usando la CPU.")) {
            (String(format: "%.1f%%", $0.cpu), $0.cpu > 80)
        }
        appList(String(localized: "Uso memoria per app"),
                expanded: Binding(get: { model.showMemoryApps }, set: { model.showMemoryApps = $0 }),
                rows: s.memoryApps, empty: String(localized: "Misuro…")) {
            (bytes(Int64($0.memory)), Double($0.memory) > Double(s.memoryTotal) * 0.25)
        }
        row(String(localized: "GPU"), "cpu.fill", fraction: s.gpu, text: percent(s.gpu))
        if let p = s.power {
            labeled(String(localized: "Potenza"), "bolt") {
                Text(powerText(p)).monospacedDigit()
            }
        }
        labeled(String(localized: "Rete"), "network") {
            Text("↓ \(rate(s.download))   ↑ \(rate(s.upload))").monospacedDigit()
        }

        if !s.batteries.isEmpty {
            Divider()
            Text("BATTERIE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(s.batteries) { device in
                HStack(spacing: 8) {
                    Image(systemName: device.symbol).frame(width: 18)
                    Text(device.name).lineLimit(1)
                    Spacer()
                    Text(device.levels.map { "\($0.label) \($0.percent)%".trimmingCharacters(in: .whitespaces) }.joined(separator: " · "))
                        .monospacedDigit().foregroundStyle(device.levels.contains { $0.percent <= 20 } ? .orange : .primary)
                }
            }
        }
        Divider()
        Text("DISCHI ESTERNI").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        if s.disks.isEmpty {
            Text("Nessun disco esterno collegato.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(s.disks) { disk in
            HStack(spacing: 8) {
                Image(systemName: "externaldrive").frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.name).lineLimit(1)
                    ProgressView(value: Double(disk.total - disk.free), total: Double(max(disk.total, 1)))
                        .controlSize(.small)
                    Text("\(bytes(disk.free)) liberi di \(bytes(disk.total))").font(.caption2).foregroundStyle(.secondary)
                }
                if disk.ejectable {
                    Button { model.eject(disk) } label: { Image(systemName: "eject") }
                        .buttonStyle(.borderless)
                        .disabled(model.ejecting.contains(disk.url))
                        .help(String(localized: "Espelli"))
                }
            }
        }
        if let error = model.ejectError {
            Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Collapsible top-10 list; `value` gives the right-hand text and whether to highlight it.
    private func appList(_ title: String, expanded: Binding<Bool>, rows: [ResourceSnapshot.AppUsage], empty: String,
                         value: @escaping (ResourceSnapshot.AppUsage) -> (String, Bool)) -> some View {
        DisclosureGroup(isExpanded: expanded) {
            VStack(alignment: .leading, spacing: 5) {
                if rows.isEmpty { Text(empty).font(.caption).foregroundStyle(.secondary) }
                ForEach(rows) { app in
                    let (text, hot) = value(app)
                    HStack(spacing: 6) {
                        Group {
                            if app.pid != 0, let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
                                Image(nsImage: icon).resizable()
                            } else {
                                Image(systemName: "gearshape").foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 16, height: 16)
                        Text(app.name).lineLimit(1)
                        Spacer()
                        Text(text).monospacedDigit().foregroundStyle(hot ? .orange : .primary)
                    }
                    .font(.callout)
                }
            }
            .padding(.top, 4)
        } label: {
            Text(title).font(.callout)
        }
        .padding(.leading, 26)
    }

    private func row(_ title: String, _ symbol: String, fraction: Double?, text: String) -> some View {
        labeled(title, symbol) {
            HStack {
                ProgressView(value: min(max(fraction ?? 0, 0), 1)).tint(color(fraction ?? 0)).controlSize(.small)
                Text(text).monospacedDigit().lineLimit(1).fixedSize().frame(minWidth: 90, alignment: .trailing)
            }
        }
    }

    private func labeled(_ title: String, _ symbol: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 18)
            Text(title).frame(width: 70, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func color(_ load: Double) -> Color { load > 0.85 ? .red : load > 0.6 ? .orange : .accentColor }

    private func percent(_ value: Double?) -> String { value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }

    /// "12.8 / 16 GB": short enough to sit next to the bar.
    private func memoryText(_ s: ResourceSnapshot) -> String {
        let gb = Double(1 << 30)
        let used = (Double(s.memoryUsed) / gb).formatted(.number.precision(.fractionLength(1)))
        let total = (Double(s.memoryTotal) / gb).formatted(.number.precision(.fractionLength(0)))
        return "\(used) / \(total) GB"
    }

    private func bytes(_ value: Int64) -> String { value.formatted(.byteCount(style: .memory)) }

    private func rate(_ value: Double?) -> String {
        value.map { "\(Int64($0).formatted(.byteCount(style: .binary)))/s" } ?? "—"
    }

    private func powerText(_ p: ResourceSnapshot.Power) -> String {
        var parts: [String] = []
        if let watts = p.watts { parts.append(String(format: "%.1f W", watts)) }
        if let percent = p.batteryPercent {
            parts.append(p.charging ? String(localized: "\(percent)% in carica")
                         : p.onAC ? String(localized: "\(percent)% alimentatore") : String(localized: "\(percent)% batteria"))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}
