import AppKit
import SwiftUI

/// A CursorPanel that closes on Esc or on a click anywhere else, like a menu.
final class TransientPanel {
    let panel: CursorPanel
    private var monitors: [Any] = []
    /// Local key/scroll events while open; return true to consume.
    var onEvent: ((NSEvent) -> Bool)?
    var onClose: (() -> Void)?

    init(content: some View) {
        panel = CursorPanel(content: content)
    }

    func show(offset: CGVector = .zero) {
        panel.showAtCursor(offset: offset)
        panel.makeKey()
        let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 { self.close(); return nil } // Esc
            return self.onEvent?(event) == true ? nil : event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        monitors = [local, global].compactMap { $0 }
    }

    /// Idempotent.
    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        panel.orderOut(nil)
        // Tear the SwiftUI views down so their `.task`s stop (panels are one-shot); next turn, since
        // close() may be running inside one of those views' button actions.
        Task { @MainActor [panel] in panel.contentView = nil }
        let onClose = onClose
        self.onClose = nil
        onClose?()
    }
}

extension View {
    /// Look of a floating panel: material card with room for the shadow.
    func panelChrome(width: CGFloat) -> some View {
        padding(14)
            .frame(width: width, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(8)
    }
}

extension EnvironmentValues {
    /// Closes the panel hosting the view (e.g. a quick view in the main panel after its action).
    @Entry var closePanel = ClosePanelAction {}
}

/// A struct, not a bare closure, so the environment value doesn't invalidate views on every update.
struct ClosePanelAction {
    let action: () -> Void
    func callAsFunction() { action() }
}
