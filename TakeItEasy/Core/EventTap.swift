import CoreGraphics
import Foundation

/// The parts of a CGEvent a handler needs, as a Sendable value (CGEvent itself isn't Sendable).
nonisolated struct TapEvent: Sendable {
    let type: CGEventType
    let keyCode: Int64
    let flags: CGEventFlags
    let isRepeat: Bool
}

/// Active session event tap on the main run loop. Needs Accessibility.
/// The handler returns true to swallow the event.
final class EventTap {
    struct Failure: LocalizedError {
        var errorDescription: String? { String(localized: "Impossibile intercettare la tastiera: controlla il permesso Accessibilità.") }
    }

    private let mask: CGEventMask
    private let listenOnly: Bool
    private let handler: (TapEvent) -> Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// `listenOnly`: for handlers that never swallow. The system then delivers events without waiting
    /// for us, so a busy main thread can't make typing or scrolling lag.
    init(events: [CGEventType], listenOnly: Bool = false, handler: @escaping (TapEvent) -> Bool) {
        mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        self.listenOnly = listenOnly
        self.handler = handler
    }

    /// Idempotent.
    func start() throws {
        guard tap == nil else { return }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: listenOnly ? .tailAppendEventTap : .headInsertEventTap,
            options: listenOnly ? .listenOnly : .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
                let value = TapEvent(type: type, keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                     flags: event.flags, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
                // The source is on the main run loop, so this runs on the main thread.
                let swallow = MainActor.assumeIsolated { owner.handle(value) }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { throw Failure() }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
    }

    /// Idempotent.
    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ event: TapEvent) -> Bool {
        if event.type == .tapDisabledByTimeout || event.type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        return handler(event)
    }
}
