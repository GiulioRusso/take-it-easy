import AppKit
import ApplicationServices
import CoreGraphics

/// Checks and requests TCC permissions. Only called when a module is enabled, never at launch.
enum PermissionCenter {
    static func isGranted(_ permission: TIEPermission) async -> Bool {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted()
        case .screenRecording:
            return CGPreflightScreenCaptureAccess()
        case .appleEvents(let bundleID):
            return await automationStatus(bundleID: bundleID, ask: false)
        case .audioCapture:
            // ponytail: no public preflight API; macOS prompts when the first process tap is created (Phase 3b).
            return true
        }
    }

    /// Triggers the system prompt. Accessibility and Screen Recording are granted in System Settings,
    /// so this usually returns false the first time and the user re-enables the module afterwards.
    static func request(_ permission: TIEPermission) async -> Bool {
        switch permission {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            return CGRequestScreenCaptureAccess()
        case .appleEvents(let bundleID):
            return await automationStatus(bundleID: bundleID, ask: true)
        case .audioCapture:
            return true
        }
    }

    static func missing(_ permissions: [TIEPermission]) async -> [TIEPermission] {
        var result: [TIEPermission] = []
        for p in permissions where !(await isGranted(p)) { result.append(p) }
        return result
    }

    /// AEDeterminePermissionToAutomateTarget blocks (and may show a prompt), so run it off the main thread.
    private static func automationStatus(bundleID: String, ask: Bool) async -> Bool {
        await Task.detached {
            var target = AEAddressDesc()
            let created = bundleID.withCString {
                AECreateDesc(typeApplicationBundleID, $0, strlen($0), &target)
            }
            guard created == noErr else { return false }
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask) == noErr
        }.value
    }
}
