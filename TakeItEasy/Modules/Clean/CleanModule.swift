import AppKit
import SwiftUI

/// Locks the keyboard (keys, modifiers, media keys) for a while so it can be wiped.
/// Ends on its own, or with the "Fine" button (the mouse keeps working).
final class CleanModule: TIEModule {
    let id = "clean"
    let name = String(localized: "Pulizia")
    let summary = String(localized: "Blocca la tastiera per pulirla.")
    let symbol = "sparkles"
    let requiredPermissions: [TIEPermission] = [.accessibility]

    private let model = CleanModel()

    func start() throws {}
    func stop() { model.finish() }

    func settingsView() -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 6) {
            CleanDurationPicker()
            Text("Avvia dal pannello principale. Il mouse e il trackpad restano attivi per premere «Fine». Il tasto di accensione e Touch ID non si possono bloccare.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        })
    }

    func quickView() -> AnyView? { AnyView(CleanQuickView(model: model)) }
}

private enum CleanDuration {
    static let key = "clean.seconds"
    static var current: Int { UserDefaults.standard.object(forKey: key) as? Int ?? 60 }
}

@Observable
final class CleanModel {
    private(set) var until: Date?
    @ObservationIgnored private var panel: CursorPanel?
    @ObservationIgnored private var timer: Timer?
    // NX_SYSDEFINED (14) carries volume, brightness and media keys.
    @ObservationIgnored private let tap = EventTap(events: [.keyDown, .keyUp, .flagsChanged, CGEventType(rawValue: 14)!]) { _ in true }

    func begin() {
        guard until == nil else { return }
        do { try tap.start() } catch {
            return Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
        let end = Date.now.addingTimeInterval(Double(CleanDuration.current))
        until = end
        let panel = CursorPanel(content: CleanOverlay(model: self))
        if let screen = NSScreen.main { panel.show(centeredAt: CGPoint(x: screen.frame.midX, y: screen.frame.midY)) }
        panel.makeKey()
        self.panel = panel
        timer = Timer.scheduledTimer(withTimeInterval: end.timeIntervalSinceNow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    /// Idempotent.
    func finish() {
        tap.stop()
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        if until != nil { Toast.show(String(localized: "Tastiera sbloccata"), symbol: "keyboard") }
        until = nil
    }
}

private struct CleanQuickView: View {
    let model: CleanModel
    @Environment(\.closePanel) private var closePanel

    var body: some View {
        HStack {
            Image(systemName: "sparkles")
            Text("Pulizia tastiera")
            Spacer()
            Button(String(localized: "Blocca \(CleanDuration.current) s")) {
                closePanel()
                model.begin()
            }
            .controlSize(.small)
        }
    }
}

private struct CleanOverlay: View {
    let model: CleanModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "keyboard").font(.system(size: 54, weight: .light))
            Text("Tastiera bloccata").font(.title2.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(String(localized: "Si sblocca tra \(max(0, Int(model.until?.timeIntervalSinceNow.rounded(.up) ?? 0))) s"))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Button(String(localized: "Fine")) { model.finish() }
                .controlSize(.large).keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(10)
    }
}

private struct CleanDurationPicker: View {
    @AppStorage(CleanDuration.key) private var seconds = 60

    var body: some View {
        Picker(String(localized: "Durata"), selection: $seconds) {
            Text("30 s").tag(30)
            Text("1 min").tag(60)
            Text("2 min").tag(120)
        }
    }
}
