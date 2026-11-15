import AppKit
import CoreGraphics

/// Brightness for every connected display, picking the best method per display:
/// native (DisplayServices: built-in and Apple displays) → DDC/CI (external, Apple Silicon) → software gamma.
@Observable
final class DisplayBrightness {
    enum Method { case probing, native, ddc, software }

    struct Item: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        var method: Method
        var value: Double
    }

    private(set) var items: [Item] = []
    private var ddc: [CGDirectDisplayID: (display: DDCDisplay, max: UInt16)] = [:]
    private var softwareLevel: [CGDirectDisplayID: Double] = [:]
    /// Value before our first change, restored by `restore()`.
    private var originals: [CGDirectDisplayID: Double] = [:]
    private var probedDisplays: Set<CGDirectDisplayID> = []
    private var ddcCurrent: [CGDirectDisplayID: Double] = [:]

    private static let minimumSoftware = 0.1 // never fully black

    func refresh() {
        let screens = NSScreen.screens.compactMap { s in s.displayID.map { ($0, s.localizedName) } }
        items = screens.map { id, name in
            if PrivateAPI.nativeBrightnessSupported(id) {
                return Item(id: id, name: name, method: .native, value: Double(PrivateAPI.nativeBrightness(id) ?? 1))
            }
            if ddc[id] != nil { return Item(id: id, name: name, method: .ddc, value: ddcCurrent[id] ?? 1) }
            let method: Method = probedDisplays.contains(id) ? .software : .probing
            return Item(id: id, name: name, method: method, value: softwareLevel[id] ?? 1)
        }
        let toProbe = items.filter { $0.method == .probing }.map(\.id)
        guard !toProbe.isEmpty else { return }
        probedDisplays.formUnion(toProbe)
        Task {
            // DDC discovery and reads block for ~100 ms per monitor: off the main thread.
            let found = await Task.detached(priority: .userInitiated) {
                DDCDisplay.discover(for: toProbe).compactMap { id, display in
                    display.readBrightness().map { (id, display, $0.current, $0.max) }
                }
            }.value
            for (id, display, current, max) in found {
                ddc[id] = (display, max)
                ddcCurrent[id] = Double(current) / Double(max)
            }
            refresh()
        }
    }

    func set(_ id: CGDirectDisplayID, _ value: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let value = min(max(value, 0), 1)
        if originals[id] == nil { originals[id] = items[index].value }
        items[index].value = value
        switch items[index].method {
        case .native:
            PrivateAPI.setNativeBrightness(id, Float(value))
        case .ddc:
            guard let channel = ddc[id] else { return }
            channel.display.setBrightness(UInt16((value * Double(channel.max)).rounded()))
            ddcCurrent[id] = value
        case .software:
            let level = Self.minimumSoftware + (1 - Self.minimumSoftware) * value
            softwareLevel[id] = value
            CGSetDisplayTransferByFormula(id, 0, CGGammaValue(level), 1, 0, CGGammaValue(level), 1, 0, CGGammaValue(level), 1)
        case .probing:
            break
        }
    }

    /// Puts every display back where it was before Mixer touched it.
    func restore() {
        for (id, value) in originals {
            guard let item = items.first(where: { $0.id == id }) else { continue }
            switch item.method {
            case .native: PrivateAPI.setNativeBrightness(id, Float(value))
            case .ddc: if let channel = ddc[id] { channel.display.setBrightness(UInt16((value * Double(channel.max)).rounded())) }
            case .software, .probing: break
            }
        }
        if !softwareLevel.isEmpty { CGDisplayRestoreColorSyncSettings() }
        originals.removeAll()
        softwareLevel.removeAll()
    }
}
