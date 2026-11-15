import AppKit
import CoreAudio

/// Volume and mute per app via process taps, remembered per output device
/// (headphones ≠ speakers). A tap exists only for apps whose volume ≠ 100% or that are muted.
@Observable
final class AppVolumes {
    struct App: Identifiable {
        let id: String // grouping key: the app's bundle ID (helpers fold into their parent app)
        let name: String
        let icon: NSImage?
        var isPlaying: Bool
    }

    struct Setting: Codable, Equatable {
        var volume: Float = 1
        var muted = false
        var isDefault: Bool { volume >= 0.999 && !muted }
        var gain: Float { muted ? 0 : volume }
    }

    private(set) var apps: [App] = []
    private(set) var settings: [String: Setting] = [:]
    private(set) var lastError: String?

    private var processKeys: [AudioObjectID: String] = [:]
    private var taps: [AudioObjectID: ProcessTap] = [:]
    private var outputUID: String?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private static let defaultsKey = "mixer.appSettings"
    private static let processList = CA.address(kAudioHardwarePropertyProcessObjectList)
    private static let defaultOutput = CA.address(kAudioHardwarePropertyDefaultOutputDevice)

    func start() {
        guard listeners.isEmpty else { return } // idempotent
        outputUID = CA.uid(of: CA.defaultOutput)
        settings = Self.load(for: outputUID)
        listeners = [
            (Self.processList, CA.addListener(CA.system, Self.processList) { [weak self] in self?.refresh() }),
            (Self.defaultOutput, CA.addListener(CA.system, Self.defaultOutput) { [weak self] in self?.outputChanged() }),
        ]
        refresh()
    }

    /// Destroys every tap: all apps go back to 100%.
    func stop() {
        for (address, listener) in listeners { CA.removeListener(CA.system, address, listener) }
        listeners.removeAll()
        taps.values.forEach { $0.invalidate() }
        taps.removeAll()
    }

    func setting(_ key: String) -> Setting { settings[key] ?? Setting() }

    func setVolume(_ key: String, _ volume: Double) {
        settings[key, default: Setting()].volume = Float(min(max(volume, 0), 1))
        changed()
    }

    func toggleMute(_ key: String) {
        settings[key, default: Setting()].muted.toggle()
        changed()
    }

    func refresh() {
        let own = getpid()
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var byKey: [String: App] = [:]
        processKeys.removeAll()
        for process in CA.processes() where process.pid != own {
            let info = Self.appInfo(for: process, running: running)
            processKeys[process.id] = info.key
            var app = byKey[info.key] ?? App(id: info.key, name: info.name, icon: info.icon, isPlaying: false)
            app.isPlaying = app.isPlaying || process.isRunningOutput
            byKey[info.key] = app
        }
        // Show apps playing now, plus quiet ones the user has adjusted (so they can be reset).
        apps = byKey.values
            .filter { $0.isPlaying || !(settings[$0.id]?.isDefault ?? true) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        apply()
    }

    private func outputChanged() {
        taps.values.forEach { $0.invalidate() }
        taps.removeAll()
        outputUID = CA.uid(of: CA.defaultOutput)
        settings = Self.load(for: outputUID)
        refresh()
    }

    private func changed() {
        Self.save(settings, for: outputUID)
        apply()
    }

    /// Creates, updates or destroys taps so they match `settings`.
    private func apply() {
        var wanted: [AudioObjectID: Float] = [:]
        for (process, key) in processKeys {
            if let setting = settings[key], !setting.isDefault { wanted[process] = setting.gain }
        }
        for (process, tap) in taps where wanted[process] == nil {
            tap.invalidate()
            taps[process] = nil
        }
        guard let outputUID else { return }
        for (process, gain) in wanted {
            if let tap = taps[process] {
                tap.volume = gain
                continue
            }
            do {
                taps[process] = try ProcessTap(process: process, outputUID: outputUID, volume: gain)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Helpers (e.g. "com.google.Chrome.helper") fold into the regular app whose bundle ID prefixes theirs.
    private static func appInfo(for process: CA.Process, running: [NSRunningApplication]) -> (key: String, name: String, icon: NSImage?) {
        if let app = running.first(where: { $0.processIdentifier == process.pid }), let id = app.bundleIdentifier {
            return (id, app.localizedName ?? id, app.icon)
        }
        if let bundleID = process.bundleID,
           let parent = running.filter({ app in app.bundleIdentifier.map { bundleID.hasPrefix($0) } ?? false })
               .max(by: { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }),
           let id = parent.bundleIdentifier {
            return (id, parent.localizedName ?? id, parent.icon)
        }
        let other = NSRunningApplication(processIdentifier: process.pid)
        let key = process.bundleID ?? "pid.\(process.pid)"
        let name = other?.localizedName ?? process.bundleID?.components(separatedBy: ".").last ?? "PID \(process.pid)"
        return (key, name, other?.icon)
    }

    // MARK: - Persistence: [output device UID: [app key: Setting]]

    private static func loadAll() -> [String: [String: Setting]] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: Setting]].self, from: data)) ?? [:]
    }

    private static func load(for device: String?) -> [String: Setting] {
        device.flatMap { loadAll()[$0] } ?? [:]
    }

    private static func save(_ settings: [String: Setting], for device: String?) {
        guard let device else { return }
        var all = loadAll()
        all[device] = settings.filter { !$0.value.isDefault }
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: defaultsKey)
    }
}
