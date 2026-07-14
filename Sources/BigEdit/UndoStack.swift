import Foundation

/// The edit history: every operation is a piece-level splice, so records
/// reference backing-store ranges and never copy document bytes. Undoing a
/// 10 GB deletion re-splices a handful of pieces.
///
/// Records stay valid forever because the original file's mmap is immutable
/// and the add buffer is append-only. The stack clears when the document
/// re-maps after a save.
final class UndoStack {

    /// One history entry. `insertedLength` is the extent the operation
    /// currently occupies in the document starting at `position`; undoing it
    /// replaces that extent with `removedPieces` (what the edit displaced).
    struct Operation {
        var position: Int
        var insertedLength: Int
        var removedPieces: [PieceTable.Piece]
        var selectionBefore: TextSelection?
        var selectionAfter: TextSelection?

        /// Whether the next edit may merge into this one (typing runs).
        /// Newline edits and caret moves close a run.
        var canCoalesce: Bool

        var removedLength: Int {
            removedPieces.reduce(0) { $0 + $1.length }
        }

        var isDeletionOnly: Bool {
            insertedLength == 0 && !removedPieces.isEmpty
        }
    }

    private var undoOperations: [Operation] = []
    private var redoOperations: [Operation] = []

    var canUndo: Bool {
        !undoOperations.isEmpty
    }

    var canRedo: Bool {
        !redoOperations.isEmpty
    }

    /// The number of undoable operations — exposed for tests.
    var depth: Int {
        undoOperations.count
    }

    /// Records an edit that has just been applied, coalescing it into the
    /// previous operation when it continues a typing or deletion run.
    func recordEdit(
        position: Int,
        insertedLength: Int,
        removedPieces: [PieceTable.Piece],
        insertedContainsNewline: Bool,
        removedContainsNewline: Bool,
        selectionBefore: TextSelection?
    ) {
        redoOperations.removeAll()
        let caretAfter = position + insertedLength
        let operation = Operation(
            position: position,
            insertedLength: insertedLength,
            removedPieces: removedPieces,
            selectionBefore: selectionBefore,
            selectionAfter: TextSelection(anchorOffset: caretAfter, activeOffset: caretAfter),
            canCoalesce: !insertedContainsNewline && !removedContainsNewline
        )
        if operation.canCoalesce, let last = undoOperations.last, last.canCoalesce,
           let merged = merged(last, absorbing: operation) {
            undoOperations[undoOperations.count - 1] = merged
        } else {
            undoOperations.append(operation)
        }
    }

    /// Merges `next` into `last` when it continues the same editing run, or
    /// returns nil when it must stand alone.
    private func merged(_ last: Operation, absorbing next: Operation) -> Operation? {
        var result: Operation?
        let lastEnd = last.position + last.insertedLength

        if next.position >= last.position && next.position + next.removedLength == lastEnd {
            // The edit replaces (or extends) the tail of the run's own
            // insertion: plain typing, dead keys, IME composition steps, and
            // backspacing into freshly typed text all take this shape. What
            // the run originally displaced is unchanged.
            var merged = last
            merged.insertedLength = next.position - last.position + next.insertedLength
            merged.selectionAfter = next.selectionAfter
            result = merged
        } else if last.isDeletionOnly && next.isDeletionOnly
            && next.position + next.removedLength == last.position {
            // A backspace run marching backwards.
            var merged = last
            merged.position = next.position
            merged.removedPieces = next.removedPieces + last.removedPieces
            merged.selectionAfter = next.selectionAfter
            result = merged
        } else if last.isDeletionOnly && next.isDeletionOnly && next.position == last.position {
            // A forward-delete run standing still.
            var merged = last
            merged.removedPieces = last.removedPieces + next.removedPieces
            merged.selectionAfter = next.selectionAfter
            result = merged
        }
        return result
    }

    /// Ends the current typing/deletion run — called when the caret moves by
    /// mouse or keyboard, so the next edit starts a fresh undo step.
    func breakCoalescing() {
        if !undoOperations.isEmpty {
            undoOperations[undoOperations.count - 1].canCoalesce = false
        }
    }

    /// Reverts the most recent operation in `document` and returns the
    /// selection to restore, or nil when there is nothing to undo.
    func undo(in document: EditedDocument) -> TextSelection? {
        var result: TextSelection?
        if let operation = undoOperations.popLast() {
            redoOperations.append(replay(operation, in: document))
            let caret = operation.position + operation.removedLength
            result = operation.selectionBefore
                ?? TextSelection(anchorOffset: caret, activeOffset: caret)
        }
        return result
    }

    /// Re-applies the most recently undone operation and returns the
    /// selection to restore, or nil when there is nothing to redo.
    func redo(in document: EditedDocument) -> TextSelection? {
        var result: TextSelection?
        if let operation = redoOperations.popLast() {
            undoOperations.append(replay(operation, in: document))
            let caret = operation.position + operation.removedLength
            result = operation.selectionAfter
                ?? TextSelection(anchorOffset: caret, activeOffset: caret)
        }
        return result
    }

    /// Applies `operation` to the document and returns its mirror — the
    /// operation that puts things back. Undo and redo are the same replay in
    /// opposite directions.
    private func replay(_ operation: Operation, in document: EditedDocument) -> Operation {
        let range = operation.position..<(operation.position + operation.insertedLength)
        let displaced = document.replaceForHistory(range, withPieces: operation.removedPieces)
        return Operation(
            position: operation.position,
            insertedLength: operation.removedLength,
            removedPieces: displaced,
            selectionBefore: operation.selectionBefore,
            selectionAfter: operation.selectionAfter,
            canCoalesce: false
        )
    }
}
