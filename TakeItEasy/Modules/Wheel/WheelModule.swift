import AppKit
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let wheel = Self("wheel")
}

enum WheelTrigger: String, CaseIterable {
    case middleButton, sideButton, hotkey, optionRightClick

    static let defaultsKey = "wheel.trigger"

    static var current: WheelTrigger {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(WheelTrigger.init) ?? .middleButton
    }

    var label: String {
        switch self {
        case .middleButton: String(localized: "Tasto centrale del mouse")
        case .sideButton: String(localized: "Tasto laterale del mouse (4/5)")
        case .hotkey: String(localized: "Scorciatoia da tastiera")
        case .optionRightClick: String(localized: "⌥ + clic destro")
        }
    }
}

final class WheelModule: TIEModule {
    let id = "wheel"
    let name = String(localized: "Wheel")
    let summary = String(localized: "Rotella di azioni sui file selezionati nel Finder.")
    let symbol = "circle.dashed"
    let requiredPermissions: [TIEPermission] = [.accessibility, .appleEvents(bundleID: "com.apple.finder")]

    private var isRunning = false
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// Mouse-up type to swallow after a swallowed trigger mouse-down, so Finder never sees half a click.
    private var swallowUp: CGEventType?
    private var menu: WheelMenu?
    /// Selection is being read: blocks a second trigger that would open two wheels.
    private var opening = false
    /// Mouse trigger is physically held down (for hold-move-release).
    private var triggerHeld = false

    init() {
        #if DEBUG
        WheelGeometry.selfCheck()
        FileActions.selfCheck()
        MediaActions.selfCheck()
        #endif
    }

    struct TapError: LocalizedError {
        var errorDescription: String? { String(localized: "Impossibile intercettare il mouse: controlla il permesso Accessibilità.") }
    }

    func start() throws {
        guard !isRunning else { return }
        switch WheelTrigger.current {
        case .hotkey:
            KeyboardShortcuts.onKeyUp(for: .wheel) { [weak self] in
                guard Self.finderIsFrontmost else { return }
                self?.fire(holdMode: false)
            }
        case .middleButton, .sideButton, .optionRightClick:
            try installTap()
        }
        isRunning = true
    }

    func stop() {
        KeyboardShortcuts.removeHandler(for: .wheel)
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        swallowUp = nil
        triggerHeld = false
        menu?.close()
        menu = nil
        isRunning = false
    }

    func settingsView() -> AnyView {
        AnyView(WheelSettingsView { [weak self] in
            guard let self, self.isRunning else { return }
            self.stop()
            do { try self.start() } catch { Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill") }
        })
    }

    // MARK: - Event tap

    private func installTap() throws {
        let types: [CGEventType] = [.otherMouseDown, .otherMouseUp, .rightMouseDown, .rightMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let module = Unmanaged<WheelModule>.fromOpaque(refcon).takeUnretainedValue()
                // CGEvent isn't Sendable: extract plain values, decide on the main actor, act here.
                let button = event.getIntegerValueField(.mouseEventButtonNumber)
                let option = event.flags.contains(.maskAlternate)
                // The tap source lives on the main run loop, so the callback runs on the main thread.
                let swallow = MainActor.assumeIsolated { module.shouldSwallow(type, button: button, option: option) }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { throw TapError() }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        tapSource = source
    }

    private func shouldSwallow(_ type: CGEventType, button: Int64, option: Bool) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .otherMouseUp, .rightMouseUp:
            guard swallowUp == type else { return false }
            swallowUp = nil
            triggerHeld = false
            menu?.triggerReleased()
            return true
        case .otherMouseDown, .rightMouseDown:
            guard Self.matches(WheelTrigger.current, type, button: button, option: option),
                  Self.finderIsFrontmost else { return false }
            swallowUp = type == .otherMouseDown ? .otherMouseUp : .rightMouseUp
            if let menu {
                menu.commit() // trigger pressed again while open (click mode) = choose
            } else {
                triggerHeld = true
                fire(holdMode: true)
            }
            return true
        default:
            return false
        }
    }

    private static func matches(_ trigger: WheelTrigger, _ type: CGEventType, button: Int64, option: Bool) -> Bool {
        switch trigger {
        case .middleButton: return type == .otherMouseDown && button == 2
        case .sideButton: return type == .otherMouseDown && (button == 3 || button == 4)
        case .optionRightClick: return type == .rightMouseDown && option
        case .hotkey: return false
        }
    }

    private static var finderIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }

    // MARK: - Trigger

    private func fire(holdMode: Bool) {
        guard menu == nil, !opening else { return }
        opening = true
        Task {
            defer { opening = false }
            do {
                // Empty selection still opens the wheel: "Nuovo file" works on the folder alone.
                let selection = try await FinderSelection.read()
                // If the trigger was released while Finder was answering, open in click mode.
                let menu = WheelMenu(items: WheelItems.build(for: selection), holdMode: holdMode && triggerHeld)
                menu.onClose = { self.menu = nil } // close() drops this closure, breaking the cycle
                self.menu = menu
                menu.show()
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", duration: .seconds(3))
            }
        }
    }
}

private struct WheelSettingsView: View {
    @AppStorage(WheelTrigger.defaultsKey) private var trigger = WheelTrigger.middleButton
    let onTriggerChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Attivazione", selection: $trigger) {
                ForEach(WheelTrigger.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if trigger == .hotkey {
                KeyboardShortcuts.Recorder(String(localized: "Scorciatoia:"), name: .wheel)
            }
            Text("Funziona solo con il Finder in primo piano.")
                .font(.caption).foregroundStyle(.secondary)
            RecipesEditor()
        }
        .onChange(of: trigger) { onTriggerChange() }
    }
}
