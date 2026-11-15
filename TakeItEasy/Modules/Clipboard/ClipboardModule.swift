import AppKit
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let clipboard = Self("clipboard", default: .init(.v, modifiers: [.control, .shift]))
}

/// Local clipboard history: hotkey → list at the cursor, type to filter, Return pastes into the front app.
final class ClipboardModule: TIEModule {
    let id = "clipboard"
    let name = String(localized: "Clipboard")
    let summary = String(localized: "Storico degli appunti, voci fissate, incolla come testo semplice.")
    let symbol = "doc.on.clipboard"
    let requiredPermissions: [TIEPermission] = [.accessibility] // to send ⌘V to the front app

    private let history = ClipboardHistory()
    private var timer: Timer?
    private var panel: TransientPanel?

    init() {
        #if DEBUG
        ClipboardHistory.selfCheck()
        #endif
    }

    func start() throws {
        guard timer == nil else { return }
        history.load()
        history.skipCurrent()
        // ponytail: polling is how every clipboard manager does it; NSPasteboard has no change notification.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.history.poll() }
        }
        timer?.tolerance = 0.25 // lets macOS batch the wakeup with others
        KeyboardShortcuts.onKeyUp(for: .clipboard) { [weak self] in self?.toggle() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        KeyboardShortcuts.removeHandler(for: .clipboard)
        panel?.close()
    }

    func settingsView() -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 6) {
            KeyboardShortcuts.Recorder(String(localized: "Apri lo storico:"), name: .clipboard)
            Text("Digita per filtrare, ↑↓ per scegliere, ↩ incolla, ⇧↩ incolla come testo semplice. Clic destro su una voce per fissarla o eliminarla. Le password copiate dai gestori di password non vengono salvate. Lo storico resta solo su questo Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "Svuota storico (tranne le voci fissate)"), role: .destructive) { [history] in history.clear() }
        })
    }

    func quickView() -> AnyView? { AnyView(ClipboardQuickView(history: history)) }

    #if DEBUG
    /// Screenshot tour: sample clips instead of the real history (nothing is read or saved).
    func startDemo() {
        history.showDemo([
            Clip(text: "brew install gh", date: .now.addingTimeInterval(-40)),
            Clip(text: "#4F8CFF", date: .now.addingTimeInterval(-300)),
            Clip(text: "https://github.com/take-it-easy/releases", date: .now.addingTimeInterval(-1_200)),
            Clip(text: "Ship v1.0 on Friday, then take it easy 🌴", date: .now.addingTimeInterval(-5_400)),
            Clip(text: "Meeting notes: per-app volume, eyedropper, keyboard cleaning", date: .now.addingTimeInterval(-86_000)),
            Clip(text: "ssh build@studio.local", date: .now.addingTimeInterval(-200_000), pinned: true),
        ])
    }
    #endif

    func toggle() {
        if let panel { return panel.close() }
        let state = ClipboardPanelState()
        let paste: (Clip, Bool) -> Void = { [weak self] clip, plain in
            self?.panel?.close()
            self?.history.paste(clip, plain: plain)
        }
        let panel = TransientPanel(content: ClipboardPanelView(history: history, state: state, paste: paste).panelChrome(width: 380))
        panel.onEvent = { [history] event in
            guard event.type == .keyDown else { return false }
            let items = history.filtered(state.query)
            switch event.keyCode {
            case 125: state.selection = min(state.selection + 1, max(items.count - 1, 0)) // ↓
            case 126: state.selection = max(state.selection - 1, 0)                     // ↑
            case 36, 76:                                                                  // Return, Enter
                if items.indices.contains(state.selection) { paste(items[state.selection], event.modifierFlags.contains(.shift)) }
            default: return false // typing goes to the search field
            }
            return true
        }
        panel.onClose = { self.panel = nil } // close() drops this closure, breaking the cycle
        self.panel = panel
        panel.show()
    }
}

// MARK: - History

nonisolated struct Clip: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let text: String
    /// Rich text as copied (RTF), pasted unless "plain" is asked.
    var rtf: Data?
    var date = Date()
    var pinned = false
}

@Observable
final class ClipboardHistory {
    private(set) var clips: [Clip] = []
    private var changeCount = NSPasteboard.general.changeCount

