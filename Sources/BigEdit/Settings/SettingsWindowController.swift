import AppKit
import SwiftUI

/// The Settings window, opened from BigEdit ▸ Settings… (⌘,). One window is
/// kept for the app's lifetime and brought forward when asked for again.
final class SettingsWindowController: NSWindowController {

    init(settings: AppSettings, updates: UpdateSettings) {
        let hostingController = NSHostingController(
            rootView: SettingsView(settings: settings, updates: updates))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("BigEditSettings")
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is created programmatically")
    }
}
