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
    /// under aligned CSV columns too. The bars are a format that cannot be
    /// edited at all, a deferred replacement rule already transforming it,
    /// and an encoding other than UTF-8, since the line operations work on
    /// lines decoded as UTF-8.
    var isWholeDocumentReplacementAllowed: Bool {
        document?.isEditable == true && document?.hasDisplayTransform != true
            && document?.encoding.isUTF8 == true
    }

    /// `text` as bytes in the document's encoding, or `nil` — after a beep
    /// and a report to `onUnrepresentableText` — when the encoding cannot
    /// write some of it.
    func encodedForInsertion(_ text: String) -> [UInt8]? {
        let bytes = textEncoding.encode(text)
        if bytes == nil {
            NSSound.beep()
            onUnrepresentableText?(text)
        }
        return bytes
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

    /// Replaces the whole table in one undoable step, in whatever encoding
    /// the document is edited in: a column rewrite leaves every byte but the
    /// delimiters and fields it adds or removes, so nothing is decoded.
    func replaceEntireTable(with bytes: [UInt8]) {
        if let document, isEditingAllowed, isCSVRenderingActive {
            csvCaretColumn = nil
            applyEdit(replacing: 0..<document.length, with: bytes, in: document)
        } else {
            NSSound.beep()
        }
    }

    /// Replaces `range` with `bytes`, collapses the caret to the end of the
    /// insertion — or `bytesAfterCaret` before it — and refreshes everything
    /// that depends on the content.
    func performEdit(replacing range: Range<Int>, with bytes: [UInt8], bytesAfterCaret: Int = 0) {
        if let document, isEditingAllowed {
            applyEdit(replacing: range, with: bytes, bytesAfterCaret: bytesAfterCaret, in: document)
        } else {
            NSSound.beep()
        }
    }

    private func applyEdit(replacing range: Range<Int>, with bytes: [UInt8], bytesAfterCaret: Int = 0,
                           in document: EditedDocument) {
        let bytes = csvDelimitersCreatingCaretCell(before: bytes, at: range)
        document.replace(range, with: bytes, selectionBefore: selection)
        documentContentChanged()
        let caret = range.lowerBound + bytes.count - bytesAfterCaret
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
        replayHistory(isUndo: true) { document in document.undoStack.undo(in: document) }
    }

    @objc func redo(_ sender: Any?) {
        replayHistory(isUndo: false) { document in document.undoStack.redo(in: document) }
    }

    private func replayHistory(isUndo: Bool, _ action: (EditedDocument) -> TextSelection?) {
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
            replayCSVColumnWidths(of: document, isUndo: isUndo)
            selection = restored
            desiredCaretX = nil
            onEdit?()
            scrollByteIntoView(restored.activeOffset)
            needsDisplay = true
        } else {
            NSSound.beep()
        }
    }

    /// After undoing or redoing a column change, puts back the widths the
    /// table had on that side of it, and tells the container.
    private func replayCSVColumnWidths(of document: EditedDocument, isUndo: Bool) {
        if let change = document.undoStack.lastReplayedCompanion as? CSVColumnWidthChange {
            restoreCSVColumnWidths(isUndo ? change.before : change.after)
            onCSVColumnChangeReplay?(isUndo)
        }
    }

    /// Inserts `bytes` at the selection. Typing without a caret does nothing
    /// (click to place one first) — arrows keep their browse-first behaviour.
    private func insertBytesAtSelection(_ bytes: [UInt8]) {
        if let selection {
            insertKeepingCells(bytes, replacing: selection.range)
        } else {
            NSSound.beep()
        }
    }

    override func deleteBackward(_ sender: Any?) {
        if hasColumnSelectionContent {
            deleteColumnSelection()
        } else {
            deleteCharacterBackward()
        }
    }

    private func deleteCharacterBackward() {
        guard let document, let selection else {
            NSSound.beep()
            return
        }
        if !selection.isEmpty {
            deleteKeepingCells(selection.range)
        } else if let row = csvRow(containing: selection.activeOffset) {
            deleteCharacterInCell(backward: true, at: selection.activeOffset, in: row)
        } else if selection.activeOffset > 0 {
            let caret = selection.activeOffset
            var start = document.previousDeletionOffset(before: caret)
            // A CRLF pair deletes as one unit.
            if document.byte(at: start) == 0x0A, start > 0,
               document.byte(at: start - 1) == 0x0D {
                start -= 1
            }
            performEdit(replacing: start..<caret, with: [])
        }
    }

    /// Control-Backspace: takes the last mark off the character before the
    /// caret, so é becomes e and a Hangul syllable loses its final jamo, or
    /// deletes it when it has none, as NSTextView does.
    override func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) {
        if let document, let selection, selection.isEmpty, !hasColumnSelectionContent,
           let edit = document.decomposingDeletion(before: selection.activeOffset) {
            insertKeepingCells(edit.bytes, replacing: edit.range)
        } else {
            deleteBackward(sender)
        }
    }

    override func deleteForward(_ sender: Any?) {
        if hasColumnSelectionContent {
            deleteColumnSelection()
        } else {
            deleteCharacterForward()
        }
    }

    private func deleteCharacterForward() {
        guard let document, let selection else {
            NSSound.beep()
            return
        }
        if !selection.isEmpty {
            deleteKeepingCells(selection.range)
        } else if let row = csvRow(containing: selection.activeOffset) {
            deleteCharacterInCell(backward: false, at: selection.activeOffset, in: row)
        } else if selection.activeOffset < document.length {
            let caret = selection.activeOffset
            var end = document.nextDeletionOffset(after: caret)
            // A CRLF pair deletes as one unit.
            if document.byte(at: caret) == 0x0D, document.byte(at: end) == 0x0A {
                end += 1
            }
            performEdit(replacing: caret..<end, with: [])
        }
    }

    // Option-Backspace and Option-Delete are bound to these in the standard
    // key bindings.
    override func deleteWordBackward(_ sender: Any?) {
        deleteSelectionOrToCaret { self.previousWordOffset(before: $0, skippingPunctuation: false) }
    }

    override func deleteWordForward(_ sender: Any?) {
        deleteSelectionOrToCaret { self.nextWordOffset(after: $0, skippingPunctuation: false) }
    }

    /// Deletes the selection, or from the caret to `boundary(caret)`. Under
    /// CSV columns that clears cell content and keeps the delimiters.
    private func deleteSelectionOrToCaret(_ boundary: (Int) -> Int) {
        if hasColumnSelectionContent {
            deleteColumnSelection()
        } else if let selection {
            let range = selection.isEmpty ? TextSelection(anchorOffset: selection.activeOffset,
                                                          activeOffset: boundary(selection.activeOffset)).range
                                          : selection.range
            if !range.isEmpty {
                deleteKeepingCells(range)
            }
        } else {
            NSSound.beep()
        }
    }

    /// Control-T: swaps the characters either side of the caret, or the two
    /// before it at the end of a line, and leaves the caret after them, as
    /// NSTextView does. Under CSV columns it beeps rather than move a
    /// delimiter, quote or line break.
    override func transpose(_ sender: Any?) {
        if let document, let selection, selection.isEmpty,
           let swap = transposition(at: selection.activeOffset, in: document),
           !movesCSVStructure(swap.bytes) {
            performEdit(replacing: swap.range, with: swap.bytes)
        } else {
            NSSound.beep()
        }
    }

    private func transposition(at caret: Int, in document: EditedDocument) -> (range: Range<Int>, bytes: [UInt8])? {
        var result: (range: Range<Int>, bytes: [UInt8])?
        let atLineEnd = caret == lineContentRange(containing: caret).upperBound
        let middle = atLineEnd ? document.previousGraphemeOffset(before: caret) : caret
        let start = document.previousGraphemeOffset(before: middle)
        let end = atLineEnd ? caret : document.nextGraphemeOffset(after: caret)
        if start < middle && middle < end {
            result = (start..<end, document.bytes(in: middle..<end) + document.bytes(in: start..<middle))
        }
        return result
    }

    private func movesCSVStructure(_ bytes: [UInt8]) -> Bool {
        var result = false
        if let csvDialect, isCSVRenderingActive {
            result = CSVCellEditing.needsQuoting(bytes, dialect: csvDialect, encoding: textEncoding)
        }
        return result
    }

    /// Under CSV columns Return moves down a row, as in a spreadsheet: a
    /// line break would end the row, and quoted inside a field it would
    /// still be drawn as a row of its own. Otherwise it types a line ending.
    override func insertNewline(_ sender: Any?) {
        if isCSVRenderingActive {
            moveToCSVCellBelow()
        } else {
            insertBytesAtSelection(document?.newlineBytes ?? [0x0A])
        }
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

    /// Option-Tab types a tab even under CSV columns, where Tab moves
    /// between cells — the system's binding for a literal tab.
    override func insertTabIgnoringFieldEditor(_ sender: Any?) {
        insertBytesAtSelection([0x09])
    }

    /// Option-Return types a line ending even under CSV columns, where
    /// Return moves down a row; in a cell it is quoted, as a pasted one is.
    /// Control-O sends this and then moves back over it.
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        insertBytesAtSelection(document?.newlineBytes ?? [0x0A])
    }

    // Control-' and Control-" are bound to these in the standard key
    // bindings, for a straight quote where typing would curl it. Nothing
    // curls quotes here, so they type the quote.
    override func insertSingleQuoteIgnoringSubstitution(_ sender: Any?) {
        insertText("'", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func insertDoubleQuoteIgnoringSubstitution(_ sender: Any?) {
        insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func insertBacktab(_ sender: Any?) {
        if isCSVRenderingActive {
            moveToAdjacentCSVCell(forward: false)
        }
    }

    @objc func cut(_ sender: Any?) {
        let cap = 64 * 1024 * 1024
        if hasColumnSelectionContent && isEditingAllowed {
            cutColumnSelection(cap: cap)
        } else if let selection, !selection.isEmpty, isEditingAllowed {
            if selection.range.count > cap {
                presentSelectionTooLarge()
            } else {
                copy(sender)
                deleteKeepingCells(selection.range)
            }
        } else {
            NSSound.beep()
        }
    }

    private func cutColumnSelection(cap: Int) {
        if columnSelectionText(cap: cap) == nil {
            presentSelectionTooLarge()
        } else {
            copy(nil)
            deleteColumnSelection()
        }
    }

    @objc func paste(_ sender: Any?) {
        paste(from: .general)
    }

    /// Inserts the text on `pasteboard` at the selection.
    func paste(from pasteboard: NSPasteboard) {
        if isEditingAllowed, selection != nil,
           let text = pasteboard.string(forType: .string) {
            insertTextAtSelection(text)
        } else {
            NSSound.beep()
        }
    }

    /// Shared by every window, like the system text views' kill buffer, and
    /// separate from the pasteboard.
    private static var killBuffer: String?

    /// Control-K: deletes the selection, or from the caret to the end of the
    /// line — the line ending itself when the caret is already there — and
    /// keeps the deleted text for Control-Y.
    override func deleteToEndOfParagraph(_ sender: Any?) {
        kill(killRange()) { self.performEdit(replacing: $0, with: []) }
    }

    /// Command-Backspace: deletes the selection, or from the start of the
    /// line to the caret, and keeps the deleted text for Control-Y. Under
    /// CSV columns it clears cell content and keeps the delimiters.
    override func deleteToBeginningOfLine(_ sender: Any?) {
        let range = selection.map { $0.isEmpty ? lineContentRange(containing: $0.activeOffset).lowerBound..<$0.activeOffset
                                               : $0.range }
        kill(range) { self.deleteKeepingCells($0) }
    }

    /// Keeps the text in `range` for Control-Y, then removes it with `delete`.
    private func kill(_ range: Range<Int>?, deletingWith delete: (Range<Int>) -> Void) {
        if let document, let range, isEditingAllowed {
            if range.count > 64 * 1024 * 1024 {
                presentSelectionTooLarge()
            } else if !range.isEmpty {
                let bytes = document.displayBytes(in: range)
                ViewportView.killBuffer = ViewportView.pasteboardText(from: bytes, encoding: textEncoding)
                delete(range)
            }
        } else {
            NSSound.beep()
        }
    }

    private func killRange() -> Range<Int>? {
        var result: Range<Int>?
        if let selection, let document {
            if !selection.isEmpty {
                result = selection.range
            } else {
                let caret = selection.activeOffset
                let line = lineContentRange(containing: caret)
                let lineEnd = document.layout.logicalLineRange(containing: caret).upperBound
                result = caret < line.upperBound ? caret..<line.upperBound : caret..<lineEnd
            }
        }
        return result
    }

    /// Control-Y: inserts the text last deleted with Control-K.
    override func yank(_ sender: Any?) {
        if isEditingAllowed, selection != nil, let text = ViewportView.killBuffer {
            insertTextAtSelection(text)
        } else {
            NSSound.beep()
        }
    }

    /// Inserts pasted or yanked text at the selection, unless the document's
    /// encoding cannot write it.
    func insertTextAtSelection(_ text: String) {
        if let bytes = encodedForInsertion(normalizingLineEndings(of: text)) {
            insertBytesAtSelection(bytes)
        }
    }

    /// Pasted text normalised to the document's detected line ending.
    func normalizingLineEndings(of text: String) -> String {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        if document?.newlineBytes == [0x0D, 0x0A] {
            normalized = normalized.replacingOccurrences(of: "\n", with: "\r\n")
        }
        return normalized
    }
}
