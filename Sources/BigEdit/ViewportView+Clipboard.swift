import AppKit
import CoreText

/// Copy and Select All, and the menu validation for the edit commands.
extension ViewportView {

    @objc func copy(_ sender: Any?) {
        let cap = 64 * 1024 * 1024
        if let selection, !selection.isEmpty, let document {
            let range = selection.range
            if range.count > cap {
                presentSelectionTooLarge()
            } else {
                let bytes = document.displayBytes(in: range)
                let text = ViewportView.pasteboardText(from: bytes, encoding: textEncoding)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        } else {
            NSSound.beep()
        }
    }

    /// Decodes copied bytes to a string and drops the control characters the
    /// viewport doesn't render — keeping only tab and newline. The viewport
    /// shows printable text (it hides the CR of CRLF lines and control bytes
    /// like Record Separator, U+001E), so copying the raw bytes would otherwise
    /// paste stray characters that look inserted. Dropping CR everywhere also
    /// turns CRLF into LF, matching the displayed lines.
    static func pasteboardText(fromUTF8 bytes: [UInt8]) -> String {
        pasteboardText(from: bytes, encoding: .utf8)
    }

    static func pasteboardText(from bytes: [UInt8], encoding: TextEncoding) -> String {
        var text = encoding.decode(bytes)
        if text.unicodeScalars.contains(where: ViewportView.isHiddenControl) {
            text.unicodeScalars.removeAll(where: ViewportView.isHiddenControl)
        }
        return text
    }

    /// A C0 control character (or DEL) that the viewport doesn't render, other
    /// than tab and newline which it lays out normally.
    private static func isHiddenControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A:           // tab, newline — keep
            return false
        case 0x00...0x1F, 0x7F:    // other C0 controls and DEL — drop
            return true
        default:
            return false
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        if let document {
            selection = TextSelection(anchorOffset: 0, activeOffset: document.length)
            needsDisplay = true
        }
    }

    func presentSelectionTooLarge() {
        let alert = NSAlert()
        alert.messageText = "Selection Too Large"
        alert.informativeText = "BigEdit caps a single copy at 64 MB. Make a smaller selection."
        alert.alertStyle = .warning
        alert.runModal()
    }

}

extension ViewportView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        var enabled = true
        switch menuItem.action {
        case #selector(copy(_:)):
            enabled = !(selection?.isEmpty ?? true)
        case #selector(cut(_:)):
            enabled = !(selection?.isEmpty ?? true) && isEditingAllowed
        case #selector(paste(_:)):
            enabled = isEditingAllowed && selection != nil
                && NSPasteboard.general.string(forType: .string) != nil
        case #selector(selectAll(_:)):
            enabled = document != nil
        case #selector(undo(_:)):
            enabled = isEditingAllowed && document?.undoStack.canUndo == true
        case #selector(redo(_:)):
            enabled = isEditingAllowed && document?.undoStack.canRedo == true
        default:
            enabled = true
        }
        return enabled
    }
}
