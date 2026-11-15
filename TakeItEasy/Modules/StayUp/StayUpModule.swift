import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// Keeps the Mac awake (like Amphetamine/caffeinate): menu bar cup → pick a duration.
/// Uses a public IOPMAssertion, released on expiry, on "Disattiva" and on stop().
final class StayUpModule: TIEModule {
    let id = "stayup"
    let name = String(localized: "Stay Up")
    let summary = String(localized: "Tiene sveglio il Mac per un tempo scelto.")
    let symbol = "cup.and.saucer"
    let requiredPermissions: [TIEPermission] = []

    private let model = StayUpModel()
    private lazy var pin = PinnableStatusItem(moduleID: id, symbol: symbol, name: name) { [weak self] in self?.toggle() }
    private var panel: TransientPanel?

    func start() throws {
        pin.start()
        model.onChange = { [weak self] active in
            guard let self else { return }
            self.pin.setSymbol(active ? "cup.and.saucer.fill" : self.symbol)
        }
    }

    func stop() {
        panel?.close()
        model.deactivate()
        model.onChange = nil
        pin.stop()
    }

    func settingsView() -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 6) {
            PinToggle(pin)
            Text("Scegli per quanto tenere sveglio il Mac dal pannello principale (o dalla tazza, se la metti nella barra dei menu: piena = attivo). Con il coperchio chiuso il Mac dorme comunque, salvo monitor esterno e alimentatore collegati.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        })
    }

    func quickView() -> AnyView? { AnyView(StayUpView(model: model, compact: true)) }

    func toggle() {
        if let panel { return panel.close() }
        let panel = TransientPanel(content: StayUpView(model: model) { [weak self] in self?.panel?.close() }.panelChrome(width: 240))
        panel.onClose = { self.panel = nil } // close() drops this closure, breaking the cycle
        self.panel = panel
        panel.show(offset: CGVector(dx: 0, dy: -12))
    }
}

@Observable
final class StayUpModel {
    /// nil = off; .distantFuture = indefinitely.
    private(set) var until: Date?
    var allowDisplaySleep = UserDefaults.standard.bool(forKey: "stayup.allowDisplaySleep") {
        didSet {
            UserDefaults.standard.set(allowDisplaySleep, forKey: "stayup.allowDisplaySleep")
            if let until { activate(until: until) } // swap the assertion type, keep the deadline
        }
    }
    var onChange: ((Bool) -> Void)?

    private var assertion: IOPMAssertionID?
    private var timer: Timer?

    var isActive: Bool { until != nil }

    func activate(for duration: Duration?) {
        activate(until: duration.map { Date.now.addingTimeInterval(Double($0.components.seconds)) } ?? .distantFuture)
    }

    private func activate(until date: Date) {
        releaseAssertion()
        let type = allowDisplaySleep ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
        var id = IOPMAssertionID(0)
        guard IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "take-it-easy Stay Up" as CFString, &id) == kIOReturnSuccess else {
            Toast.show(String(localized: "Impossibile tenere sveglio il Mac."), symbol: "exclamationmark.triangle.fill")
            return deactivate()
        }
        assertion = id
        until = date
        timer?.invalidate()
        if date != .distantFuture {
            timer = Timer.scheduledTimer(withTimeInterval: date.timeIntervalSinceNow, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.deactivate() }
            }
        }
        onChange?(true)
    }

    /// Idempotent.
    func deactivate() {
        releaseAssertion()
        timer?.invalidate()
        timer = nil
        let wasActive = until != nil
        until = nil
        if wasActive { onChange?(false) }
    }

    private func releaseAssertion() {
        if let assertion { IOPMAssertionRelease(assertion) }
        assertion = nil
    }
}

private struct StayUpView: View {
    @Bindable var model: StayUpModel
    /// Main panel: one row of duration chips instead of a list.
    var compact = false
    var dismiss: () -> Void = {}

    private static let choices: [(String, Duration?)] = [
        (String(localized: "15 minuti"), .seconds(15 * 60)),
        (String(localized: "1 ora"), .seconds(3600)),
        (String(localized: "2 ore"), .seconds(2 * 3600)),
        (String(localized: "5 ore"), .seconds(5 * 3600)),
        (String(localized: "Finché non lo spengo"), nil),
    ]

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: model.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .foregroundStyle(model.isActive ? Color.accentColor : Color.primary)
                TimelineView(.periodic(from: .now, by: 1)) { _ in Text(status) }
                Spacer()
                if model.isActive {
                    Button(String(localized: "Spegni")) { model.deactivate() }.controlSize(.small)
                }
            }
            HStack(spacing: 4) {
                ForEach(Self.chips, id: \.0) { label, duration in
                    Button(label) { model.activate(for: duration) }.controlSize(.small)
                }
            }
        }
    }

    private static let chips: [(String, Duration?)] = [
        ("15m", .seconds(15 * 60)), ("1h", .seconds(3600)), ("2h", .seconds(2 * 3600)), ("5h", .seconds(5 * 3600)), ("∞", nil),
    ]

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: model.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                TimelineView(.periodic(from: .now, by: 1)) { _ in Text(status).font(.headline) }
            }
            Divider()
            ForEach(Self.choices, id: \.0) { label, duration in
                Button(label) { model.activate(for: duration); dismiss() }
                    .buttonStyle(.borderless)
            }
            if model.isActive {
                Button(String(localized: "Disattiva"), role: .destructive) { model.deactivate(); dismiss() }
                    .buttonStyle(.borderless)
            }
            Divider()
            Toggle(String(localized: "Lascia spegnere lo schermo"), isOn: $model.allowDisplaySleep)
                .toggleStyle(.checkbox)
        }
    }

    private var status: String {
        guard let until = model.until else { return String(localized: "Spento") }
        if until == .distantFuture { return String(localized: "Sveglio") }
        let left = max(0, Int(until.timeIntervalSinceNow))
        return String(localized: "Sveglio · \(left / 3600)h \(String(format: "%02d", left % 3600 / 60))m \(String(format: "%02d", left % 60))s")
    }
}
