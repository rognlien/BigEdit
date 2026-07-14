import XCTest
@testable import BigEdit

/// The piece table is the storage behind every edit, so it is tested two
/// ways: focused unit cases for each operation, and fuzz runs that mirror
/// hundreds of random splices against a plain `[UInt8]` model.
final class PieceTableTests: XCTestCase {

    // MARK: - Helpers

    private func contents(
        _ table: PieceTable, original: [UInt8], added: AddBuffer
    ) -> [UInt8] {
        original.withUnsafeBytes { buffer in
            table.bytes(in: 0..<table.length, original: buffer, added: added)
        }
    }

    private func bytes(
        of pieces: [PieceTable.Piece], original: [UInt8], added: AddBuffer
    ) -> [UInt8] {
        var result: [UInt8] = []
        for piece in pieces {
            switch piece.source {
            case .original:
                result.append(contentsOf: original[piece.start..<piece.end])
            case .added:
                result.append(contentsOf: added.bytes(in: piece.start..<piece.end))
            }
        }
        return result
    }

    /// Inserts `text` at `offset`, mirroring how the editor will drive the
    /// table: append the bytes to the add buffer, then splice.
    private func insert(
        _ text: String, at offset: Int, table: PieceTable, added: AddBuffer
    ) -> [PieceTable.Piece] {
        let range = added.append(Array(text.utf8))
        return table.replace(offset..<offset, withAddedRange: range)
    }

    // MARK: - Basic splices

    func testUneditedTableIsPassthrough() {
        let original = Array("hello world".utf8)
        let table = PieceTable(originalLength: original.count)
        let added = AddBuffer()

        XCTAssertFalse(table.hasEdits)
        XCTAssertEqual(table.length, original.count)
        XCTAssertEqual(table.pieceCount, 1)
        XCTAssertEqual(contents(table, original: original, added: added), original)
        XCTAssertEqual(table.originalOffset(forLogical: 0), 0)
        XCTAssertEqual(table.originalOffset(forLogical: 10), 10)
        XCTAssertNil(table.originalOffset(forLogical: 11))
        XCTAssertNil(table.originalOffset(forLogical: -1))
    }

    func testInsertInMiddle() {
        let original = Array("hello world".utf8)
        let table = PieceTable(originalLength: original.count)
        let added = AddBuffer()

        let removed = insert("beautiful ", at: 6, table: table, added: added)

        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(table.hasEdits)
        XCTAssertEqual(String(decoding: contents(table, original: original, added: added),
                              as: UTF8.self),
                       "hello beautiful world")
        XCTAssertEqual(table.pieceCount, 3)
    }

    func testDeleteAcrossPieces() {
        let original = Array("one two three".utf8)
        let table = PieceTable(originalLength: original.count)
        let added = AddBuffer()
        _ = insert("X", at: 4, table: table, added: added)   // "one Xtwo three"

        // Delete "e Xtw" — spans original, added, and original pieces.
        let removed = table.replace(2..<7, withAddedRange: 0..<0)

        XCTAssertEqual(String(decoding: contents(table, original: original, added: added),
                              as: UTF8.self),
                       "ono three")
        XCTAssertEqual(String(decoding: bytes(of: removed, original: original, added: added),
                              as: UTF8.self),
                       "e Xtw")
    }

    func testTypingCoalescesIntoOnePiece() {
        let original = Array("ab".utf8)
        let table = PieceTable(originalLength: original.count)
        let added = AddBuffer()

        _ = insert("x", at: 1, table: table, added: added)
        _ = insert("y", at: 2, table: table, added: added)
        _ = insert("z", at: 3, table: table, added: added)

        XCTAssertEqual(String(decoding: contents(table, original: original, added: added),
                              as: UTF8.self),
                       "axyzb")
        // original head + one coalesced added piece + original tail.
        XCTAssertEqual(table.pieceCount, 3)
    }

    func testCoalescingRequiresContiguity() {
        let original = Array("ab".utf8)
        let table = PieceTable(originalLength: original.count)
        let added = AddBuffer()

        _ = insert("x", at: 1, table: table, added: added)
        // Typing somewhere else, then back — the add-buffer bytes are no
        // longer contiguous with the first piece, so no coalescing.
        _ = insert("q", at: 0, table: table, added: added)
        _ = insert("y", at: 3, table: table, added: added)

        XCTAssertEqual(String(decoding: contents(table, original: original, added: added),
                              as: UTF8.self),
                       "qaxyb")
        XCTAssertEqual(table.pieceCount, 5)
    }

    func testEmptyOriginal() {
        let table = PieceTable(originalLength: 0)
        let added = AddBuffer()

        XCTAssertEqual(table.length, 0)
        XCTAssertEqual(table.pieceCount, 0)
        _ = insert("fresh", at: 0, table: table, added: added)
        XCTAssertEqual(String(decoding: contents(table, original: [], added: added),
                              as: UTF8.self),
                       "fresh")
    }

    func testOriginalOffsetShiftsAroundAnInsertion() {
        let original = Array("abcdef".utf8)
        let table = PieceTable(originalLength: original.count)
        let added = AddBuffer()
        _ = insert("XY", at: 3, table: table, added: added)   // "abcXYdef"

        XCTAssertEqual(table.originalOffset(forLogical: 2), 2)    // 'c'
        XCTAssertNil(table.originalOffset(forLogical: 3))         // 'X' — added
        XCTAssertNil(table.originalOffset(forLogical: 4))         // 'Y' — added
        XCTAssertEqual(table.originalOffset(forLogical: 5), 3)    // 'd'
        XCTAssertEqual(table.originalOffset(forLogical: 7), 5)    // 'f'
    }

