import AppKit
import CoreAudio
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let mixer = Self("mixer")
    static let micMute = Self("micMute", default: .init(.m, modifiers: [.control, .shift]))
    static let pushToTalk = Self("pushToTalk")
}

final class MixerModule: TIEModule {
    let id = "mixer"
    let name = String(localized: "Mixer")
    let summary = String(localized: "Volume per app, microfono e luminosità dei display.")
    let symbol = "slider.horizontal.3"
    let requiredPermissions: [TIEPermission] = [.audioCapture]

    private let model = MixerModel()
    private lazy var pin = PinnableStatusItem(moduleID: id, symbol: symbol, name: name) { [weak self] in self?.toggle() }
    private var running = false
    private var panel: TransientPanel?

    init() {
        #if DEBUG
        DDCDisplay.selfCheck()
        #endif
    }

    func start() throws {
        guard !running else { return } // idempotent
        running = true
        pin.start()
        KeyboardShortcuts.onKeyUp(for: .mixer) { [weak self] in self?.toggle() }
        KeyboardShortcuts.onKeyUp(for: .micMute) { [weak self] in self?.model.mic.toggle() }
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in self?.model.mic.pushToTalk(true) }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in self?.model.mic.pushToTalk(false) }
        model.apps.start()
        model.mic.refresh()
    }

    func stop() {
        panel?.close()
        panel = nil
        running = false
        for name in [KeyboardShortcuts.Name.mixer, .micMute, .pushToTalk] { KeyboardShortcuts.removeHandler(for: name) }
        pin.stop()
        model.mic.restore()      // unmute what we muted
        model.apps.stop()        // taps destroyed → every app back to 100%
        model.displays.restore() // brightness and gamma back to the originals
        model.restoreKeyboard()
    }

    func settingsView() -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 6) {
            KeyboardShortcuts.Recorder(String(localized: "Apri il pannello:"), name: .mixer)
            KeyboardShortcuts.Recorder(String(localized: "Microfono on/off:"), name: .micMute)
            KeyboardShortcuts.Recorder(String(localized: "Push-to-talk (tieni premuto):"), name: .pushToTalk)
            PinToggle(pin)
            Text("Il Mixer è anche nel pannello principale. Nel pannello del Mixer la rotella del mouse sopra uno slider regola di fino. Con il microfono spento compare un microfono rosso nella barra dei menu: cliccalo per riaccenderlo.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        })
    }

    func quickView() -> AnyView? {
        AnyView(MixerView(model: model, compact: true).onAppear { [model] in model.refresh() })
    }

    private func toggle() {
        if let panel {
            panel.close()
            return
        }
        model.refresh()
        let panel = makePanel(model)
        panel.onClose = { [model] in
            model.hovered = nil
            self.panel = nil // close() drops this closure, breaking the cycle
        }
        self.panel = panel
        panel.show(offset: CGVector(dx: 0, dy: -12))
    }
}

// MARK: - Model

enum SliderTarget: Hashable {
    case display(CGDirectDisplayID), keyboard, system, app(String)
}

@Observable
final class MixerModel {
    let displays = DisplayBrightness()
    let apps = AppVolumes()
    let mic = MicMute()
    private(set) var devices: [CA.Device] = []
    private(set) var output: AudioDeviceID = 0
    private(set) var systemVolume: Double = 1
    private(set) var systemMuted = false
    /// nil = no backlit keyboard (or CoreBrightness unavailable): the row is hidden.
    private(set) var keyboard: Double?
    private var keyboardOriginal: Double?
    var hovered: SliderTarget?

    func refresh() {
        displays.refresh()
        keyboard = PrivateAPI.keyboardBrightness().map(Double.init)
        devices = CA.outputDevices()
        output = CA.defaultOutput
        systemVolume = Double(CA.volume(output) ?? 1)
        systemMuted = CA.isMuted(output)
        apps.refresh()
        mic.refresh()
    }

    func setOutput(_ device: AudioDeviceID) {
        CA.defaultOutput = device // AppVolumes hears the change and rebuilds its taps
        refresh()
    }

    func setSystemVolume(_ value: Double) {
        systemVolume = min(max(value, 0), 1)
        CA.setVolume(output, Float(systemVolume))
    }

    func toggleSystemMute() {
        systemMuted.toggle()
        CA.setMuted(output, systemMuted)
    }

    func setKeyboard(_ value: Double) {
        guard let current = keyboard else { return }
        if keyboardOriginal == nil { keyboardOriginal = current }
        keyboard = min(max(value, 0), 1)
        PrivateAPI.setKeyboardBrightness(Float(keyboard!))
    }

