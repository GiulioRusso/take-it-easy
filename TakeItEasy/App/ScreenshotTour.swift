#if DEBUG
import AppKit
import OSLog
import ScreenCaptureKit

/// README screenshots. Launch with `-TIEScreenshots <dir>` (and `-enabledModules "()"` so nothing autostarts):
/// opens the main panels with demo data, saves PNGs of them on a gradient backdrop, then quits.
/// Captures only this app's own window: nothing else on screen ends up in the image.
enum ScreenshotTour {
    private static let log = Logger(subsystem: "take-it-easy", category: "screenshots")

    static func runIfRequested(registry: ModuleRegistry, mainPanel: MainPanel, settings: SettingsWindow) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-TIEScreenshots"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        Task {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try await run(registry: registry, mainPanel: mainPanel, settings: settings, dir: dir)
            } catch {
                log.error("screenshot tour failed: \(error.localizedDescription, privacy: .public)")
            }
            NSApp.terminate(nil)
        }
    }

    private static func run(registry: ModuleRegistry, mainPanel: MainPanel, settings: SettingsWindow, dir: URL) async throws {
        func module<T>(_: T.Type) -> T? { registry.modules.first { $0 is T } as? T }
        guard let mixer = module(MixerModule.self), let resources = module(ResourceManagerModule.self),
              let clipboard = module(ClipboardModule.self), let screen = NSScreen.main else { return }

        ResourceSampler.demoBatteries = [
            .init(name: "AirPods Pro", symbol: "airpodspro", levels: [("L", 92), ("R", 88), (String(localized: "Custodia"), 64)]),
            .init(name: "Magic Keyboard", symbol: "keyboard", levels: [("", 54)]),
            .init(name: "Magic Mouse", symbol: "magicmouse", levels: [("", 71)]),
        ]
        clipboard.startDemo()
        registry.startForScreenshots(clipboard, start: false)
        for id in ["mixer", "resources", "stayup", "clean", "grab", "wheel", "glance"] {
            guard let m = registry.modules.first(where: { $0.id == id }) else { continue }
            // Grab, Wheel, Glance only light up their tile (they'd need permissions and do nothing visible here).
            registry.startForScreenshots(m, start: ["mixer", "resources", "stayup", "clean"].contains(id))
        }

        // Main panel: opened from the menu bar corner, as a click on the icon would.
        moveMouse(to: CGPoint(x: screen.frame.maxX - 240, y: screen.frame.maxY - 14), on: screen)
        mainPanel.toggle()
        try await capture("main-panel", dir: dir, settle: 2.5) // two samples for the CPU rates
        mainPanel.toggle()

        moveMouse(to: CGPoint(x: screen.frame.midX, y: screen.frame.midY + 120), on: screen)
        clipboard.toggle()
        try await capture("clipboard", dir: dir)
        clipboard.toggle()

        let files = try demoImages()
        let wheel = WheelMenu(items: WheelItems.build(for: FinderSelection(folder: files[0].deletingLastPathComponent(), items: files)),
                              holdMode: false)
        moveMouse(to: CGPoint(x: screen.frame.midX, y: screen.frame.midY), on: screen)
        wheel.show()
        try await capture("wheel", dir: dir)
        wheel.close()

        resources.toggle()
        try await capture("resource-manager", dir: dir, settle: 2.5)
        resources.toggle()

        mixer.toggle()
        try await capture("mixer", dir: dir)
        mixer.toggle()

        settings.show("mixer")
        try await capture("settings", dir: dir, settle: 1.5)
        for module in registry.modules { module.stop() }
    }

    // MARK: - Capture

    /// Saves the window this app opened last on a gradient backdrop.
    private static func capture(_ name: String, dir: URL, settle: Double = 1) async throws {
        try await Task.sleep(for: .seconds(settle))
        let candidates = NSApp.windows.filter {
            $0.isVisible && $0.contentView != nil && $0.frame.width > 60 && !String(describing: type(of: $0)).contains("StatusBar")
        }
        // Panels are created fresh for each shot: the newest window is the one just opened.
        guard let window = candidates.max(by: { $0.windowNumber < $1.windowNumber }),
              let screen = window.screen else { return log.error("\(name, privacy: .public): no window") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }),
              let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            return log.error("\(name, privacy: .public): window not shareable")
        }
        let filter = SCContentFilter(display: display, including: [target])

        let rect = window.frame.insetBy(dx: -56, dy: -56).intersection(screen.frame)
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                                   width: rect.width, height: rect.height) // display points, top-left origin
        config.width = Int(rect.width * screen.backingScaleFactor)
        config.height = Int(rect.height * screen.backingScaleFactor)
        config.showsCursor = false
        let shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try backdrop(shot).write(to: dir.appendingPathComponent("\(name).png"))
        log.info("\(name, privacy: .public) saved")
    }

    /// The shot over the icon's blue gradient, rounded, so every README image looks the same.
    private static func backdrop(_ shot: CGImage) throws -> Data {
        let size = CGSize(width: shot.width, height: shot.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: shot.width, height: shot.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let clip = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 36, cornerHeight: 36, transform: nil)
        ctx.addPath(clip)
        ctx.clip()
        let colors = [CGColor(srgbRed: 0.36, green: 0.72, blue: 1, alpha: 1), CGColor(srgbRed: 0.27, green: 0.35, blue: 0.93, alpha: 1)]
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        ctx.draw(shot, in: CGRect(origin: .zero, size: size))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    /// `point` in AppKit coordinates of `screen`.
    private static func moveMouse(to point: CGPoint, on screen: NSScreen) {
        let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: top - point.y))
    }

    /// Three small PNGs so the wheel shows its image actions.
    private static func demoImages() throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appending(path: "tie-screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try (1...3).map { i in
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let url = dir.appending(path: "photo-\(i).png")
            try rep.representation(using: .png, properties: [:])!.write(to: url)
            return url
        }
    }
}
#endif
