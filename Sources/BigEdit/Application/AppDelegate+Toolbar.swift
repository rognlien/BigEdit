import AppKit

/// The window's toolbar: Find, Find & Replace, and the info pane, each
/// forwarding to the same action as its menu item.
extension AppDelegate: NSToolbarDelegate, NSToolbarItemValidation {

    private static let toolbarIdentifier = NSToolbar.Identifier("BigEditMain")

    private enum ToolbarItem {
        static let find = NSToolbarItem.Identifier("find")
        static let findAndReplace = NSToolbarItem.Identifier("findAndReplace")
        static let infoPane = NSToolbarItem.Identifier("infoPane")
    }

    /// Gives the window a unified title bar and toolbar, with the file name
    /// and proxy icon at the leading edge as in Finder and Xcode.
    func installToolbar() {
        let toolbar = NSToolbar(identifier: AppDelegate.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbarStyle = .unified
        window.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ToolbarItem.find, ToolbarItem.findAndReplace, ToolbarItem.infoPane]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarItem.find, ToolbarItem.findAndReplace, ToolbarItem.infoPane, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        var item: NSToolbarItem?
        switch identifier {
        case ToolbarItem.find:
            item = makeToolbarItem(identifier, label: "Find", symbol: "magnifyingglass",
                                   toolTip: "Find (⌘F)", action: #selector(performFind))
        case ToolbarItem.findAndReplace:
            item = makeToolbarItem(identifier, label: "Find & Replace", symbol: "arrow.2.squarepath",
                                   toolTip: "Find & Replace (⌥⌘F)", action: #selector(performFindReplace))
        case ToolbarItem.infoPane:
            item = makeToolbarItem(identifier, label: "Info", symbol: "info.circle",
                                   toolTip: "Show or hide the info pane (⌘I)", action: #selector(toggleInfoPane))
        default:
            break
        }
        return item
    }

    private func makeToolbarItem(_ identifier: NSToolbarItem.Identifier, label: String, symbol: String,
                                 toolTip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = toolTip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    /// The items need a document, like their menu counterparts.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        activeDocument != nil
    }
}