    /// Back to the brightness before Mixer touched it.
    func restoreKeyboard() {
        if let keyboardOriginal { PrivateAPI.setKeyboardBrightness(Float(keyboardOriginal)) }
        keyboardOriginal = nil
    }

    func value(_ target: SliderTarget) -> Double {
        switch target {
        case .keyboard: keyboard ?? 0
        case .display(let id): displays.items.first { $0.id == id }?.value ?? 0
        case .system: systemVolume
        case .app(let key): Double(apps.setting(key).volume)
        }
    }

    func set(_ target: SliderTarget, _ value: Double) {
        switch target {
        case .keyboard: setKeyboard(value)
        case .display(let id): displays.set(id, value)
        case .system: setSystemVolume(value)
        case .app(let key): apps.setVolume(key, value)
        }
    }

    /// Scroll wheel over the hovered slider: fine adjustment without clicking.
    func scroll(by delta: Double) -> Bool {
        guard let hovered else { return false }
        set(hovered, value(hovered) + delta * 0.01)
        return true
    }
}

// MARK: - Panel

private func makePanel(_ model: MixerModel) -> TransientPanel {
    let panel = TransientPanel(content: MixerView(model: model).panelChrome(width: 340))
    panel.onEvent = { [weak panel] event in
        guard event.type == .scrollWheel, event.window === panel?.panel else { return false }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
        // Natural scrolling flips the sign: up should always mean louder/brighter.
        return model.scroll(by: event.isDirectionInvertedFromDevice ? -delta : delta)
    }
    return panel
}

// MARK: - View

private struct MixerView: View {
    let model: MixerModel
    /// Main panel: per-app volumes folded away.
    var compact = false
    @State private var showApps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DISPLAY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(model.displays.items) { item in
                MixerRow(model: model, target: .display(item.id), title: item.name, caption: caption(item.method),
                         symbol: "sun.max", isMuted: nil, toggleMute: nil)
                    .disabled(item.method == .probing)
            }
            if model.keyboard != nil {
                MixerRow(model: model, target: .keyboard, title: String(localized: "Tastiera"), caption: nil,
                         symbol: "light.max", isMuted: nil, toggleMute: nil)
            }

            Divider().padding(.vertical, 2)

            HStack {
                Text("AUDIO").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Picker("Uscita", selection: Binding(get: { model.output }, set: { model.setOutput($0) })) {
                    ForEach(model.devices) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 180)
            }
            MixerRow(model: model, target: .system, title: String(localized: "Sistema"), caption: nil,
                     symbol: "speaker.wave.2", isMuted: model.systemMuted, toggleMute: model.toggleSystemMute)
            micRow
            if compact {
                DisclosureGroup(String(localized: "Volume per app (\(model.apps.apps.count))"), isExpanded: $showApps) {
                    appRows.padding(.top, 4)
                }
                .font(.callout)
            } else {
                appRows
            }
            if let error = model.apps.lastError {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var appRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.apps.apps) { app in
                let setting = model.apps.setting(app.id)
                MixerRow(model: model, target: .app(app.id), title: app.name, caption: app.isPlaying ? nil : String(localized: "in pausa"),
                         icon: app.icon, symbol: "app", isMuted: setting.muted, toggleMute: { model.apps.toggleMute(app.id) })
            }
            if model.apps.apps.isEmpty {
                Text("Nessuna app sta riproducendo audio.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var micRow: some View {
        HStack(spacing: 8) {
            Image(systemName: model.mic.isMuted ? "mic.slash.fill" : "mic.fill")
                .foregroundStyle(model.mic.isMuted ? Color.red : Color.primary)
                .frame(width: 18, height: 18)
            Text("Microfono")
            Spacer()
            Toggle("", isOn: Binding(get: { !model.mic.isMuted }, set: { model.mic.set(!$0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }

    private func caption(_ method: DisplayBrightness.Method) -> String? {
        switch method {
        case .probing: String(localized: "rilevamento…")
        case .native: nil
        case .ddc: "DDC"
        case .software: String(localized: "software")
        }
    }
}

private struct MixerRow: View {
    let model: MixerModel
    let target: SliderTarget
    let title: String
    let caption: String?
    var icon: NSImage?
    let symbol: String
    let isMuted: Bool?
    let toggleMute: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon { Image(nsImage: icon).resizable() } else { Image(systemName: symbol) }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).lineLimit(1)
                if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(width: 104, alignment: .leading)
            Slider(value: Binding(get: { model.value(target) }, set: { model.set(target, $0) }), in: 0...1)
                .controlSize(.small)
            if let isMuted, let toggleMute {
                Button(action: toggleMute) {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(isMuted ? Color.red : Color.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.hovered = target } else if model.hovered == target { model.hovered = nil }
        }
    }
}
