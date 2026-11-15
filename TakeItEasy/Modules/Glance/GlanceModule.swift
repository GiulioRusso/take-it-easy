import AppKit
import SwiftUI

/// Hovering a Dock icon opens a bubble above it (never over the Dock) with the app's window thumbnails.
final class GlanceModule: TIEModule {
    let id = "glance"
    let name = String(localized: "Glance")
    let summary = String(localized: "Anteprime delle finestre sopra le icone del Dock.")
    let symbol = "macwindow.on.rectangle"
    let requiredPermissions: [TIEPermission] = [.accessibility, .screenRecording]

    private let dock = DockWatcher()
    private let bubble = WindowBubble()
    private var running = false
    private var showTask: Task<Void, Never>?
    private var hideTimer: Timer?
    private var keyMonitor: Any?
    /// Bundle ID shown (or about to be shown).
    private var current: String?

    private static let hoverDelay: Duration = .milliseconds(300)

    func start() throws {
        guard !running else { return }
        running = true
        bubble.model.onRaise = { [weak self] window in
            WindowCatalog.raise(window)
            self?.hide()
        }
        bubble.model.onClose = { [weak self] window in
            guard WindowCatalog.close(window) else { return }
            self?.bubble.remove(window.id)
        }
        dock.onChange = { [weak self] bundleID in self?.hoverChanged(bundleID) }
        dock.start()
    }

    func stop() {
        guard running else { return }
        running = false
        dock.stop()
        hide()
    }

    func settingsView() -> AnyView {
        AnyView(Text("Passa sopra un'icona del Dock: clic su una miniatura per portarla in primo piano, clic centrale per chiuderla, digita per filtrare.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true))
    }

    // MARK: - Hover

    private func hoverChanged(_ bundleID: String?) {
        guard let bundleID else { return } // leaving the Dock is handled by the hide timer
        guard bundleID != current || !bubble.isVisible else { return }
        current = bundleID
        showTask?.cancel()
        showTask = Task {
            try? await Task.sleep(for: Self.hoverDelay)
            guard !Task.isCancelled, dock.hoveredBundleID == bundleID,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
                  let iconFrame = dock.hoveredFrame else { return }
            // AX frames are top-left origin: convert the icon's corners to AppKit.
            let bottomLeft = AX.appKitPoint(CGPoint(x: iconFrame.minX, y: iconFrame.maxY))
            let anchor = CGRect(origin: bottomLeft, size: iconFrame.size)
            startWatching() // hides if the cursor leaves before the bubble appears, too
            await bubble.show(app, anchor: anchor, edge: Self.dockEdge, takesKeyboard: true) // typing filters by title
        }
    }

    private func hide() {
        showTask?.cancel()
        hideTimer?.invalidate()
        hideTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        bubble.hide()
        bubble.flush()
        current = nil
    }

    /// Hide once the cursor is neither on a Dock app icon nor over the bubble; route typing to the filter.
    private func startWatching() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let overBubble = self.bubble.panel.frame.insetBy(dx: -10, dy: -10).contains(NSEvent.mouseLocation)
                if !overBubble, self.dock.hoveredBundleID == nil { self.hide() }
            }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.bubble.isVisible else { return event }
                return self.handleKey(event) ? nil : event
            }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let model = bubble.model
        switch event.keyCode {
        case 53: hide() // Esc
        case 51: if !model.filter.isEmpty { model.filter.removeLast() } // Delete
        case 36: if let first = model.visible.first { model.onRaise?(first) } // Return
        default:
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
                  event.modifierFlags.intersection([.command, .control]).isEmpty else { return false }
            model.filter += chars
        }
        return true
    }

    private static var dockEdge: BubbleEdge {
        switch UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") {
        case "left": .left
        case "right": .right
        default: .bottom
        }
    }
}
