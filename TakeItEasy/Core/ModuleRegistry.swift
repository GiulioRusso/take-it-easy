import SwiftUI

@Observable
final class ModuleRegistry {
    let modules: [any TIEModule]
    private(set) var enabled: Set<String>
    private(set) var running: Set<String> = []
    /// Last problem per module (missing permissions, start failure), shown in Settings.
    private(set) var issues: [String: String] = [:]

    private static let defaultsKey = "enabledModules"

    init(modules: [any TIEModule]) {
        self.modules = modules
        // Drop ids of renamed modules (peek, pulse, vitals…).
        enabled = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []).intersection(modules.map(\.id))
        Task { await startEnabledModules() }
    }

    func isEnabled(_ module: any TIEModule) -> Bool { enabled.contains(module.id) }

    func binding(for module: any TIEModule) -> Binding<Bool> {
        Binding(
            get: { self.isEnabled(module) },
            set: { on in Task { await self.setEnabled(module, on) } }
        )
    }

    func setEnabled(_ module: any TIEModule, _ on: Bool) async {
        if on {
            enabled.insert(module.id)
            persist()
            var missing = await PermissionCenter.missing(module.requiredPermissions)
            for p in missing where await PermissionCenter.request(p) {
                missing.removeAll { $0 == p }
            }
            guard missing.isEmpty else {
                // Keep the module disabled: the user re-enables it after granting in System Settings.
                enabled.remove(module.id)
                persist()
                issues[module.id] = String(localized: "Permessi mancanti: \(missing.map(\.displayName).joined(separator: ", "))")
                return
            }
            start(module)
        } else {
            enabled.remove(module.id)
            persist()
            module.stop()
            running.remove(module.id)
            issues[module.id] = nil
        }
    }

    func stopAll() {
        for module in modules where running.contains(module.id) { module.stop() }
        running.removeAll()
    }

    /// At launch never prompt: start only modules whose permissions are already granted.
    private func startEnabledModules() async {
        for module in modules where isEnabled(module) {
            let missing = await PermissionCenter.missing(module.requiredPermissions)
            if missing.isEmpty {
                start(module)
            } else {
                issues[module.id] = String(localized: "Permessi mancanti: \(missing.map(\.displayName).joined(separator: ", "))")
            }
        }
    }

    private func start(_ module: any TIEModule) {
        do {
            try module.start()
            running.insert(module.id)
            issues[module.id] = nil
        } catch {
            issues[module.id] = error.localizedDescription
        }
    }

    #if DEBUG
    /// Screenshot tour: shows the module as on (and running, if `start`), without saving or asking permissions.
    func startForScreenshots(_ module: any TIEModule, start: Bool) {
        enabled.insert(module.id)
        if start { self.start(module) } else { running.insert(module.id) }
    }
    #endif

    private func persist() {
        UserDefaults.standard.set(Array(enabled).sorted(), forKey: Self.defaultsKey)
    }
}
