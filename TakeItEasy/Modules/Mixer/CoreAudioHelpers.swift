import AudioToolbox
import CoreAudio
import Foundation

/// Thin wrappers over the CoreAudio property API.
nonisolated enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    static func set<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }

    static func array<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ zero: T) -> [T] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        let status = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return values
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    // MARK: - Devices

    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    static var defaultOutput: AudioDeviceID {
        get { get(system, address(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0)) ?? 0 }
        set { set(system, address(kAudioHardwarePropertyDefaultOutputDevice), newValue) }
    }

    static var defaultInput: AudioDeviceID {
        Self.get(system, address(kAudioHardwarePropertyDefaultInputDevice), AudioDeviceID(0)) ?? 0
    }

    private static let inputMute = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput)
    private static let inputVolumeAddress = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput)

    /// Mute switch if the device has one, else "volume at 0".
    static func isInputMuted(_ device: AudioDeviceID) -> Bool {
        if let mute = get(device, inputMute, UInt32(0)) { return mute == 1 }
        return get(device, inputVolumeAddress, Float32(1)) == 0
    }

    /// Returns false if the device has no settable mute (the caller falls back to `setInputVolume`).
    @discardableResult
    static func setInputMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        set(device, inputMute, UInt32(muted ? 1 : 0))
    }

    static func inputVolume(_ device: AudioDeviceID) -> Float? { get(device, inputVolumeAddress, Float32(0)) }
    static func setInputVolume(_ device: AudioDeviceID, _ value: Float) { set(device, inputVolumeAddress, Float32(value)) }

    static func outputDevices() -> [Device] {
        array(system, address(kAudioHardwarePropertyDevices), AudioDeviceID(0)).compactMap { id in
            let streams = array(id, address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), AudioStreamID(0))
            guard !streams.isEmpty, let uid = uid(of: id) else { return nil }
            // Hide our own private aggregate devices and other hidden ones.
            if get(id, address(kAudioDevicePropertyIsHidden), UInt32(0)) == 1 { return nil }
            return Device(id: id, uid: uid, name: string(id, address(kAudioObjectPropertyName)) ?? uid)
        }
    }

    static func uid(of device: AudioDeviceID) -> String? {
        string(device, address(kAudioDevicePropertyDeviceUID))
    }

    // MARK: - Volume (virtual main volume, falling back to the two front channels)

    private static let mainVolume = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)

    static func volume(_ device: AudioDeviceID) -> Float? {
        if let v = get(device, mainVolume, Float32(0)) { return v }
        let channels = [1, 2].compactMap {
            get(device, address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, UInt32($0)), Float32(0))
        }
        return channels.isEmpty ? nil : channels.reduce(0, +) / Float(channels.count)
    }

    static func setVolume(_ device: AudioDeviceID, _ value: Float) {
        if set(device, mainVolume, Float32(value)) { return }
        for channel in [1, 2] {
            set(device, address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, UInt32(channel)), Float32(value))
        }
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool {
        get(device, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), UInt32(0)) == 1
    }

    static func setMuted(_ device: AudioDeviceID, _ muted: Bool) {
        set(device, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), UInt32(muted ? 1 : 0))
    }

    // MARK: - Processes (macOS 14.2+)

    struct Process {
        let id: AudioObjectID
        let pid: pid_t
        let bundleID: String?
        let isRunningOutput: Bool
    }

    static func processes() -> [Process] {
        array(system, address(kAudioHardwarePropertyProcessObjectList), AudioObjectID(0)).compactMap { id in
            guard let pid = get(id, address(kAudioProcessPropertyPID), pid_t(0)) else { return nil }
            let bundleID = string(id, address(kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 }
            let running = get(id, address(kAudioProcessPropertyIsRunningOutput), UInt32(0)) == 1
            return Process(id: id, pid: pid, bundleID: bundleID, isRunningOutput: running)
        }
    }

    // MARK: - Listeners

    /// Registers `block` on the main queue; returns a token for `removeListener`.
    static func addListener(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
                            _ block: @escaping @MainActor () -> Void) -> AudioObjectPropertyListenerBlock {
        var address = address
        let listener: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { block() } }
        AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, listener)
        return listener
    }

    static func removeListener(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
                               _ listener: @escaping AudioObjectPropertyListenerBlock) {
        var address = address
        AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, listener)
    }
}
