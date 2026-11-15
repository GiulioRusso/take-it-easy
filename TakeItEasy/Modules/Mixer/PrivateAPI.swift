import CoreGraphics
import Foundation
import IOKit

/// All private API used by Mixer, loaded at runtime with dlopen/dlsym.
/// Every entry point is optional: if a symbol is missing (future macOS, Intel Mac), callers fall back.
nonisolated enum PrivateAPI {
    // MARK: DisplayServices (built-in and Apple displays)

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

    nonisolated(unsafe) private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    private static let getBrightness: GetBrightness? = symbol(displayServices, "DisplayServicesGetBrightness")
    private static let setBrightness: SetBrightness? = symbol(displayServices, "DisplayServicesSetBrightness")
    private static let canChangeBrightness: CanChangeBrightness? = symbol(displayServices, "DisplayServicesCanChangeBrightness")

    static func nativeBrightnessSupported(_ display: CGDirectDisplayID) -> Bool {
        canChangeBrightness?(display) == true && getBrightness != nil && setBrightness != nil
    }

    static func nativeBrightness(_ display: CGDirectDisplayID) -> Float? {
        var value: Float = 0
        guard let getBrightness, getBrightness(display, &value) == 0 else { return nil }
        return value
    }

    @discardableResult
    static func setNativeBrightness(_ display: CGDirectDisplayID, _ value: Float) -> Bool {
        setBrightness?(display, value) == 0
    }

    // MARK: IOAVService (DDC/CI over I²C on Apple Silicon)

    private typealias AVServiceCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias AVServiceI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    nonisolated(unsafe) private static let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    private static let avServiceCreate: AVServiceCreate? = symbol(ioKit, "IOAVServiceCreateWithService")
    private static let avServiceRead: AVServiceI2C? = symbol(ioKit, "IOAVServiceReadI2C")
    private static let avServiceWrite: AVServiceI2C? = symbol(ioKit, "IOAVServiceWriteI2C")

    static func avService(for service: io_service_t) -> CFTypeRef? {
        avServiceCreate?(kCFAllocatorDefault, service)?.takeRetainedValue()
    }

    static func i2cWrite(_ service: CFTypeRef, chip: UInt32, offset: UInt32, _ data: inout [UInt8]) -> Bool {
        guard let avServiceWrite else { return false }
        let count = UInt32(data.count)
        return data.withUnsafeMutableBytes { avServiceWrite(service, chip, offset, $0.baseAddress!, count) } == KERN_SUCCESS
    }

    static func i2cRead(_ service: CFTypeRef, chip: UInt32, offset: UInt32, _ data: inout [UInt8]) -> Bool {
        guard let avServiceRead else { return false }
        let count = UInt32(data.count)
        return data.withUnsafeMutableBytes { avServiceRead(service, chip, offset, $0.baseAddress!, count) } == KERN_SUCCESS
    }

    // MARK: CoreBrightness (keyboard backlight)

    private typealias KeyboardGet = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias KeyboardSet = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    nonisolated(unsafe) private static let coreBrightness = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
    nonisolated(unsafe) private static let keyboardClient: NSObject? = {
        guard coreBrightness != nil, let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let client = type.init()
        let needed = ["brightnessForKeyboard:", "setBrightness:forKeyboard:", "copyKeyboardBacklightIDs"]
        return needed.allSatisfy { client.responds(to: Selector($0)) } ? client : nil
    }()
    /// The backlight ID is hardware-specific (not 1), so ask for it.
    private static let keyboardID: UInt64? = {
        guard let keyboardClient,
              let ids = keyboardClient.perform(Selector(("copyKeyboardBacklightIDs")))?.takeRetainedValue() as? [NSNumber]
        else { return nil }
        return ids.first?.uint64Value
    }()

    /// 0...1, or nil when the Mac has no backlit keyboard or the API is gone.
    static func keyboardBrightness() -> Float? {
        guard let keyboardClient, let keyboardID else { return nil }
        let selector = Selector(("brightnessForKeyboard:"))
        return unsafeBitCast(keyboardClient.method(for: selector), to: KeyboardGet.self)(keyboardClient, selector, keyboardID)
    }

    @discardableResult
    static func setKeyboardBrightness(_ value: Float) -> Bool {
        guard let keyboardClient, let keyboardID else { return false }
        let selector = Selector(("setBrightness:forKeyboard:"))
        return unsafeBitCast(keyboardClient.method(for: selector), to: KeyboardSet.self)(keyboardClient, selector, value, keyboardID)
    }

    // MARK: -

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
