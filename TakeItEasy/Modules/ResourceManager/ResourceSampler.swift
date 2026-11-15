import Darwin
import Foundation
import IOKit

nonisolated struct ResourceSnapshot: Sendable {
    struct Power: Sendable {
        var watts: Double?
        var batteryPercent: Int?
        var charging = false
        var onAC = false
    }

    struct Disk: Sendable, Identifiable {
        var id: URL { url }
        let url: URL
        let name: String
        let free: Int64
        let total: Int64
        let ejectable: Bool
    }

    struct AppUsage: Sendable, Identifiable {
        var id: String { name + String(pid) }
        let pid: pid_t      // the app's main process (for its icon)
        let name: String
        let cpu: Double     // percent, 100 = one core (as in Activity Monitor)
        let memory: UInt64  // physical footprint, bytes (Activity Monitor's "Memoria")
    }

    /// A connected Bluetooth device's battery (AirPods have left, right and case).
    struct Battery: Sendable, Identifiable {
        var id: String { name }
        let name: String
        let symbol: String
        let levels: [(label: String, percent: Int)]
    }

    /// nil on the first sample (rates need two readings).
    var cpu: Double?
    /// Top apps by CPU and by memory (same rows, different order and cut).
    var apps: [AppUsage] = []
    var memoryApps: [AppUsage] = []
    var cores: [Double] = []
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var gpu: Double?
    var power: Power?
    var download: Double? // bytes/s
    var upload: Double?
    var disks: [Disk] = []
    var batteries: [Battery] = []
}

