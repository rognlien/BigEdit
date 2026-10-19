import AppKit
import CoreText

/// The input-client conformance needed for IME composition, dead keys, and
/// press-and-hold accents. The document is far too large for global UTF-16
/// ranges, so ranges count from an anchor near the caret — see
/// `inputAnchor()`; composition bytes live in the document itself.
extension ViewportView: NSTextInputClient {

    /// A long line is split into blocks of this many bytes, so that UTF-16
    /// positions never count from further back than one block.
    static let inputAnchorBlockLength = 4096

    /// The most bytes a range conversion decodes.
    static let inputSpanLimit = 1 << 20

    /// Text the document's encoding cannot write is not inserted; any
    /// composition it was meant to replace is removed with it.
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = ViewportView.plainString(from: string)
        let target = editTargetRange(for: replacementRange)
        let isCommittingComposition = markedByteRange != nil
        markedByteRange = nil
        if let target, isEditingAllowed {
            if let bytes = encodedForInsertion(text) {
                insertKeepingCells(bytes, replacing: target)
            } else if isCommittingComposition && !target.isEmpty {
                performEdit(replacing: target, with: [])
            }
        } else {
            NSSound.beep()
        }
    }

    /// Composition the document's encoding cannot write — a dead key's
    /// accent that has no character of its own there — is tracked as an
    /// empty marked range, so the committed character still lands at the
    /// caret.
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = ViewportView.plainString(from: string)
        if isEditingAllowed, let target = editTargetRange(for: replacementRange) {
            let bytes = textEncoding.encode(text) ?? []
            performEdit(replacing: target, with: bytes)
            markedByteRange = text.isEmpty
                ? nil
                : target.lowerBound..<(target.lowerBound + bytes.count)
            selectInMarkedText(text, range: selectedRange)
        }
    }

    /// Selects the part of the marked text the input method chose: the
    /// clause being converted, or an empty range where it put the caret.
    private func selectInMarkedText(_ text: String, range: NSRange) {
        if let marked = markedByteRange, !marked.isEmpty, range.location != NSNotFound {
            let length = text.utf16.count
            let start = min(range.location, length)
            let end = min(start + max(0, range.length), length)
            let anchor = ViewportView.byteOffset(forUTF16Index: start, in: text, encoding: textEncoding)
            let active = ViewportView.byteOffset(forUTF16Index: end, in: text, encoding: textEncoding)
            selection = TextSelection(anchorOffset: marked.lowerBound + anchor,
                                      activeOffset: marked.lowerBound + active)
        }
    }

    /// Accepts the composition as it stands, leaving the caret after it.
    func unmarkText() {
        if let marked = markedByteRange {
            selection = TextSelection(anchorOffset: marked.upperBound, activeOffset: marked.upperBound)
        }
        markedByteRange = nil
        needsDisplay = true
    }

    func hasMarkedText() -> Bool {
        markedByteRange != nil
    }

    func markedRange() -> NSRange {
        var result = NSRange(location: NSNotFound, length: 0)
        if let marked = markedByteRange, let anchor = inputAnchor() {
            result = utf16Range(of: marked, from: anchor)
        }
        return result
    }

    func selectedRange() -> NSRange {
        var result = NSRange(location: NSNotFound, length: 0)
        if let selection, let anchor = inputAnchor() {
            result = utf16Range(of: selection.range, from: anchor)
        }
        return result
    }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? {
        var result: NSAttributedString?
        if let document, let bytes = byteRange(for: range) {
            let text = textEncoding.decode(document.bytes(in: bytes))
            result = NSAttributedString(string: text)
            actualRange?.pointee = NSRange(location: range.location, length: text.utf16.count)
        }
        return result
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

    /// The logical byte range an input-method `replacementRange` addresses;
    /// without an explicit range, the marked range or selection.
    private func editTargetRange(for replacementRange: NSRange) -> Range<Int>? {
        var result = markedByteRange ?? selection?.range
        if replacementRange.location != NSNotFound {
            result = byteRange(for: replacementRange)
        }
        return result
    }

    /// The logical byte offset input-method positions count from: the start
    /// of the line holding the composition, or the selection when there is
    /// none. On a long line it is the start of the block that holds it
    /// instead, so a position never costs more than a block to convert.
    private func inputAnchor() -> Int? {
        var result: Int?
        if let document, let reference = markedByteRange?.lowerBound ?? selection?.range.lowerBound {
            let lineStart = document.layout.logicalLineStart(containing: reference)
            let blockLength = ViewportView.inputAnchorBlockLength
            var anchor = lineStart + (reference - lineStart) / blockLength * blockLength
            while anchor < reference, document.isContinuationByte(at: anchor) {
                anchor += 1
            }
            result = anchor
        }
        return result
    }

    /// `bytes`, which start at or after `anchor`, as UTF-16 positions.
    private func utf16Range(of bytes: Range<Int>, from anchor: Int) -> NSRange {
        let location = utf16Length(of: anchor..<max(anchor, bytes.lowerBound))
        return NSRange(location: location, length: utf16Length(of: bytes))
    }

    private func utf16Length(of bytes: Range<Int>) -> Int {
        var result = 0
        if let document {
            let end = min(bytes.upperBound, bytes.lowerBound + ViewportView.inputSpanLimit)
            result = textEncoding.decode(document.bytes(in: bytes.lowerBound..<end)).utf16.count
        }
        return result
    }

    /// The logical bytes the UTF-16 `range` covers, clamped to the document.
    private func byteRange(for range: NSRange) -> Range<Int>? {
        var result: Range<Int>?
        if let anchor = inputAnchor(), range.location != NSNotFound {
            let start = byteOffset(forUTF16Location: range.location, from: anchor)
            let end = byteOffset(forUTF16Location: range.location + max(0, range.length), from: anchor)
            result = start..<max(start, end)
        }
        return result
    }

    private func byteOffset(forUTF16Location location: Int, from anchor: Int) -> Int {
        var result = anchor
        if let document {
            let units = min(max(0, location), ViewportView.inputSpanLimit)
            let end = min(document.length, anchor + units * (textEncoding.isSingleByte ? 1 : 3))
            let text = textEncoding.decode(document.bytes(in: anchor..<end))
            let offset = ViewportView.byteOffset(forUTF16Index: units, in: text, encoding: textEncoding)
            result = min(end, anchor + offset)
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
