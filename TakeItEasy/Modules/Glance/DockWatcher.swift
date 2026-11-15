import AppKit
import ApplicationServices
import CoreGraphics

/// Reports which Dock icon is under the cursor, via the Dock's selected-children notification
/// (the Dock "selects" the icon being hovered).
final class DockWatcher {
    /// Bundle ID of the hovered app icon, or nil (cursor left the Dock / not an app).
    var onChange: ((String?) -> Void)?

    private var observer: AXObserver?
    private var list: AXUIElement?
    private var relaunchObserver: NSObjectProtocol?

    func start() {
        install()
        // The Dock can restart (e.g. `killall Dock`): reattach to the new process.
        relaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.dock" else { return }
            MainActor.assumeIsolated { self?.install() }
        }
    }

    func stop() {
        uninstall()
        if let relaunchObserver { NSWorkspace.shared.notificationCenter.removeObserver(relaunchObserver) }
        relaunchObserver = nil
    }

    /// Bundle ID of the icon currently hovered.
    var hoveredBundleID: String? {
        guard let list, let selected: [AXUIElement] = AX.value(list, kAXSelectedChildrenAttribute),
              let item = selected.first,
              AX.value(item, kAXSubroleAttribute) as String? == "AXApplicationDockItem",
              let url: URL = AX.value(item, kAXURLAttribute) else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    /// Frame (top-left origin, global) of the hovered icon.
    var hoveredFrame: CGRect? {
        guard let list, let selected: [AXUIElement] = AX.value(list, kAXSelectedChildrenAttribute),
              let item = selected.first else { return nil }
        return AX.frame(item)
    }

    private func install() {
        uninstall()
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        let children: [AXUIElement] = AX.value(app, kAXChildrenAttribute) ?? []
        guard let list = children.first(where: { AX.value($0, kAXRoleAttribute) as String? == kAXListRole }) else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<DockWatcher>.fromOpaque(refcon).takeUnretainedValue()
            // The observer's source is on the main run loop.
            MainActor.assumeIsolated { watcher.onChange?(watcher.hoveredBundleID) }
        }
        guard AXObserverCreate(dock.processIdentifier, callback, &observer) == .success, let observer else { return }
        AXObserverAddNotification(observer, list, kAXSelectedChildrenChangedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = observer
        self.list = list
    }

    private func uninstall() {
        if let observer {
            if let list { AXObserverRemoveNotification(observer, list, kAXSelectedChildrenChangedNotification as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        list = nil
    }
}
