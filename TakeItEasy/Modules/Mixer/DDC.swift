import CoreGraphics
import Foundation
import IOKit

/// DDC/CI brightness (VCP 0x10) for one external monitor, over IOAVService I²C (Apple Silicon only).
/// All I/O is blocking and slow (~50 ms), so it runs on a private serial queue; while a write is in
/// flight only the latest requested value is kept, so dragging a slider never piles up commands.
nonisolated final class DDCDisplay: @unchecked Sendable {
    private let service: CFTypeRef
    private let queue = DispatchQueue(label: "take-it-easy.ddc", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: UInt16?   // guarded by lock
    private var writing = false    // guarded by lock

    private static let chip: UInt32 = 0x37
    private static let hostAddress: UInt8 = 0x51
    private static let displayAddress: UInt8 = 0x6E
    private static let brightnessCode: UInt8 = 0x10

    init(service: CFTypeRef) { self.service = service }

    /// Blocking. Current and maximum brightness, or nil if the monitor doesn't answer DDC.
    func readBrightness() -> (current: UInt16, max: UInt16)? {
        for _ in 0..<3 {
            var request = Self.packet([0x01, Self.brightnessCode]) // 0x01 = Get VCP Feature
            guard PrivateAPI.i2cWrite(service, chip: Self.chip, offset: UInt32(Self.hostAddress), &request) else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            guard PrivateAPI.i2cRead(service, chip: Self.chip, offset: UInt32(Self.hostAddress), &reply) else { continue }
            // [src, len, 0x02 = VCP reply, result, code, type, max hi, max lo, cur hi, cur lo, checksum]
            guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == Self.brightnessCode else { continue }
            let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
            guard max > 0 else { continue }
            return (current, max)
        }
        return nil
    }

    /// Non-blocking; coalesces rapid calls.
    func setBrightness(_ value: UInt16) {
        lock.lock()
        pending = value
        let start = !writing
        writing = true
        lock.unlock()
        guard start else { return }
        queue.async { self.drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let value = pending else {
                writing = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            // 0x03 = Set VCP Feature. Sent twice: some monitors drop the first command.
            for _ in 0..<2 {
                var packet = Self.packet([0x03, Self.brightnessCode, UInt8(value >> 8), UInt8(value & 0xFF)])
                _ = PrivateAPI.i2cWrite(service, chip: Self.chip, offset: UInt32(Self.hostAddress), &packet)
                usleep(10_000)
            }
            usleep(40_000) // DDC/CI asks for ≥ 40 ms between commands
        }
    }

    /// Length byte + payload + checksum (XOR of destination, source and every byte).
    static func packet(_ payload: [UInt8]) -> [UInt8] {
        var bytes = [0x80 | UInt8(payload.count)] + payload
        bytes.append(bytes.reduce(displayAddress ^ hostAddress, ^))
        return bytes
    }

    // MARK: - Discovery

    /// Pairs each external IOAVService with an online CGDisplay.
    /// The I/O registry lists a display's framebuffer (with its EDID vendor/product) before its
    /// DCPAVServiceProxy, so each proxy is matched to the last framebuffer seen.
    static func discover(for displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: DDCDisplay] {
        var found: [(vendor: Int?, product: Int?, service: CFTypeRef)] = []
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }
        var last: (vendor: Int?, product: Int?) = (nil, nil)
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var buffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &buffer)
            let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name.contains("AppleCLCD2") || name.contains("IOMobileFramebufferShim") {
                let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any]
                let product = attributes?["ProductAttributes"] as? [String: Any]
                last = (product?["LegacyManufacturerID"] as? Int, product?["ProductID"] as? Int)
            } else if name == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                if location == "External", let service = PrivateAPI.avService(for: entry) {
                    found.append((last.vendor, last.product, service))
                }
            }
        }

        var result: [CGDirectDisplayID: DDCDisplay] = [:]
        let externals = displays.filter { CGDisplayIsBuiltin($0) == 0 }
        for display in externals {
            let vendor = Int(CGDisplayVendorNumber(display)), product = Int(CGDisplayModelNumber(display))
            if let i = found.firstIndex(where: { $0.vendor == vendor && $0.product == product }) {
                result[display] = DDCDisplay(service: found.remove(at: i).service)
            }
        }
        // Unmatched leftovers: with exactly one of each, they must belong together.
        let unmatched = externals.filter { result[$0] == nil }
        if unmatched.count == 1, found.count == 1 { result[unmatched[0]] = DDCDisplay(service: found[0].service) }
        return result
    }

    #if DEBUG
    static func selfCheck() {
        // Set brightness to 50: 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x32
        assert(packet([0x03, 0x10, 0x00, 0x32]) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x32])
        assert(packet([0x01, 0x10]).count == 4 && packet([0x01, 0x10])[0] == 0x82)
    }
    #endif
}
