import SwiftUI

@main
struct TakeItEasyApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // The menu bar icon and Settings are AppKit-owned (MainPanel, SettingsWindow); SwiftUI needs one scene.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let registry = ModuleRegistry(modules: [
        GrabModule(), ClipboardModule(), WheelModule(), MixerModule(), GlanceModule(), SwitchModule(),
        ResourceManagerModule(), GestureModule(), StayUpModule(), CleanModule(),
    ])
    private var settings: SettingsWindow?
    private var mainPanel: MainPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsWindow(registry: registry)
        self.settings = settings
        let mainPanel = MainPanel(registry: registry, settings: settings)
        self.mainPanel = mainPanel
        #if DEBUG
        ScreenshotTour.runIfRequested(registry: registry, mainPanel: mainPanel, settings: settings)
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        registry.stopAll()
    }
}
