import SwiftUI

enum TIEPermission: Hashable {
    case accessibility
    case screenRecording
    case appleEvents(bundleID: String)
    case audioCapture

    var displayName: String {
        switch self {
        case .accessibility: String(localized: "Accessibilità")
        case .screenRecording: String(localized: "Registrazione schermo")
        case .appleEvents(let bundleID): String(localized: "Automazione (\(bundleID))")
        case .audioCapture: String(localized: "Registrazione audio di sistema")
        }
    }
}

// Not `Identifiable`: that nonisolated conformance clashes with MainActor default isolation; use `id: \.id`.
protocol TIEModule: AnyObject {
    var id: String { get }
    var name: String { get }
    var summary: String { get }
    /// SF Symbol name.
    var symbol: String { get }
    var requiredPermissions: [TIEPermission] { get }
    /// Must be idempotent.
    func start() throws
    /// Must be idempotent and restore any system state the module changed.
    func stop()
    func settingsView() -> AnyView
    /// Compact controls shown in the main menu bar panel while the module runs; nil = tile only.
    func quickView() -> AnyView?
}

extension TIEModule {
    func quickView() -> AnyView? { nil }
}
