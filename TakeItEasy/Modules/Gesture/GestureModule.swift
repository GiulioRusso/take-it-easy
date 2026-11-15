import AppKit
import SwiftUI

/// A tap of a modifier key on its own (pressed and released within 350 ms, nothing else in between)
/// runs what a trackpad gesture would: e.g. right ⌘ → Show Desktop (four-finger spread).
final class GestureModule: TIEModule {
    let id = "gesture"
    let name = String(localized: "Gesture")
    let summary = String(localized: "Le gesture del trackpad con un tocco di un tasto.")
    let symbol = "hand.draw"
    let requiredPermissions: [TIEPermission] = [.accessibility]

    private lazy var tap = EventTap(events: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel],
                                    listenOnly: true) { [weak self] in
        self?.handle($0)
        return false // never swallow: the modifier must keep working normally
    }
    private var detector = TapDetector()

    init() {
        #if DEBUG
        TapDetector.selfCheck()
        #endif
    }

    func start() throws { try tap.start() }

    func stop() {
        tap.stop()
        detector = TapDetector()
    }

    func settingsView() -> AnyView { AnyView(GestureSettingsView()) }

    private func handle(_ event: TapEvent) {
        guard let key = detector.feed(event, at: Date()),
              let action = GestureMapping.saved.first(where: { $0.key == key })?.action else { return }
        action.run()
    }
}

/// Recognizes a lone modifier tap: down and up within `maxDuration`, with nothing else in between.
nonisolated struct TapDetector {
    static let maxDuration: TimeInterval = 0.35
    private var pressed: (key: GestureKey, time: Date)?

    /// Returns the tapped key when `event` completes a tap.
    mutating func feed(_ event: TapEvent, at now: Date) -> GestureKey? {
        guard event.type == .flagsChanged, let key = GestureKey(rawValue: event.keyCode) else {
            pressed = nil // any key, click or scroll in between: it's a shortcut, not a tap
            return nil
        }
        if event.flags.contains(key.flag) {
            // Only a lone modifier counts: ⌘ while ⇧ is held is a shortcut in progress.
            let others = event.flags.intersection(GestureKey.allFlags).subtracting(key.flag)
            pressed = others.isEmpty ? (key, now) : nil
            return nil
        }
        defer { pressed = nil }
        guard let pressed, pressed.key == key, now.timeIntervalSince(pressed.time) < Self.maxDuration else { return nil }
        return key
    }

    #if DEBUG
    static func selfCheck() {
        func flags(_ key: Int64, _ flags: CGEventFlags) -> TapEvent { TapEvent(type: .flagsChanged, keyCode: key, flags: flags, isRepeat: false) }
        let keyC = TapEvent(type: .keyDown, keyCode: 8, flags: .maskCommand, isRepeat: false)
        let t0 = Date()
        var d = TapDetector()
        // Quick tap of right ⌘ → recognized.
        assert(d.feed(flags(54, .maskCommand), at: t0) == nil)
        assert(d.feed(flags(54, []), at: t0 + 0.1) == .rightCommand)
        // ⌘C → not a tap.
        _ = d.feed(flags(55, .maskCommand), at: t0)
        _ = d.feed(keyC, at: t0 + 0.05)
        assert(d.feed(flags(55, []), at: t0 + 0.1) == nil)
        // Held too long → not a tap.
        _ = d.feed(flags(54, .maskCommand), at: t0)
        assert(d.feed(flags(54, []), at: t0 + 1) == nil)
        // ⌘ pressed while ⇧ is held → not a tap.
        _ = d.feed(flags(54, [.maskCommand, .maskShift]), at: t0)
        assert(d.feed(flags(54, .maskShift), at: t0 + 0.1) == nil)
    }
    #endif
}

// MARK: - Keys and actions

/// Values are the keycodes macOS reports in flagsChanged events.
nonisolated enum GestureKey: Int64, Codable, CaseIterable, Sendable {
    case rightCommand = 54, leftCommand = 55, leftOption = 58, rightOption = 61, leftControl = 59, rightControl = 62, function = 63

    var flag: CGEventFlags {
        switch self {
        case .leftCommand, .rightCommand: .maskCommand
        case .leftOption, .rightOption: .maskAlternate
        case .leftControl, .rightControl: .maskControl
        case .function: .maskSecondaryFn
        }
    }

    static let allFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]

    var label: String {
        switch self {
        case .leftCommand: String(localized: "⌘ sinistro")
        case .rightCommand: String(localized: "⌘ destro")
        case .leftOption: String(localized: "⌥ sinistro")
        case .rightOption: String(localized: "⌥ destro")
        case .leftControl: String(localized: "⌃ sinistro")
        case .rightControl: String(localized: "⌃ destro")
        case .function: String(localized: "fn")
        }
    }
}

