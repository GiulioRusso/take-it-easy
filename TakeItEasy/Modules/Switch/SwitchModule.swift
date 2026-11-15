import AppKit
import OSLog
import SwiftUI

/// • System ⌘Tab stays as it is; while it's open, a bubble above the selected app shows its windows.
/// • ⌥`: cycle the windows of the front app (several VS Code / Safari windows), always centered on screen.
///   Hold ⌥, press ` to move (⇧ goes back, ← → too), release ⌥ to choose, Esc to cancel.
final class SwitchModule: TIEModule {
    let id = "switch"
    let name = String(localized: "Switch")
    let summary = String(localized: "Anteprime nel ⌘Tab di sistema e ⌥` tra le finestre della stessa app.")
    let symbol = "rectangle.on.rectangle"
    let requiredPermissions: [TIEPermission] = [.accessibility, .screenRecording]

    private lazy var tap = EventTap(events: [.keyDown, .flagsChanged]) { [weak self] in self?.handle($0) ?? false }
    private let commandTab = CommandTabPreview()
    private let model = WindowSwitcherModel()
    private lazy var panel: CursorPanel = {
        let panel = CursorPanel(contentView: SwitchHostingView(rootView: WindowSwitcherView(model: model)))
        panel.hasShadow = false
        return panel
    }()
    private var loadTask: Task<Void, Never>?

    private enum Key {
        static let tab: Int64 = 48, grave: Int64 = 50, isoSection: Int64 = 10 // ` sits on 50 (ANSI) or 10 (ISO, e.g. Italian)
        static let escape: Int64 = 53, left: Int64 = 123, right: Int64 = 124, `return`: Int64 = 36
    }

    func start() throws {
        try tap.start()
        commandTab.start()
        model.onChoose = { [weak self] index in self?.commit(index) }
    }

    func stop() {
        tap.stop()
        commandTab.stop()
        cancel()
    }

    func settingsView() -> AnyView {
        AnyView(Text("⌘Tab: tieni premuto ⌘ come sempre, sopra l'app selezionata compaiono le sue finestre. ⌥`: tieni premuto ⌥ e premi ` per scorrere le finestre dell'app in primo piano; rilascia ⌥ per scegliere.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true))
    }

    // MARK: - Keys

    private func handle(_ event: TapEvent) -> Bool {
        commandTab.observe(event) // never swallows: the system ⌘Tab keeps working
        let option = event.flags.contains(.maskAlternate)
        if event.type == .flagsChanged {
            if model.active, !option { commit(model.selected) }
            return false
        }
        if model.active {
            switch event.keyCode {
            case Key.grave, Key.isoSection: model.move(event.flags.contains(.maskShift) ? -1 : 1)
            case Key.left: model.move(-1)
            case Key.right: model.move(1)
            case Key.escape: cancel()
            case Key.return: commit(model.selected)
            default: break
            }
            return true // while open, keys belong to the switcher
        }
        let others = !event.flags.intersection([.maskCommand, .maskControl]).isEmpty
        guard option, !others, !event.isRepeat, event.keyCode == Key.grave || event.keyCode == Key.isoSection else { return false }
        open(back: event.flags.contains(.maskShift))
        return true
    }

    // MARK: - ⌥` window switcher

    private func open(back: Bool) {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        model.begin(entries: [])
        loadTask?.cancel()
        loadTask = Task {
            guard let windows = try? await WindowCatalog.windows(of: [front.processIdentifier]), model.active else { return }
            let own = windows.filter(\.isShowable)
            guard own.count > 1 else { return cancel() } // nothing to switch to
            model.begin(entries: own.map { WindowSwitcherModel.Entry(window: $0, icon: front.icon) })
            model.move(back ? -1 : 1) // start on the previous window, like ⌘Tab
            present()
            for entry in model.entries {
                guard model.active else { return }
                if let image = await WindowCatalog.thumbnail(entry.window.scWindow, maxWidth: 260) { model.setImage(image, for: entry.id) }
            }
        }
    }

    /// Always in the middle of the screen in use.
    private func present() {
        guard let screen = NSScreen.main else { return }
        panel.show(centeredAt: CGPoint(x: screen.frame.midX, y: screen.frame.midY))
    }

    private func commit(_ index: Int) {
        guard model.entries.indices.contains(index) else { return cancel() }
        let window = model.entries[index].window
        cancel()
        WindowCatalog.raise(window)
    }

    private func cancel() {
        loadTask?.cancel()
        model.end()
        panel.orderOut(nil)
    }
}

// MARK: - System ⌘Tab preview

/// Follows the system ⌘Tab switcher and shows the selected app's windows in a bubble above its icon.
/// The selection and icon position come from the Dock's accessibility tree (the switcher lives in the Dock);
/// if macOS doesn't expose them, we track the selection ourselves from the key presses, using recent-use order.
private final class CommandTabPreview {
    private let bubble = WindowBubble()
    private var active = false
    private var index = 0
    private var order: [NSRunningApplication] = []
    private var recent: [pid_t] = [] // most recently activated first
    private var activationObserver: NSObjectProtocol?
    private var updateTask: Task<Void, Never>?
    private static let log = Logger(subsystem: "take-it-easy", category: "switch")
    /// The system switcher appears after a short hold; a quick ⌘Tab shouldn't flash a bubble.
    private static let delay: Duration = .milliseconds(150)

    func start() {
        recent = Self.zOrderPIDs()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated {
                self?.recent.removeAll { $0 == pid }
                self?.recent.insert(pid, at: 0)
            }
        }
        bubble.model.onRaise = { [weak self] window in
            self?.end()
            WindowCatalog.raise(window)
        }
        bubble.model.onClose = { [weak self] window in
            if WindowCatalog.close(window) { self?.bubble.remove(window.id) }
        }
    }

    func stop() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        end()
    }

