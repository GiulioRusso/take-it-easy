import AppKit
import SwiftUI

/// Non-activating panel shown at the mouse cursor, on any display and over full-screen Spaces.
final class CursorPanel: NSPanel {
    convenience init(content: some View) {
        self.init(contentView: AutoSizingHostingView(rootView: content))
    }

    /// For panels that need their own view subclass (e.g. to receive middle/right clicks).
    init(contentView view: NSView) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = view
    }

    /// Allows keyboard input (e.g. Esc) when explicitly made key; still never activates the app.
    override var canBecomeKey: Bool { true }

    /// Centers the panel on the cursor (plus `offset`), clamped to the visible frame of the cursor's screen.
    func showAtCursor(offset: CGVector = .zero) {
        let mouse = NSEvent.mouseLocation
        show(centeredAt: CGPoint(x: mouse.x + offset.dx, y: mouse.y + offset.dy))
    }

    /// Centers the panel on `point` (global, bottom-left origin), clamped to the visible frame of that point's screen.
    func show(centeredAt point: CGPoint) {
        let size = contentView?.fittingSize ?? .zero
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        var frame = NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                           width: size.width, height: size.height)
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        }
        setFrame(frame, display: true)
        orderFrontRegardless()
    }
}

/// Resizes its window when the SwiftUI content grows or shrinks (a disclosure opening),
/// keeping the top edge in place and the window on screen.
private final class AutoSizingHostingView<Content: View>: NSHostingView<Content> {
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        Task { @MainActor [weak self] in self?.fitWindow() } // after SwiftUI finishes the layout pass
    }

    private func fitWindow() {
        guard let window, window.isVisible else { return }
        let size = fittingSize
        guard size != window.frame.size else { return }
        var frame = window.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        if let visible = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        }
        window.setFrame(frame, display: true)
    }
}

enum Toast {
    private static var panel: CursorPanel?
    private static var hideTask: Task<Void, Never>?

    /// Shows a short message just below the cursor, then fades away.
    static func show(_ text: String, symbol: String = "checkmark.circle.fill", duration: Duration = .seconds(1.5)) {
        hideTask?.cancel()
        panel?.orderOut(nil)
        let panel = CursorPanel(content: ToastView(text: text, symbol: symbol))
        panel.ignoresMouseEvents = true
        panel.alphaValue = 1
        panel.showAtCursor(offset: CGVector(dx: 0, dy: -48))
        self.panel = panel
        hideTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 0 }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }
}

private struct ToastView: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(8) // room for the shadow
    }
}
