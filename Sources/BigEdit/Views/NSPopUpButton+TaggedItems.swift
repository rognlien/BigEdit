import AppKit

extension NSPopUpButton {

    /// Appends an item whose tag identifies it. Unlike `addItem(withTitle:)`,
    /// which first removes any item with the same title, this keeps items
    /// whose titles repeat — two open documents can share a name.
    func addItem(title: String, tag: Int) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.tag = tag
        menu?.addItem(item)
    }
}
