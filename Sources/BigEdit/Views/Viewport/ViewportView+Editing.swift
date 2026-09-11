import AppKit
import CoreText

/// Positional editing: typing, deletion, cut and paste, undo and redo.
extension ViewportView {

    /// Positional edits are possible when the format allows it and no
    /// deferred replacement rule is transforming the drawn text, since under
    /// one the caret's screen position no longer identifies a byte. Aligned
    /// CSV columns are fine: the cell map turns a screen position back into
    /// the byte it shows.
    var isEditingAllowed: Bool {
        document?.isEditable == true && document?.hasDisplayTransform != true
    }

    /// A rewrite of the whole document needs no caret, so it is possible
    /// under aligned CSV columns too; the only bar is a format that cannot be
    /// edited at all, or a deferred replacement rule already transforming it.
    var isWholeDocumentReplacementAllowed: Bool {
        document?.isEditable == true && document?.hasDisplayTransform != true
    }

    /// Replaces the whole document in one undoable step.
    ///
    /// The line operations rewrite every line, so they land as a single edit
    /// rather than as thousands — one ⌘Z puts the document back.
    func replaceEntireDocument(with bytes: [UInt8]) {
        if let document, isWholeDocumentReplacementAllowed {
            applyEdit(replacing: 0..<document.length, with: bytes, in: document)
        } else {
            NSSound.beep()
        }
    }

    /// Replaces `range` with `bytes`, collapses the caret to the end of the
    /// insertion, and refreshes everything that depends on the content.
    func performEdit(replacing range: Range<Int>, with bytes: [UInt8]) {
        if let document, isEditingAllowed {
            applyEdit(replacing: range, with: bytes, in: document)
        } else {
            NSSound.beep()
        }
    }

    private func applyEdit(replacing range: Range<Int>, with bytes: [UInt8], in document: EditedDocument) {
        let bytes = csvDelimitersCreatingCaretCell(before: bytes, at: range)
        document.replace(range, with: bytes, selectionBefore: selection)
        documentContentChanged()
        let caret = range.lowerBound + bytes.count
        widenCSVColumnsToFitRow(containing: caret)
        selection = TextSelection(anchorOffset: caret, activeOffset: caret)
        desiredCaretX = nil
        onEdit?()
        scrollByteIntoView(caret)
        needsDisplay = true
    }

    /// Call after the document was edited outside the keyboard path (Replace
    /// All): clamps the selection to the new length and re-clamps the scroll.
    func documentDidChangeProgrammatically() {
        documentContentChanged()
        if let selection, let document {
            let length = document.length
            self.selection = TextSelection(
                anchorOffset: min(selection.anchorOffset, length),
                activeOffset: min(selection.activeOffset, length)
            )
        }
        setScrollRow(scrollRow)
        needsDisplay = true
    }

    @objc func undo(_ sender: Any?) {
        replayHistory { document in document.undoStack.undo(in: document) }
    }

    @objc func redo(_ sender: Any?) {
        replayHistory { document in document.undoStack.redo(in: document) }
    }

    private func replayHistory(_ action: (EditedDocument) -> TextSelection?) {
        guard let document, isEditingAllowed else {
            NSSound.beep()
            return
        }
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            unmarkText()
        }
        if let restored = action(document) {
            documentContentChanged()
            selection = restored
            desiredCaretX = nil
            onEdit?()
            scrollByteIntoView(restored.activeOffset)
            needsDisplay = true
        } else {
            NSSound.beep()
        }
    }

    /// Inserts `bytes` at the selection. Typing without a caret does nothing
    /// (click to place one first) — arrows keep their browse-first behaviour.
    private func insertBytesAtSelection(_ bytes: [UInt8]) {
        if let selection {
            performEdit(replacing: selection.range, with: bytes)
        } else {
            NSSound.beep()
        }
    }

    override func deleteBackward(_ sender: Any?) {
        guard let document, let selection else {
            NSSound.beep()
            return
        }
        if !selection.isEmpty {
            performEdit(replacing: selection.range, with: [])
        } else if selection.activeOffset > 0 {
            let caret = selection.activeOffset
            var start = document.previousCharacterOffset(before: caret)
            // A CRLF pair deletes as one unit.
            if document.byte(at: start) == 0x0A, start > 0,
               document.byte(at: start - 1) == 0x0D {
                start -= 1
            }
            performEdit(replacing: start..<caret, with: [])
        }
    }

    override func deleteForward(_ sender: Any?) {
        guard let document, let selection else {
            NSSound.beep()
            return
        }
        if !selection.isEmpty {
            performEdit(replacing: selection.range, with: [])
        } else if selection.activeOffset < document.length {
            let caret = selection.activeOffset
            var end = document.nextCharacterOffset(after: caret)
            // A CRLF pair deletes as one unit.
            if document.byte(at: caret) == 0x0D, document.byte(at: end) == 0x0A {
                end += 1
            }
            performEdit(replacing: caret..<end, with: [])
        }
    }

    override func insertNewline(_ sender: Any?) {
        insertBytesAtSelection(document?.newlineBytes ?? [0x0A])
    }

    /// Under CSV columns Tab moves to the next cell, as in a spreadsheet;
    /// otherwise it types a tab.
    override func insertTab(_ sender: Any?) {
        if isCSVRenderingActive {
            moveToAdjacentCSVCell(forward: true)
        } else {
            insertBytesAtSelection([0x09])
        }
    }

    override func insertBacktab(_ sender: Any?) {
        if isCSVRenderingActive {
            moveToAdjacentCSVCell(forward: false)
        }
    }

    @objc func cut(_ sender: Any?) {
        let cap = 64 * 1024 * 1024
        if let selection, !selection.isEmpty, isEditingAllowed {
            if selection.range.count > cap {
                presentSelectionTooLarge()
            } else {
                copy(sender)
                performEdit(replacing: selection.range, with: [])
            }
        } else {
            NSSound.beep()
        }
    }

    @objc func paste(_ sender: Any?) {
        if isEditingAllowed, selection != nil,
           let text = NSPasteboard.general.string(forType: .string) {
            insertBytesAtSelection(pasteBytes(from: text))
        } else {
            NSSound.beep()
        }
    }

    /// Pasted text normalised to the document's detected line ending, as
    /// UTF-8 bytes.
    private func pasteBytes(from text: String) -> [UInt8] {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        if document?.newlineBytes == [0x0D, 0x0A] {
            normalized = normalized.replacingOccurrences(of: "\n", with: "\r\n")
        }
        return Array(normalized.utf8)
    }
}
