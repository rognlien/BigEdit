import AppKit
import CoreText

/// The input-client conformance needed for IME composition, dead keys, and
/// press-and-hold accents. The document is far too large for global UTF-16
/// ranges, so ranges are reported in a synthetic space anchored at the start
/// of the marked text; composition bytes live in the document itself.
extension ViewportView: NSTextInputClient {

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = ViewportView.plainString(from: string)
        let target = editTargetRange(for: replacementRange)
        markedByteRange = nil
        if let target {
            performEdit(replacing: target, with: Array(text.utf8))
        } else {
            NSSound.beep()
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = ViewportView.plainString(from: string)
        if isEditingAllowed, let target = editTargetRange(for: replacementRange) {
            let bytes = Array(text.utf8)
            performEdit(replacing: target, with: bytes)
            markedByteRange = bytes.isEmpty
                ? nil
                : target.lowerBound..<(target.lowerBound + bytes.count)
        }
    }

    func unmarkText() {
        markedByteRange = nil
        needsDisplay = true
    }

    func hasMarkedText() -> Bool {
        markedByteRange != nil
    }

    func markedRange() -> NSRange {
        var result = NSRange(location: NSNotFound, length: 0)
        if let marked = markedByteRange, let document {
            let text = String(decoding: document.bytes(in: marked), as: UTF8.self)
            result = NSRange(location: 0, length: text.utf16.count)
        }
        return result
    }

    func selectedRange() -> NSRange {
        // During composition the caret sits at the marked text's end; there
        // is no meaningful global range to report otherwise.
        var result = NSRange(location: NSNotFound, length: 0)
        if hasMarkedText() {
            result = NSRange(location: markedRange().length, length: 0)
        }
        return result
    }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    /// The caret rectangle in screen coordinates — anchors the input method's
    /// candidate window.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        var result = NSRect.zero
        if let layout, let window, let caret = caretByteOffset {
            let caretRow = layout.visualRow(forLogicalByteOffset: caret)
            let x = caretX(forOffset: caret, row: caretRow)
            let gutterW = gutterWidth(for: layout.gutterLineCount)
            let viewRect = NSRect(
                x: gutterW + gutterPadding - horizontalOffset + x,
                y: (CGFloat(caretRow) - CGFloat(scrollRow)) * lineHeight,
                width: 1,
                height: lineHeight
            )
            result = window.convertToScreen(convert(viewRect, to: nil))
        }
        return result
    }

    /// The logical byte range an input-method `replacementRange` addresses.
    /// Its offsets are UTF-16 positions in the synthetic space anchored at the
    /// marked text; without an explicit range, the marked range or selection.
    private func editTargetRange(for replacementRange: NSRange) -> Range<Int>? {
        var result: Range<Int>?
        if let marked = markedByteRange, let document {
            result = marked
            if replacementRange.location != NSNotFound {
                let text = String(decoding: document.bytes(in: marked), as: UTF8.self)
                let start = ViewportView.byteOffset(forUTF16Index: replacementRange.location, in: text)
                let end = ViewportView.byteOffset(
                    forUTF16Index: replacementRange.location + replacementRange.length, in: text)
                result = (marked.lowerBound + start)..<(marked.lowerBound + end)
            }
        } else if let selection {
            result = selection.range
        }
        return result
    }

    /// Converts a UTF-16 index within `text` to a UTF-8 byte offset, clamped.
    /// The byte offset within `text`'s bytes — in `encoding` — of the
    /// character at UTF-16 index `target`. For UTF-8 that walks the variable
    /// widths; in a single-byte encoding one character is one byte.
    static func byteOffset(forUTF16Index target: Int, in text: String,
                           encoding: TextEncoding = .utf8) -> Int {
        var consumedUTF16 = 0
        var consumedBytes = 0
        for scalar in text.unicodeScalars {
            if consumedUTF16 >= target {
                break
            }
            consumedUTF16 += scalar.value > 0xFFFF ? 2 : 1
            consumedBytes += encoding.byteLength(of: scalar)
        }
        return consumedBytes
    }

    private static func plainString(from string: Any) -> String {
        var result = ""
        if let text = string as? String {
            result = text
        } else if let attributed = string as? NSAttributedString {
            result = attributed.string
        }
        return result
    }
}