nonisolated enum GestureAction: String, Codable, CaseIterable, Sendable {
    case showDesktop, missionControl, appExpose, apps, spaceLeft, spaceRight

    var label: String {
        switch self {
        case .showDesktop: String(localized: "Mostra Scrivania (4 dita verso l'esterno)")
        case .missionControl: String(localized: "Mission Control (4 dita in su)")
        case .appExpose: String(localized: "Finestre dell'app (4 dita in giù)")
        case .apps: String(localized: "App (4 dita verso l'interno)")
        case .spaceLeft: String(localized: "Scrivania a sinistra (4 dita a destra)")
        case .spaceRight: String(localized: "Scrivania a destra (4 dita a sinistra)")
        }
    }

    @MainActor func run() {
        switch self {
        case .missionControl:
            NSWorkspace.shared.open(Self.missionControlApp)
        case .apps:
            // macOS 26 replaced Launchpad with Apps.
            let apps = URL(fileURLWithPath: "/System/Applications/Apps.app")
            let launchpad = URL(fileURLWithPath: "/System/Applications/Launchpad.app")
            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: apps.path) ? apps : launchpad)
        case .showDesktop: Self.pressSystemShortcut(id: 36, fallback: (103, 0))           // F11
        case .appExpose: Self.pressSystemShortcut(id: 33, fallback: (125, 0x40000))      // ⌃↓
        case .spaceLeft: Self.pressSystemShortcut(id: 79, fallback: (123, 0x40000))      // ⌃←
        case .spaceRight: Self.pressSystemShortcut(id: 81, fallback: (124, 0x40000))     // ⌃→
        }
    }

    private static let missionControlApp = URL(fileURLWithPath: "/System/Applications/Mission Control.app")

    /// Presses the keyboard shortcut macOS has for a Mission Control function, as configured in
    /// System Settings › Keyboard › Shortcuts (com.apple.symbolichotkeys: [ascii, keycode, modifiers]).
    /// IDs: 33 application windows, 36 show desktop, 79/81 move one Space left/right.
    private static func pressSystemShortcut(id: Int, fallback: (keyCode: Int, modifiers: Int)) {
        let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        let entry = all?[String(id)] as? [String: Any]
        let parameters = (entry?["value"] as? [String: Any])?["parameters"] as? [Int]
        var keyCode = fallback.keyCode, modifiers = fallback.modifiers
        if let parameters, parameters.count == 3, entry?["enabled"] as? Bool ?? true {
            keyCode = parameters[1]
            modifiers = parameters[2]
        }
        // Function and arrow keys always carry the fn flag (arrows also numpad) in real key events.
        var flags = CGEventFlags(rawValue: UInt64(modifiers))
        if (96...126).contains(keyCode) { flags.insert(.maskSecondaryFn) }
        if (123...126).contains(keyCode) { flags.insert(.maskNumericPad) }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}

nonisolated struct GestureMapping: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var key: GestureKey
    var action: GestureAction

    static let defaultsKey = "gesture.mappings"

    static var saved: [GestureMapping] {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return defaults }
            return (try? JSONDecoder().decode([GestureMapping].self, from: data)) ?? defaults
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey) }
    }

    /// The example from the request: tap right ⌘ → Show Desktop.
    static let defaults = [GestureMapping(key: .rightCommand, action: .showDesktop)]
}

private struct GestureSettingsView: View {
    @State private var mappings = GestureMapping.saved

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($mappings) { $mapping in
                HStack {
                    Picker("Tasto", selection: $mapping.key) {
                        ForEach(GestureKey.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Picker("Azione", selection: $mapping.action) {
                        ForEach(GestureAction.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    Button(role: .destructive) { mappings.removeAll { $0.id == mapping.id } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Aggiungi") {
                    let used = Set(mappings.map(\.key))
                    let key = GestureKey.allCases.first { !used.contains($0) } ?? .rightOption
                    mappings.append(GestureMapping(key: key, action: .missionControl))
                }
                .disabled(mappings.count >= GestureKey.allCases.count)
                Spacer()
            }
            if Set(mappings.map(\.key)).count < mappings.count {
                Text("Lo stesso tasto è usato due volte: vale la prima riga.").font(.caption).foregroundStyle(.orange)
            }
            Text("Tocca il tasto da solo e rilascialo subito: le scorciatoie normali (es. ⌘C) non lo attivano.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: mappings) { _, new in GestureMapping.saved = new }
    }
}