    private static let limit = 50
    private static let maxLength = 200_000
    /// nspasteboard.org markers set by password managers and other apps for "don't record this".
    private static let skipTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
    ]

    private static var fileURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "take-it-easy", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "clipboard.json")
    }

    /// Pinned first, then most recent.
    func filtered(_ query: String) -> [Clip] {
        let all = clips.filter(\.pinned) + clips.filter { !$0.pinned }
        return query.isEmpty ? all : all.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    /// Don't record what was already on the clipboard before the module started.
    func skipCurrent() { changeCount = NSPasteboard.general.changeCount }

    func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        let types = Set(pasteboard.types?.map(\.rawValue) ?? [])
        guard types.isDisjoint(with: Self.skipTypes),
              let text = pasteboard.string(forType: .string) else { return }
        add(Clip(text: text, rtf: pasteboard.data(forType: .rtf)))
    }

    /// Same text again moves to the top (keeping its pin).
    func add(_ clip: Clip) {
        guard !clip.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, clip.text.count <= Self.maxLength else { return }
        var clip = clip
        if let i = clips.firstIndex(where: { $0.text == clip.text }) {
            clip.pinned = clips[i].pinned
            clips.remove(at: i)
        }
        clips.insert(clip, at: 0)
        clips = Self.capped(clips)
        save()
    }

    /// Keeps every pinned clip and the newest `limit` unpinned ones (clips are newest first).
    static func capped(_ clips: [Clip]) -> [Clip] {
        var unpinned = 0
        return clips.filter { clip in
            if clip.pinned { return true }
            unpinned += 1
            return unpinned <= limit
        }
    }

    #if DEBUG
    func showDemo(_ clips: [Clip]) { self.clips = clips }
    #endif

    func togglePin(_ clip: Clip) {
        guard let i = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[i].pinned.toggle()
        save()
    }

    func delete(_ clip: Clip) {
        clips.removeAll { $0.id == clip.id }
        save()
    }

    func clear() {
        clips.removeAll { !$0.pinned }
        save()
    }

    func copy(_ clip: Clip, plain: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !plain, let rtf = clip.rtf { pasteboard.setData(rtf, forType: .rtf) }
        pasteboard.setString(clip.text, forType: .string)
        add(Clip(text: clip.text, rtf: plain ? nil : clip.rtf)) // to the top
        changeCount = pasteboard.changeCount
    }

    /// Copies, then sends ⌘V to the frontmost app (our panels never activate, so it's still the user's app).
    func paste(_ clip: Clip, plain: Bool) {
        copy(clip, plain: plain)
        Task {
            try? await Task.sleep(for: .milliseconds(60)) // let the panel give keyboard focus back
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: down) // V
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let saved = try? JSONDecoder().decode([Clip].self, from: data) else { return }
        clips = saved
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(clips) else { return }
        let url = Self.fileURL
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) // only the user
    }

    #if DEBUG
    static func selfCheck() {
        let h = ClipboardHistory()
        var clips = (0..<(limit + 5)).reversed().map { Clip(text: "t\($0)") }
        clips[clips.count - 1].pinned = true // oldest, pinned: must survive the cap
        let pinned = clips.last!
        h.clips = capped(clips)
        assert(h.clips.count == limit + 1 && h.clips.contains(pinned), "clipboard cap keeps pins")
        assert(h.filtered("").first == pinned, "pinned first")
        assert(h.filtered("T5").allSatisfy { $0.text.contains("5") }, "filter")
    }
    #endif
}

// MARK: - Views

@Observable
final class ClipboardPanelState {
    var query = "" { didSet { selection = 0 } }
    var selection = 0
}

private struct ClipboardPanelView: View {
    let history: ClipboardHistory
    @Bindable var state: ClipboardPanelState
    let paste: (Clip, Bool) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = history.filtered(state.query)
        VStack(alignment: .leading, spacing: 8) {
            TextField(String(localized: "Cerca negli appunti"), text: $state.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            if items.isEmpty {
                Text(history.clips.isEmpty ? String(localized: "Ancora niente: copia qualcosa.") : String(localized: "Nessun risultato."))
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.prefix(50).enumerated()), id: \.element.id) { index, clip in
                            ClipRow(clip: clip, selected: index == state.selection)
                                .id(clip.id)
                                .onTapGesture { paste(clip, NSEvent.modifierFlags.contains(.shift)) }
                                .contextMenu {
                                    Button(clip.pinned ? String(localized: "Togli dalle fissate") : String(localized: "Fissa")) { history.togglePin(clip) }
                                    Button(String(localized: "Incolla come testo semplice")) { paste(clip, true) }
                                    Button(String(localized: "Elimina"), role: .destructive) { history.delete(clip) }
                                }
                        }
                    }
                }
                .frame(height: min(CGFloat(max(items.count, 1)) * 34, 340))
                .onChange(of: state.selection) {
                    if items.indices.contains(state.selection) { proxy.scrollTo(items[state.selection].id) }
                }
            }
        }
        .onAppear { searchFocused = true }
    }
}

private struct ClipRow: View {
    let clip: Clip
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            if clip.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
            Text(clip.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ⏎ "))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text(clip.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(.caption2).foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

/// In the main panel: the last three clips, click to copy (the panel closes; paste with ⌘V).
private struct ClipboardQuickView: View {
    let history: ClipboardHistory
    @Environment(\.closePanel) private var closePanel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "doc.on.clipboard")
                Text("Appunti")
                Spacer()
                if let shortcut = KeyboardShortcuts.getShortcut(for: .clipboard) {
                    Text(shortcut.description).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(history.filtered("").prefix(3)) { clip in
                Button {
                    history.copy(clip)
                    closePanel()
                    Toast.show(String(localized: "Copiato"))
                } label: {
                    ClipRow(clip: clip, selected: false).frame(height: 24)
                }
                .buttonStyle(.plain)
            }
            if history.clips.isEmpty {
                Text("Ancora niente: copia qualcosa.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