/// Reads system stats with public APIs only. Keeps the previous reading to compute rates,
/// so use one instance from one task at a time.
nonisolated final class ResourceSampler: @unchecked Sendable {
    private var lastTicks: [[Int64]]?
    private var lastNet: (bytes: [String: (rx: UInt32, tx: UInt32)], time: Date)?
    private var lastProcessCPU: (ns: [pid_t: UInt64], time: UInt64)?
    private var lastBatteries: (value: [ResourceSnapshot.Battery], time: Date)?
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// `apps`: regular apps (pid → name), gathered on the main thread by the caller.
    func sample(apps: [pid_t: String] = [:]) -> ResourceSnapshot {
        var s = ResourceSnapshot()
        (s.cpu, s.cores) = cpu()
        (s.apps, s.memoryApps) = appUsage(apps)
        s.memoryUsed = memoryUsed()
        s.gpu = gpu()
        s.power = power()
        (s.download, s.upload) = network()
        s.disks = externalDisks()
        s.batteries = batteries()
        return s
    }

    // MARK: CPU

    private func cpu() -> (Double?, [Double]) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return (nil, []) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        let ticks: [[Int64]] = (0..<Int(count)).map { core in
            [CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_NICE, CPU_STATE_IDLE].map { Int64(UInt32(bitPattern: info[core * states + Int($0)])) }
        }
        defer { lastTicks = ticks }
        guard let lastTicks, lastTicks.count == ticks.count else { return (nil, []) }
        var busyAll: Int64 = 0, totalAll: Int64 = 0
        let cores = zip(ticks, lastTicks).map { now, before -> Double in
            let d = zip(now, before).map { $0 - $1 }
            let busy = d[0] + d[1] + d[2], total = busy + d[3]
            busyAll += busy
            totalAll += total
            return total > 0 ? Double(busy) / Double(total) : 0
        }
        return (totalAll > 0 ? Double(busyAll) / Double(totalAll) : 0, cores)
    }

    // MARK: CPU per app

    /// CPU time and memory footprint of every process we can read (our user's), attributed to the nearest ancestor that is
    /// a regular app (so "Google Chrome Helper" counts as Chrome); others are listed by process name.
    private func appUsage(_ apps: [pid_t: String]) -> (cpu: [ResourceSnapshot.AppUsage], memory: [ResourceSnapshot.AppUsage]) {
        let processes = Self.allProcesses()
        let parent = Dictionary(processes.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        var ns: [pid_t: UInt64] = [:]
        var footprint: [pid_t: UInt64] = [:]
        for process in processes {
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(process.pid, RUSAGE_INFO_V2, $0) }
            } == 0
            // rusage times are mach ticks on Apple Silicon: convert to nanoseconds.
            guard ok else { continue }
            ns[process.pid] = (usage.ri_user_time + usage.ri_system_time) * Self.timebase.numer / Self.timebase.denom
            footprint[process.pid] = usage.ri_phys_footprint
        }
        let now = mach_absolute_time() * Self.timebase.numer / Self.timebase.denom
        defer { lastProcessCPU = (ns, now) }
        let last = lastProcessCPU.flatMap { now > $0.time ? $0 : nil } // nil on the first sample: memory only
        let elapsed = last.map { Double(now - $0.time) } ?? 1

        func owner(of pid: pid_t) -> pid_t {
            if apps[pid] != nil { return pid }
            var cursor = pid, hops = 0
            while let up = parent[cursor], up > 1, hops < 16 {
                if apps[up] != nil { return up }
                cursor = up
                hops += 1
            }
            return pid
        }
        // Keyed by the owning app's (or the process's own) pid.
        var cpu: [pid_t: Double] = [:], memory: [pid_t: UInt64] = [:]
        for (pid, bytes) in footprint {
            let o = owner(of: pid)
            memory[o, default: 0] += bytes
            if let time = ns[pid], let before = last?.ns[pid], time > before {
                cpu[o, default: 0] += Double(time - before) / elapsed * 100
            }
        }
        // Apps stay one row each; other processes merge by name (five copies of a service = one row).
        let shortNames = Dictionary(processes.map { ($0.pid, $0.name) }, uniquingKeysWith: { a, _ in a })
        var rows: [String: ResourceSnapshot.AppUsage] = [:]
        for (pid, bytes) in memory {
            let isApp = apps[pid] != nil
            let name = apps[pid] ?? Self.processName(pid) ?? shortNames[pid] ?? "PID \(pid)"
            let key = isApp ? "app.\(pid)" : "proc.\(name)"
            rows[key] = ResourceSnapshot.AppUsage(pid: isApp ? pid : 0, name: name,
                                               cpu: (rows[key]?.cpu ?? 0) + (cpu[pid] ?? 0),
                                               memory: (rows[key]?.memory ?? 0) + bytes)
        }
        let all = Array(rows.values)
        let byCPU = last == nil ? [] : all.filter { $0.cpu >= 0.5 }.sorted { $0.cpu > $1.cpu }.prefix(10)
        let byMemory = all.sorted { $0.memory > $1.memory }.prefix(10)
        return (Array(byCPU), Array(byMemory))
    }

    /// Full executable name (p_comm is cut at 16 characters).
    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Every process with its parent and short name, in one sysctl call.
    private static func allProcesses() -> [(pid: pid_t, ppid: pid_t, name: String)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var list = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32) // room for new processes
        size = list.count * stride
        guard sysctl(&mib, 3, &list, &size, nil, 0) == 0 else { return [] }
        return list.prefix(size / stride).map { info in
            var comm = info.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return (info.kp_proc.p_pid, info.kp_eproc.e_ppid, name)
        }
    }

    // MARK: Memory ("Memoria utilizzata" as in Activity Monitor: app + wired + compressed)

    private func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pages = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
            + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * UInt64(getpagesize())
    }

    // MARK: GPU (IOAccelerator performance statistics)

    private func gpu() -> Double? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Int?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            if let value = stats?["Device Utilization %"] as? Int { best = max(best ?? 0, value) }
        }
        return best.map { Double($0) / 100 }
    }

    // MARK: Power (AppleSmartBattery)

    private func power() -> ResourceSnapshot.Power? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil } // desktop Mac
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        func number(_ key: String) -> Int64? { (dict[key] as? NSNumber)?.int64Value }
        var p = ResourceSnapshot.Power()
        p.onAC = dict["ExternalConnected"] as? Bool ?? false
        p.charging = dict["IsCharging"] as? Bool ?? false
        if let current = number("CurrentCapacity"), let max = number("MaxCapacity"), max > 0 {
            // Apple Silicon reports percent directly (max = 100); Intel reports mAh.
            p.batteryPercent = Int(Double(current) / Double(max) * 100)
        }
        let telemetry = dict["PowerTelemetryData"] as? [String: Any]
        if p.onAC, let systemIn = (telemetry?["SystemPowerIn"] as? NSNumber)?.doubleValue, systemIn > 0 {
            p.watts = systemIn / 1000 // mW
        } else if let volts = number("Voltage"), let amps = number("InstantAmperage") ?? number("Amperage") {
            p.watts = abs(Double(volts) * Double(amps)) / 1_000_000 // mV × mA
        }
        return p
    }

    // MARK: Network (Wi-Fi/Ethernet interfaces)

    private func network() -> (Double?, Double?) {
        var bytes: [String: (rx: UInt32, tx: UInt32)] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return (nil, nil) }
        defer { freeifaddrs(head) }
        var cursor = head
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            // ponytail: "en*" covers Wi-Fi and Ethernet; VPN (utun) would double-count traffic.
            guard name.hasPrefix("en") else { continue }
            bytes[name] = (data.pointee.ifi_ibytes, data.pointee.ifi_obytes)
        }
        let now = Date()
        defer { lastNet = (bytes, now) }
        guard let lastNet else { return (nil, nil) }
        let seconds = now.timeIntervalSince(lastNet.time)
        guard seconds > 0 else { return (nil, nil) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for (name, value) in bytes {
            guard let before = lastNet.bytes[name] else { continue }
            // 32-bit counters wrap at 4 GB: wrapping subtraction still gives the right delta.
            rx += UInt64(value.rx &- before.rx)
            tx += UInt64(value.tx &- before.tx)
        }
        return (Double(rx) / seconds, Double(tx) / seconds)
    }

    // MARK: Bluetooth batteries

    /// Every 30 s: `system_profiler` takes ~0.15 s and battery levels move slowly.
    #if DEBUG
    /// Screenshot tour: fixed devices instead of the user's (their names often include the owner's name).
    nonisolated(unsafe) static var demoBatteries: [ResourceSnapshot.Battery]?
    #endif

    private func batteries() -> [ResourceSnapshot.Battery] {
        #if DEBUG
        if let demo = Self.demoBatteries { return demo }
        #endif
        if let lastBatteries, Date().timeIntervalSince(lastBatteries.time) < 30 { return lastBatteries.value }
        let value = Self.readBatteries()
        lastBatteries = (value, Date())
        return value
    }

    // ponytail: system_profiler is the only public source with AirPods levels; IOBluetooth has none.
    private static func readBatteries() -> [ResourceSnapshot.Battery] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseBatteries(data)
    }

    static func parseBatteries(_ data: Data) -> [ResourceSnapshot.Battery] {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let controller = (root?["SPBluetoothDataType"] as? [[String: Any]])?.first
        let connected = controller?["device_connected"] as? [[String: [String: Any]]] ?? []
        let parts: [(key: String, label: String)] = [
            ("device_batteryLevelMain", ""), ("device_batteryLevelLeft", "L"),
            ("device_batteryLevelRight", "R"), ("device_batteryLevelCase", String(localized: "Custodia")),
        ]
        return connected.flatMap { $0 }.compactMap { name, info in
            let levels = parts.compactMap { part -> (label: String, percent: Int)? in
                guard let text = info[part.key] as? String, let percent = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { return nil }
                return (part.label, percent)
            }
            guard !levels.isEmpty else { return nil }
            let symbol = switch (info["device_minorType"] as? String ?? "").lowercased() {
            case let t where t.contains("headphone") || t.contains("headset"): "airpodspro"
            case let t where t.contains("mouse"): "magicmouse"
            case let t where t.contains("keyboard"): "keyboard"
            case let t where t.contains("trackpad"): "rectangle.and.hand.point.up.left"
            default: "battery.75percent"
            }
            return ResourceSnapshot.Battery(name: name, symbol: symbol, levels: levels)
        }
        .sorted { $0.name < $1.name }
    }

    #if DEBUG
    static func selfCheck() {
        let json = #"{"SPBluetoothDataType":[{"device_connected":[{"AirPods":{"device_batteryLevelLeft":"91%","device_batteryLevelRight":"100%","device_batteryLevelCase":"36%","device_minorType":"Headphones"}},{"iPhone":{"device_minorType":"Phone"}}]}]}"#
        let b = parseBatteries(Data(json.utf8))
        assert(b.count == 1 && b[0].levels.map(\.percent) == [91, 100, 36] && b[0].symbol == "airpodspro", "battery parse")
    }
    #endif

    // MARK: External disks

    private func externalDisks() -> [ResourceSnapshot.Disk] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                      .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsInternal == false || v.volumeIsRemovable == true,
                  url.path != "/" else { return nil }
            return ResourceSnapshot.Disk(url: url, name: v.volumeName ?? url.lastPathComponent,
                                      free: v.volumeAvailableCapacityForImportantUsage ?? 0,
                                      total: Int64(v.volumeTotalCapacity ?? 0),
                                      ejectable: v.volumeIsEjectable ?? false)
        }
    }
}
