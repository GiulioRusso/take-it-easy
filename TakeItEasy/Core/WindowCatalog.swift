import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Small Accessibility helpers.
enum AX {
    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position: AXValue = value(element, kAXPositionAttribute),
              let size: AXValue = value(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        value(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []
    }

    /// AX/CG global coordinates (top-left origin) → AppKit (bottom-left origin).
    static func appKitPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
    }
}

struct CatalogWindow: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let frame: CGRect // global, top-left origin
    let minimized: Bool
    let scWindow: SCWindow
    var image: CGImage?

    /// On screen or minimized. The rest (other Spaces, invisible helper windows) can't be captured
    /// reliably and would show as empty boxes.
    var isShowable: Bool { scWindow.isOnScreen || minimized }
    /// Not on screen and not minimized: on another Space (desktop), or an invisible helper.
    var onOtherSpace: Bool { !scWindow.isOnScreen && !minimized }
    /// Other-Space windows worth listing: titled ones (untitled off-screen windows are mostly helpers).
    var isOnOtherSpaceListable: Bool { onOtherSpace && !(scWindow.title ?? "").isEmpty }
}

/// Lists, captures, raises and closes app windows. Shared by Glance and Switch.
enum WindowCatalog {
    /// Normal-layer windows of `pids` (all apps if nil), front-to-back, including minimized ones.
    static func windows(of pids: Set<pid_t>? = nil) async throws -> [CatalogWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        var minimizedTitles: [pid_t: Set<String>] = [:]
        func minimized(_ pid: pid_t) -> Set<String> {
            if let cached = minimizedTitles[pid] { return cached }
            let titles = Set(AX.windows(of: pid).compactMap { window -> String? in
                guard AX.value(window, kAXMinimizedAttribute) as Bool? == true else { return nil }
                return AX.value(window, kAXTitleAttribute)
            })
            minimizedTitles[pid] = titles
            return titles
        }
        return content.windows.compactMap { w in
            guard let app = w.owningApplication, pids?.contains(app.processID) ?? true,
                  w.windowLayer == 0, w.frame.width >= 100, w.frame.height >= 60 else { return nil }
            let title = w.title ?? ""
            return CatalogWindow(id: w.windowID, pid: app.processID,
                                 title: title.isEmpty ? app.applicationName : title, frame: w.frame,
                                 minimized: !w.isOnScreen && minimized(app.processID).contains(title), scWindow: w)
        }
    }

    /// Thumbnail at most `maxWidth` points wide, rendered at 2×.
    static func thumbnail(_ window: SCWindow, maxWidth: CGFloat = 480) async -> CGImage? {
        let config = SCStreamConfiguration()
        let scale = min(1, maxWidth / max(window.frame.width, 1))
        config.width = Int(window.frame.width * scale * 2)
        config.height = Int(window.frame.height * scale * 2)
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                           configuration: config)
    }

    /// Matches by frame first (same coordinate space as ScreenCaptureKit), then by title.
    static func axWindow(for window: CatalogWindow) -> AXUIElement? {
        let candidates = AX.windows(of: window.pid)
        if let byFrame = candidates.first(where: { AX.frame($0).map { $0.equalTo(window.frame) } ?? false }) { return byFrame }
        return candidates.first { AX.value($0, kAXTitleAttribute) as String? == window.title }
    }

    /// Brings the window to the front (un-minimizing it) and activates its app.
    /// A window on another Space isn't visible to AX yet: activating the app switches to that Space,
    /// then the raise is retried.
    static func raise(_ window: CatalogWindow) {
        let found = raiseAX(window)
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        guard !found else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(500)) // Space switch animation
            raiseAX(window)
        }
    }

    @discardableResult
    private static func raiseAX(_ window: CatalogWindow) -> Bool {
        guard let element = axWindow(for: window) else { return false }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        return true
    }

    /// Presses the window's close button. False if it has none or AX can't find it.
    @discardableResult
    static func close(_ window: CatalogWindow) -> Bool {
        guard let element = axWindow(for: window),
              let button: AXUIElement = AX.value(element, kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }
}