    func testPiecesAreTrimmedToTheRequestedRange() {
        let original = Array("abcdef".utf8)
        let table = PieceTable(originalLength: original.count)
        let added = AddBuffer()
        _ = insert("XY", at: 3, table: table, added: added)   // "abcXYdef"

        let pieces = table.pieces(in: 1..<7)
        XCTAssertEqual(String(decoding: bytes(of: pieces, original: original, added: added),
                              as: UTF8.self),
                       "bcXYde")
        XCTAssertEqual(pieces.first, PieceTable.Piece(source: .original, start: 1, length: 2))
        XCTAssertEqual(pieces.last, PieceTable.Piece(source: .original, start: 3, length: 2))
    }

    func testRespliceOfRemovedPiecesUndoesAnEdit() {
        let original = Array("the quick brown fox".utf8)
        let table = PieceTable(originalLength: original.count)
        let added = AddBuffer()
        let before = contents(table, original: original, added: added)

        let addedRange = added.append(Array("slow".utf8))
        let removed = table.replace(4..<9, withAddedRange: addedRange)   // quick → slow
        XCTAssertEqual(String(decoding: contents(table, original: original, added: added),
                              as: UTF8.self),
                       "the slow brown fox")

        _ = table.replace(4..<8, withPieces: removed)                    // undo
        XCTAssertEqual(contents(table, original: original, added: added), before)
    }

    // MARK: - Fuzz

    /// Mirrors hundreds of random splices against a plain array model,
    /// checking full contents, length, removed-piece bytes, and a random
    /// subrange read after every operation.
    func testFuzzAgainstNaiveModel() {
        for seed: UInt64 in [1, 2, 3, 42, 999] {
            var generator = SeededGenerator(seed: seed)
            let originalLength = Int.random(in: 0...800, using: &generator)
            let original = (0..<originalLength).map { _ in
                UInt8.random(in: 32...126, using: &generator)
            }
            var model = original
            let table = PieceTable(originalLength: original.count)
            let added = AddBuffer()

            for step in 0..<300 {
                let lower = Int.random(in: 0...model.count, using: &generator)
                let upper = Int.random(in: lower...min(model.count, lower + 40), using: &generator)
                let insertLength = Int.random(in: 0...20, using: &generator)
                let insertBytes = (0..<insertLength).map { _ in
                    UInt8.random(in: 32...126, using: &generator)
                }

                let expectedRemoved = Array(model[lower..<upper])
                let addedRange = added.append(insertBytes)
                let removed = table.replace(lower..<upper, withAddedRange: addedRange)
                model.replaceSubrange(lower..<upper, with: insertBytes)

                let context = "seed \(seed) step \(step)"
                XCTAssertEqual(table.length, model.count, context)
                XCTAssertEqual(bytes(of: removed, original: original, added: added),
                               expectedRemoved, context)
                XCTAssertEqual(contents(table, original: original, added: added), model, context)

                let probeLower = Int.random(in: 0...model.count, using: &generator)
                let probeUpper = Int.random(in: probeLower...model.count, using: &generator)
                let probe = original.withUnsafeBytes { buffer in
                    table.bytes(in: probeLower..<probeUpper, original: buffer, added: added)
                }
                XCTAssertEqual(probe, Array(model[probeLower..<probeUpper]), context)
            }
        }
    }

    /// Every random edit is immediately undone by re-splicing the removed
    /// pieces; the document must return to its exact prior state.
    func testFuzzUndoRoundTrip() {
        for seed: UInt64 in [7, 88, 4096] {
            var generator = SeededGenerator(seed: seed)
            let original = (0..<500).map { _ in UInt8.random(in: 32...126, using: &generator) }
            var model = original
            let table = PieceTable(originalLength: original.count)
            let added = AddBuffer()

            for step in 0..<200 {
                let lower = Int.random(in: 0...model.count, using: &generator)
                let upper = Int.random(in: lower...min(model.count, lower + 30), using: &generator)
                let insertLength = Int.random(in: 0...12, using: &generator)
                let insertBytes = (0..<insertLength).map { _ in
                    UInt8.random(in: 32...126, using: &generator)
                }
                let context = "seed \(seed) step \(step)"
                let before = contents(table, original: original, added: added)

                let addedRange = added.append(insertBytes)
                let removed = table.replace(lower..<upper, withAddedRange: addedRange)

                let undone = table.replace(lower..<(lower + insertLength), withPieces: removed)
                XCTAssertEqual(contents(table, original: original, added: added), before, context)
                XCTAssertEqual(bytes(of: undone, original: original, added: added),
                               insertBytes, context)

                // Redo the edit so the fuzz walk keeps moving forward.
                _ = table.replace(lower..<upper, withPieces: [
                    PieceTable.Piece(source: .added,
                                     start: addedRange.lowerBound,
                                     length: addedRange.count)
                ])
                model.replaceSubrange(lower..<upper, with: insertBytes)
                XCTAssertEqual(contents(table, original: original, added: added), model, context)
            }
        }
    }
}