    func observe(_ event: TapEvent) {
        let command = event.flags.contains(.maskCommand)
        if event.type == .flagsChanged {
            if active, !command { end() }
            return
        }
        guard command, event.flags.intersection([.maskControl, .maskAlternate]).isEmpty else { return }
        switch event.keyCode {
        case 48: // Tab
            let back = event.flags.contains(.maskShift)
            if !active {
                active = true
                order = appOrder()
                index = back ? order.count - 1 : 1
            } else if !order.isEmpty {
                index = (index + (back ? -1 : 1) + order.count) % order.count
            }
            scheduleUpdate()
        case 53: end() // Esc cancels the system switcher too
        case 123, 124: // ← → move the system selection
            guard active, !order.isEmpty else { return }
            index = (index + (event.keyCode == 123 ? -1 : 1) + order.count) % order.count
            scheduleUpdate()
        default:
            break
        }
    }

    private func scheduleUpdate() {
        updateTask?.cancel()
        updateTask = Task {
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, active else { return }
            await update()
        }
    }

    private func update() async {
        if let (title, frame) = Self.systemSelection(),
           let app = order.first(where: { $0.localizedName == title }) {
            let bottomLeft = AX.appKitPoint(CGPoint(x: frame.minX, y: frame.maxY))
            await bubble.show(app, anchor: CGRect(origin: bottomLeft, size: frame.size), edge: .bottom)
            return
        }
        // Fallback: our own tracking; the system switcher sits in the middle of the main screen.
        guard order.indices.contains(index), let screen = NSScreen.main else { return }
        let anchor = CGRect(x: screen.frame.midX, y: screen.frame.midY - 70, width: 0, height: 140)
        await bubble.show(order[index], anchor: anchor, edge: .bottom)
    }

    private func end() {
        active = false
        updateTask?.cancel()
        bubble.hide()
        bubble.flush()
    }

