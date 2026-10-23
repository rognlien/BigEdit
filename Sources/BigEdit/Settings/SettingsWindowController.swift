import AppKit
import SwiftUI

/// The Settings window, opened from BigEdit ▸ Settings… (⌘,). One window is
/// kept for the app's lifetime and brought forward when asked for again.
/// Its panes are chosen from the toolbar, like the settings of Apple's own
/// apps, and the window takes the size of the one shown.
final class SettingsWindowController: NSWindowController {

    init(settings: AppSettings, updates: UpdateSettings) {
        let panes = SettingsTabViewController()
        panes.tabStyle = .toolbar
        panes.addTabViewItem(SettingsWindowController.pane(
            "General", symbol: "gearshape", SettingsView(settings: settings, updates: updates)))
        panes.addTabViewItem(SettingsWindowController.pane(
            "Formatting", symbol: "text.alignleft", FormattingSettingsView(settings: settings)))
        let window = NSWindow(contentViewController: panes)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("BigEditSettings")
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is created programmatically")
    }

    private static func pane<Content: View>(_ title: String, symbol: String, _ content: Content) -> NSTabViewItem {
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = .preferredContentSize
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

/// Resizes the window to each pane as it is chosen, keeping its top edge
/// where it was.
final class SettingsTabViewController: NSTabViewController {

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let window = view.window, let size = tabViewItem?.viewController?.preferredContentSize,
           size.width > 0, size.height > 0 {
            let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            let origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(NSRect(origin: origin, size: frame.size), display: true, animate: window.isVisible)
        }
    }
}
