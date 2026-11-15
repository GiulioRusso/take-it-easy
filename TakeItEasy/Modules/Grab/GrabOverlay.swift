import AppKit
import ScreenCaptureKit

/// A selected screen area: display plus rect in that display's points (bottom-left origin).
struct GrabArea {
    let displayID: CGDirectDisplayID
    let rect: NSRect
}

struct GrabSelection {
    let image: CGImage
    let area: GrabArea
    /// ⌘ was held on mouse-up: open a detected link instead of only copying it.
    let openLink: Bool
}

/// Frozen screenshot of every display with a drag-to-select rectangle.
/// Calls `completion` once with the selection, or nil if cancelled (Esc / click without dragging).
final class GrabOverlay {
    private var panels: [NSPanel] = []
    private var completion: ((GrabSelection?) -> Void)?

    static func freezeScreens(completion: @escaping (GrabSelection?) -> Void) async throws -> GrabOverlay {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var shots: [(NSScreen, CGImage)] = []
        for screen in NSScreen.screens {
            if let image = try await capture(screen, content: content) { shots.append((screen, image)) }
        }
        // No panels would mean a GrabOverlay that never calls completion and blocks every later grab.
        guard !shots.isEmpty else { throw GrabError.noDisplays }
        let overlay = GrabOverlay()
        overlay.completion = completion
        overlay.show(shots)
        return overlay
    }

    /// Re-captures a previous area without showing the overlay. Nil if that display is gone.
    static func capture(_ area: GrabArea) async throws -> CGImage? {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == area.displayID }) else { return nil }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let image = try await capture(screen, content: content) else { return nil }
        return crop(image, to: area.rect, viewSize: screen.frame.size)
    }

    private static func capture(_ screen: NSScreen, content: SCShareableContent) async throws -> CGImage? {
        guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        config.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// `rect` is bottom-left origin in points; CGImage is top-left origin in pixels.
    private static func crop(_ image: CGImage, to rect: NSRect, viewSize: CGSize) -> CGImage? {
        let sx = CGFloat(image.width) / viewSize.width
        let sy = CGFloat(image.height) / viewSize.height
        let pixels = CGRect(x: rect.minX * sx, y: (viewSize.height - rect.maxY) * sy,
                            width: rect.width * sx, height: rect.height * sy).integral
        return image.cropping(to: pixels)
    }

    private func show(_ shots: [(NSScreen, CGImage)]) {
        for (screen, image) in shots {
            guard let displayID = screen.displayID else { continue }
            let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.nonactivatingPanel, .borderless],
                                     backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.setFrame(screen.frame, display: false)
            let view = SelectionView(image: image)
            view.onFinish = { [weak self, weak view] result in
                guard let self, let view else { return }
                guard let (rect, command) = result,
                      let crop = Self.crop(image, to: rect, viewSize: view.bounds.size) else { return self.finish(nil) }
                self.finish(GrabSelection(image: crop, area: GrabArea(displayID: displayID, rect: rect), openLink: command))
            }
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        // Key panel = the one under the cursor, so Esc works without activating the app.
        let mouse = NSEvent.mouseLocation
        (panels.first { NSMouseInRect(mouse, $0.frame, false) } ?? panels.first)?.makeKey()
    }

    private func finish(_ selection: GrabSelection?) {
        let completion = completion
        close()
        completion?(selection)
    }

    func close() {
        completion = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

private enum GrabError: LocalizedError {
    case noDisplays
    var errorDescription: String? { String(localized: "nessun display catturabile") }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// ponytail: selection is limited to one display; spanning displays can come later if needed.
private final class SelectionView: NSView {
    let image: CGImage
    /// Selected rect and whether ⌘ was held, or nil when cancelled.
    var onFinish: (((NSRect, Bool)?) -> Void)?
    private var start: NSPoint?
    private var selection: NSRect?

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(image, in: bounds)
        let dim = NSBezierPath(rect: bounds)
        if let selection { dim.append(NSBezierPath(rect: selection)) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()
        if let selection {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        selection = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            .intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selection, selection.width >= 4, selection.height >= 4 else { onFinish?(nil); return }
        onFinish?((selection, event.modifierFlags.contains(.command)))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) } // 53 = Esc
    }
}
