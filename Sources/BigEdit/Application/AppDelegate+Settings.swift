import AppKit

/// The Settings window and applying its choices.
extension AppDelegate {

    @objc func showSettings() {
        let controller = settingsWindowController ?? SettingsWindowController(
            settings: settings, updates: UpdateSettings(updater: updaterController.updater))
        settingsWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Applies the current settings to the app and every open document.
    func applySettings() {
        NSApp.appearance = settings.appearance.appearance
        for document in documents {
            document.view.apply(settings)
        }
    }
}
