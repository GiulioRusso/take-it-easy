import AppKit
import SwiftUI

/// A module's own icon in the menu bar. Removed on `remove()` (call it from the module's `stop()`).
final class StatusItem {
    private var item: NSStatusItem?
    private let target: Target

    /// `tint`: colored icon (e.g. a red muted mic) instead of the usual template one.
    init(symbol: String, accessibilityName: String, tint: NSColor? = nil, action: @escaping () -> Void) {
        target = Target(action)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityName)
        if let tint {
            image = image?.withSymbolConfiguration(.init(paletteColors: [tint]))
            image?.isTemplate = false
        }
        item.button?.image = image
        item.button?.target = target
        item.button?.action = #selector(Target.fire)
        self.item = item
    }

    func setSymbol(_ symbol: String, accessibilityName: String) {
        item?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityName)
    }

    func remove() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// NSStatusItem needs an Objective-C target.
    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

/// A module's optional own menu bar icon. Off by default: the main panel hosts the module;
/// the user pins it from the module's settings (`PinToggle`).
final class PinnableStatusItem {
    let defaultsKey: String
    private let name: String
    private let action: () -> Void
    private var symbol: String
    private var item: StatusItem?
    private var running = false

    init(moduleID: String, symbol: String, name: String, action: @escaping () -> Void) {
        defaultsKey = "\(moduleID).menuBarIcon"
        self.symbol = symbol
        self.name = name
        self.action = action
    }

    func start() { running = true; refresh() }
    func stop() { running = false; refresh() }

    func setSymbol(_ symbol: String) {
        self.symbol = symbol
        item?.setSymbol(symbol, accessibilityName: name)
    }

    /// Shows or removes the icon to match the running state and the user's choice.
    func refresh() {
        let wanted = running && UserDefaults.standard.bool(forKey: defaultsKey)
        if wanted, item == nil {
            item = StatusItem(symbol: symbol, accessibilityName: name, action: action)
        } else if !wanted {
            item?.remove()
            item = nil
        }
    }
}

struct PinToggle: View {
    let item: PinnableStatusItem
    @AppStorage private var pinned: Bool

    init(_ item: PinnableStatusItem) {
        self.item = item
        _pinned = AppStorage(wrappedValue: false, item.defaultsKey)
    }

    var body: some View {
        Toggle(String(localized: "Icona propria nella barra dei menu"), isOn: $pinned)
            .onChange(of: pinned) { item.refresh() }
    }
}
