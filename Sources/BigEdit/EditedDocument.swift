import Foundation

/// The document as the user works with it: the memory-mapped original file
/// with any unsaved edits applied on demand.
///
/// This is the single read funnel between the UI and the underlying bytes.
/// Offsets at this level are *logical* — they address the edited document.
/// While there are no edits the logical space equals the original file's and
/// every read takes a zero-overhead passthrough straight off the mmap; once
/// the piece table holds edits, reads assemble from it. Memory stays
/// proportional to the edits, never the file.
final class EditedDocument {

    /// The memory-mapped original file. Exposed for the components that speak
    /// original byte offsets — the line index, search, and save.
    let file: MappedFile

    /// The deferred-edit model whose rule (if any) transforms displayed text.
    let editModel: EditModel

    /// The immutable line index of the original file.
    let lineIndex: LineIndex

    /// Logical bytes → (original mmap | add buffer) pieces.
    let pieceTable: PieceTable

    /// Append-only storage for every inserted byte.
    let addBuffer: AddBuffer

    /// Line / visual-row layout of the logical document.
    let layout: EditedLayout

    /// Piece-level edit history. Carried across a save into the document
    /// built over the freshly written file, so ⌘Z still works after ⌘S.
    let undoStack: UndoStack

    /// Mappings that earlier saves wrote over, kept while history still
    /// refers to them. A save replaces the file by atomic rename, so the old
    /// inode stays readable for as long as it is mapped — which is what lets
    /// an undo after a save put back bytes that now exist only there.
    private(set) var retiredFiles: [MappedFile]

    /// How many retired mappings are kept before the history is let go. Each
    /// one pins an old inode and its address space, so rather than grow
    /// without bound across a long run of saves, the history is cleared once
    /// this many are held.
    static let maximumRetiredMappings = 8

    /// Where unsaved edits are written so a crash does not lose them. Every
    /// splice and every inserted byte is mirrored here as it happens.
    var journal: EditJournal?

    /// True while a journal is being replayed into this document, so the
    /// replay is not journaled again.
    private var isReplayingJournal = false

    init(file: MappedFile, editModel: EditModel, lineIndex: LineIndex,
         addBuffer: AddBuffer = AddBuffer(), undoStack: UndoStack = UndoStack(),
         retiredFiles: [MappedFile] = []) {
        self.file = file
        self.editModel = editModel
        self.lineIndex = lineIndex
        self.addBuffer = addBuffer
        self.undoStack = undoStack
        self.retiredFiles = retiredFiles
        self.pieceTable = PieceTable(originalLength: file.size)
        self.layout = EditedLayout(file: file, index: lineIndex)
    }

    /// Builds the document over a file that has just been saved, carrying
    /// `previous`'s edit history so undo reaches back across the save.
    ///
    /// The saved file's bytes are exactly the previous document's logical
    /// bytes, so every history record's positions still mean what they meant.
    /// What no longer holds is that `.original` pieces refer to the current
    /// file: they meant the file before the save, which is retired here and
    /// the records rewritten to point at it. The add buffer comes along
    /// unchanged, since `.added` pieces refer to it directly.
    convenience init(file: MappedFile, editModel: EditModel, lineIndex: LineIndex,
                     inheritingHistoryFrom previous: EditedDocument) {
        let history = previous.undoStack
        var retired = previous.retiredFiles
        if history.isEmpty {
            retired = []                          // nothing refers to any of them
        } else {
            if retired.count >= EditedDocument.maximumRetiredMappings {
                history.clear()
                retired = []
            } else {
                history.retireOriginalPieces(as: retired.count)
                retired.append(previous.file)
            }
        }
        history.breakCoalescing()                 // a save ends any typing run
        self.init(file: file, editModel: editModel, lineIndex: lineIndex,
                  addBuffer: previous.addBuffer, undoStack: history, retiredFiles: retired)
    }

    /// Whether the document accepts positional edits. Set from the detected
    /// file format at load: only UTF-8 / ASCII text is editable, since the
    /// viewport decodes UTF-8 and edits are spliced as UTF-8 bytes.
    var isEditable = false

    /// The byte sequence Return inserts — the document's detected line ending.
    var newlineBytes: [UInt8] = [0x0A]

    /// The logical document length in bytes.
    var length: Int {
        pieceTable.length
    }

    /// Replaces `logicalRange` with `bytes` — the single mutation entry
    /// point. Keeps the piece table, the layout, and the undo history in
    /// step, and returns the removed pieces.
    @discardableResult
    func replace(_ logicalRange: Range<Int>, with bytes: [UInt8],
                 selectionBefore: TextSelection? = nil) -> [PieceTable.Piece] {
        let removedContainsNewline = rangeContainsNewline(logicalRange)
        let addedRange = addBuffer.append(bytes)
        let removed = pieceTable.replace(logicalRange, withAddedRange: addedRange)
        layout.applyReplacement(logicalRange, insertedLength: bytes.count) { range in
            self.bytes(in: range)
        }
        if let journal, !isReplayingJournal {
            journal.recordAppend(bytes)
            journal.recordSplice(logicalRange, pieces: [
                PieceTable.Piece(source: .added, start: addedRange.lowerBound, length: bytes.count)
            ])
        }
        undoStack.recordEdit(
            position: logicalRange.lowerBound,
            insertedLength: bytes.count,
            removedPieces: removed,
            insertedContainsNewline: bytes.contains(0x0A),
            removedContainsNewline: removedContainsNewline,
            selectionBefore: selectionBefore
        )
        return removed
    }