    /// Regular apps as the system switcher lists them: most recently used first.
    private func appOrder() -> [NSRunningApplication] {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let known = recent + Self.zOrderPIDs().filter { !recent.contains($0) }
        let rank = Dictionary(known.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return apps.sorted { (rank[$0.processIdentifier] ?? .max) < (rank[$1.processIdentifier] ?? .max) }
    }

    /// Owners of on-screen windows, front to back: the best guess of recent-use order for apps
    /// activated before we started.
    private static func zOrderPIDs() -> [pid_t] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var seen = Set<pid_t>(), result: [pid_t] = []
        for window in info where (window[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = window[kCGWindowOwnerPID as String] as? pid_t, seen.insert(pid).inserted { result.append(pid) }
        }
        return result
    }

    /// Selected item of the system ⌘Tab switcher, read from the Dock's accessibility tree.
    private static func systemSelection() -> (String, CGRect)? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let children: [AXUIElement] = AX.value(AXUIElementCreateApplication(dock.processIdentifier), kAXChildrenAttribute) ?? []
        let lists = children.filter { AX.value($0, kAXRoleAttribute) as String? == kAXListRole }
        // The Dock's own icon list is always there; the switcher list exists only while ⌘Tab is open.
        let switcher = lists.first { (AX.value($0, kAXSubroleAttribute) as String?)?.contains("ProcessSwitcher") == true }
            ?? (lists.count > 1 ? lists.last : nil)
        #if DEBUG
        log.debug("⌘Tab AX: \(lists.count) lists, subroles \(lists.map { AX.value($0, kAXSubroleAttribute) as String? ?? "-" })")
        #endif
        guard let switcher else { return nil }
        let items: [AXUIElement] = AX.value(switcher, kAXChildrenAttribute) ?? []
        let selected = (AX.value(switcher, kAXSelectedChildrenAttribute) as [AXUIElement]?)?.first
            ?? items.first { AX.value($0, kAXSelectedAttribute) as Bool? == true }
        guard let selected, let title: String = AX.value(selected, kAXTitleAttribute), let frame = AX.frame(selected) else { return nil }
        return (title, frame)
    }
}

// MARK: - ⌥` model & view

@Observable
final class WindowSwitcherModel {
    struct Entry: Identifiable {
        var id: CGWindowID { window.id }
        let window: CatalogWindow
        let icon: NSImage?
        var image: CGImage?
    }

    private(set) var active = false
    private(set) var entries: [Entry] = []
    private(set) var selected = 0
    var onChoose: ((Int) -> Void)?

    func begin(entries: [Entry]) {
        active = true
        self.entries = entries
        selected = 0
    }

    func end() {
        active = false
        entries = []
    }

    func move(_ step: Int) {
        guard !entries.isEmpty else { return }
        selected = (selected + step + entries.count) % entries.count
    }

    func setImage(_ image: CGImage, for id: CGWindowID) {
        if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].image = image }
    }
}

private final class SwitchHostingView: NSHostingView<WindowSwitcherView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct WindowSwitcherView: View {
    let model: WindowSwitcherModel
    private static let card = CGSize(width: 220, height: 138)
    private static let columns = 4

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(Self.card.width), spacing: 14),
                            count: max(1, min(model.entries.count, Self.columns)))
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                card(entry, selected: index == model.selected)
                    .onTapGesture { model.onChoose?(index) }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        .padding(16) // room for the shadow
    }

    private func card(_ entry: WindowSwitcherModel.Entry, selected: Bool) -> some View {
        VStack(spacing: 6) {
            Group {
                if let image = entry.image {
                    Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else if let icon = entry.icon {
                    Image(nsImage: icon).resizable().frame(width: 64, height: 64).opacity(0.6)
                }
            }
            .frame(width: Self.card.width, height: Self.card.height)
            Text(entry.window.title).font(.callout).lineLimit(1).frame(width: Self.card.width)
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}