    /// Re-splices pieces without touching the undo history — the undo
    /// stack's replay primitive.
    @discardableResult
    func replaceForHistory(_ logicalRange: Range<Int>,
                           withPieces pieces: [PieceTable.Piece]) -> [PieceTable.Piece] {
        let removed = pieceTable.replace(logicalRange, withPieces: pieces)
        let insertedLength = pieces.reduce(0) { $0 + $1.length }
        layout.applyReplacement(logicalRange, insertedLength: insertedLength) { range in
            self.bytes(in: range)
        }
        if !isReplayingJournal {
            journal?.recordSplice(logicalRange, pieces: pieces)
        }
        return removed
    }

    /// Rebuilds the unsaved edits recorded in `journal` over this document,
    /// which must be over the journal's baseline file. Returns false, leaving
    /// the document untouched, if the journal cannot be replayed.
    @discardableResult
    func recover(from journal: EditJournal) -> Bool {
        guard !hasEdits, let operations = journal.readOperations() else {
            return false
        }
        var applied = true
        isReplayingJournal = true
        addBuffer.append(journal.loadBytes())
        for operation in operations where applied {
            let addedCount = addBuffer.count
            let fits = operation.range.upperBound <= length && operation.pieces.allSatisfy { piece in
                piece.source == .original ? piece.end <= file.size : piece.end <= addedCount
            }
            if fits {
                replaceForHistory(operation.range, withPieces: operation.pieces)
            } else {
                applied = false
            }
        }
        isReplayingJournal = false
        self.journal = journal
        return applied
    }

    /// Whether `range` covers a newline. Small ranges are checked exactly;
    /// large ones are assumed to — this only steers undo coalescing.
    private func rangeContainsNewline(_ range: Range<Int>) -> Bool {
        var result = !range.isEmpty
        if range.count <= 64 {
            result = bytes(in: range).contains(0x0A)
        }
        return result
    }

    /// The retired mappings' bytes, in generation order, for piece reads.
    var retiredBuffers: [UnsafeRawBufferPointer] {
        retiredFiles.map(\.buffer)
    }

    /// True once any positional edit has been applied.
    var hasEdits: Bool {
        pieceTable.hasEdits
    }

    /// Whether displayed text currently differs from the underlying bytes
    /// (a replacement rule is active).
    var hasDisplayTransform: Bool {
        editModel.rule != nil
    }

    /// The logical byte at `offset`, or `nil` outside the document.
    func byte(at offset: Int) -> UInt8? {
        var result: UInt8?
        if offset >= 0 && offset < length {
            if pieceTable.hasEdits {
                result = pieceTable.bytes(in: offset..<(offset + 1),
                                          original: file.buffer,
                                          added: addBuffer,
                                          retired: retiredBuffers).first
            } else {
                result = file.buffer[offset]
            }
        }
        return result
    }

    /// Copies the logical bytes in `range`, without display transforms.
    /// The range is clamped to the document bounds.
    func bytes(in range: Range<Int>) -> [UInt8] {
        var result: [UInt8] = []
        let clamped = range.clamped(to: 0..<length)
        if !clamped.isEmpty {
            if pieceTable.hasEdits {
                result = pieceTable.bytes(in: clamped, original: file.buffer,
                                          added: addBuffer, retired: retiredBuffers)
            } else {
                result = Array(UnsafeRawBufferPointer(rebasing: file.buffer[clamped]))
            }
        }
        return result
    }

    /// The bytes in `range` as they should be displayed — with the active
    /// replacement rule spliced in, if any. A rule and positional edits are
    /// mutually exclusive, so the rule path always reads original offsets.
    func displayBytes(in range: Range<Int>) -> [UInt8] {
        var result: [UInt8]
        if editModel.rule != nil {
            let clamped = range.clamped(to: 0..<file.size)
            result = editModel.transformedBytes(forOriginalRange: clamped, in: file.buffer)
        } else {
            result = bytes(in: range)
        }
        return result
    }

    // MARK: - UTF-8 character stepping

    /// The logical offset of the next UTF-8 character boundary after `offset`.
    func nextCharacterOffset(after offset: Int) -> Int {
        let size = length
        var result = size
        if offset < size {
            var candidate = offset + 1
            while candidate < size, let byte = byte(at: candidate), (byte & 0xC0) == 0x80 {
                candidate += 1
            }
            result = candidate
        }
        return result
    }

    /// The logical offset of the previous UTF-8 character boundary before
    /// `offset`.
    func previousCharacterOffset(before offset: Int) -> Int {
        var result = 0
        if offset > 0 {
            var candidate = offset - 1
            while candidate > 0, let byte = byte(at: candidate), (byte & 0xC0) == 0x80 {
                candidate -= 1
            }
            result = candidate
        }
        return result
    }
}
