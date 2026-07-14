import Foundation

/// Maps the logical byte space of an edited document onto pieces of two
/// backing stores: the memory-mapped original file and the append-only add
/// buffer. Edits are splices of the piece sequence — the backing bytes are
/// never moved or copied — so deleting a 10 GB selection stores a handful of
/// pieces, not 10 GB.
///
/// The pieces live in a balanced binary tree ordered by logical position,
/// with each node aggregating its subtree's byte length. Lookups and splices
/// are O(log pieces), which matters once Replace All materialises hundreds of
/// thousands of pieces. The tree is a treap with a deterministic priority
/// stream, its nodes pooled in a flat array with integer links (no per-node
/// allocations, reproducible shape in tests).
final class PieceTable {

    /// One contiguous run of logical bytes, referencing either backing store.
    struct Piece: Equatable {
        enum Source: Equatable {
            case original
            case added
        }

        var source: Source
        var start: Int
        var length: Int

        var end: Int {
            start + length
        }
    }

    private struct Node {
        var piece: Piece
        var left: Int32
        var right: Int32
        var priority: UInt64
        var subtreeLength: Int
    }

    private static let none: Int32 = -1

    private var nodes: ContiguousArray<Node> = []
    private var freeNodes: [Int32] = []
    private var root = PieceTable.none

    /// SplitMix64 state for treap priorities — deterministic, so the tree
    /// shape (and any bug) is reproducible.
    private var priorityState: UInt64 = 0x9E3779B97F4A7C15

    /// The logical length of the document in bytes.
    private(set) var length: Int

    /// The number of pieces currently in the table.
    private(set) var pieceCount = 0

    /// True once any splice has been applied. Reads can take a zero-overhead
    /// passthrough path while this is false.
    private(set) var hasEdits = false

    init(originalLength: Int) {
        self.length = originalLength
        if originalLength > 0 {
            let whole = Piece(source: .original, start: 0, length: originalLength)
            root = makeNode(whole)
        }
    }

    // MARK: - Reads

    /// The pieces covering `logicalRange`, in order, with the first and last
    /// trimmed to the range. O(log pieces + result count).
    func pieces(in logicalRange: Range<Int>) -> [Piece] {
        var result: [Piece] = []
        let clamped = logicalRange.clamped(to: 0..<length)
        if !clamped.isEmpty {
            collectPieces(root, subtreeStart: 0, range: clamped, into: &result)
        }
        return result
    }

    /// Copies the logical bytes in `logicalRange` out of the backing stores.
    func bytes(
        in logicalRange: Range<Int>,
        original: UnsafeRawBufferPointer,
        added: AddedByteStore
    ) -> [UInt8] {
        let clamped = logicalRange.clamped(to: 0..<length)
        var result: [UInt8] = []
        result.reserveCapacity(clamped.count)
        for piece in pieces(in: clamped) {
            switch piece.source {
            case .original:
                result.append(contentsOf: original[piece.start..<piece.end])
            case .added:
                result.append(contentsOf: added.bytes(in: piece.start..<piece.end))
            }
        }
        return result
    }

    /// The original-file offset behind `logicalOffset`, or `nil` when the
    /// offset lies inside added text (or outside the document).
    func originalOffset(forLogical logicalOffset: Int) -> Int? {
        var result: Int?
        if logicalOffset >= 0 && logicalOffset < length {
            var node = root
            var offset = logicalOffset
            while node != PieceTable.none {
                let current = nodes[Int(node)]
                let leftLength = subtreeLength(current.left)
                if offset < leftLength {
                    node = current.left
                } else if offset < leftLength + current.piece.length {
                    if current.piece.source == .original {
                        result = current.piece.start + (offset - leftLength)
                    }
                    node = PieceTable.none
                } else {
                    offset -= leftLength + current.piece.length
                    node = current.right
                }
            }
        }
        return result
    }

    // MARK: - Mutations

    /// Replaces `logicalRange` with a piece over `addedRange` of the add
    /// buffer, returning the removed pieces (trimmed to the range) for undo.
    /// An insertion that directly extends the most recently written added
    /// piece grows that piece in place, so continuous typing stays one piece.
    @discardableResult
    func replace(_ logicalRange: Range<Int>, withAddedRange addedRange: Range<Int>) -> [Piece] {
        var removed: [Piece] = []
        let coalesced = logicalRange.isEmpty && !addedRange.isEmpty
            && growAddedPiece(root, endingAt: logicalRange.lowerBound,
                              contiguousWith: addedRange.lowerBound, by: addedRange.count)
        if coalesced {
            length += addedRange.count
            hasEdits = true
        } else {
            var inserted: [Piece] = []
            if !addedRange.isEmpty {
                inserted.append(Piece(source: .added,
                                      start: addedRange.lowerBound,
                                      length: addedRange.count))
            }
            removed = replace(logicalRange, withPieces: inserted)
        }
        return removed
    }

    /// Replaces `logicalRange` with `newPieces` (used by undo/redo to
    /// re-splice previously removed pieces), returning the removed pieces.
    @discardableResult
    func replace(_ logicalRange: Range<Int>, withPieces newPieces: [Piece]) -> [Piece] {
        precondition(logicalRange.lowerBound >= 0 && logicalRange.upperBound <= length,
                     "replace range out of bounds")
        let (left, rest) = split(root, at: logicalRange.lowerBound)
        let (middle, right) = split(rest, at: logicalRange.count)

        var removed: [Piece] = []
        appendPieces(middle, to: &removed)
        recycle(middle)

        var insertedTree = PieceTable.none
        var insertedLength = 0
        for piece in newPieces where piece.length > 0 {
            insertedTree = merge(insertedTree, makeNode(piece))
            insertedLength += piece.length
        }

        root = merge(merge(left, insertedTree), right)
        length += insertedLength - logicalRange.count
        hasEdits = true
        return removed
    }

    // MARK: - Tree plumbing

    private func subtreeLength(_ node: Int32) -> Int {
        node == PieceTable.none ? 0 : nodes[Int(node)].subtreeLength
    }

    private func update(_ node: Int32) {
        let current = Int(node)
        nodes[current].subtreeLength = nodes[current].piece.length
            + subtreeLength(nodes[current].left)
            + subtreeLength(nodes[current].right)
    }

    private func makeNode(_ piece: Piece) -> Int32 {
        let node = Node(piece: piece, left: PieceTable.none, right: PieceTable.none,
                        priority: nextPriority(), subtreeLength: piece.length)
        var index: Int32
        if let reused = freeNodes.popLast() {
            nodes[Int(reused)] = node
            index = reused
        } else {
            nodes.append(node)
            index = Int32(nodes.count - 1)
        }
        pieceCount += 1
        return index
    }

    /// Returns a subtree's nodes to the free pool.
    private func recycle(_ node: Int32) {
        if node != PieceTable.none {
            recycle(nodes[Int(node)].left)
            recycle(nodes[Int(node)].right)
            freeNodes.append(node)
            pieceCount -= 1
        }
    }

    private func nextPriority() -> UInt64 {
        priorityState &+= 0x9E3779B97F4A7C15
        var mixed = priorityState
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
        return mixed ^ (mixed >> 31)
    }

    /// Joins two trees where every byte of `left` logically precedes `right`.
    private func merge(_ left: Int32, _ right: Int32) -> Int32 {
        var result: Int32
        if left == PieceTable.none {
            result = right
        } else if right == PieceTable.none {
            result = left
        } else if nodes[Int(left)].priority > nodes[Int(right)].priority {
            nodes[Int(left)].right = merge(nodes[Int(left)].right, right)
            update(left)
            result = left
        } else {
            nodes[Int(right)].left = merge(left, nodes[Int(right)].left)
            update(right)
            result = right
        }
        return result
    }

    /// Splits `node` so the first tree holds exactly `count` bytes, splitting
    /// a piece in two when the cut lands inside one.
    private func split(_ node: Int32, at count: Int) -> (Int32, Int32) {
        var result = (PieceTable.none, PieceTable.none)
        if node != PieceTable.none {
            let leftLength = subtreeLength(nodes[Int(node)].left)
            let pieceEnd = leftLength + nodes[Int(node)].piece.length
            if count <= leftLength {
                let (first, second) = split(nodes[Int(node)].left, at: count)
                nodes[Int(node)].left = second
                update(node)
                result = (first, node)
            } else if count >= pieceEnd {
                let (first, second) = split(nodes[Int(node)].right, at: count - pieceEnd)
                nodes[Int(node)].right = first
                update(node)
                result = (node, second)
            } else {
                let keep = count - leftLength
                let piece = nodes[Int(node)].piece
                let tail = Piece(source: piece.source,
                                 start: piece.start + keep,
                                 length: piece.length - keep)
                nodes[Int(node)].piece.length = keep
                let detachedRight = nodes[Int(node)].right
                nodes[Int(node)].right = PieceTable.none
                update(node)
                result = (node, merge(makeNode(tail), detachedRight))
            }
        }
        return result
    }

    /// Appends a subtree's pieces in logical order.
    private func appendPieces(_ node: Int32, to result: inout [Piece]) {
        if node != PieceTable.none {
            appendPieces(nodes[Int(node)].left, to: &result)
            result.append(nodes[Int(node)].piece)
            appendPieces(nodes[Int(node)].right, to: &result)
        }
    }

    /// Collects the pieces intersecting `range`, trimming the boundary pieces.
    /// `subtreeStart` is the logical offset where `node`'s subtree begins.
    private func collectPieces(
        _ node: Int32,
        subtreeStart: Int,
        range: Range<Int>,
        into result: inout [Piece]
    ) {
        if node != PieceTable.none {
            let current = nodes[Int(node)]
            let pieceStart = subtreeStart + subtreeLength(current.left)
            let pieceEnd = pieceStart + current.piece.length

            if range.lowerBound < pieceStart {
                collectPieces(current.left, subtreeStart: subtreeStart, range: range, into: &result)
            }
            let lower = max(range.lowerBound, pieceStart)
            let upper = min(range.upperBound, pieceEnd)
            if lower < upper {
                result.append(Piece(source: current.piece.source,
                                    start: current.piece.start + (lower - pieceStart),
                                    length: upper - lower))
            }
            if range.upperBound > pieceEnd {
                collectPieces(current.right, subtreeStart: pieceEnd, range: range, into: &result)
            }
        }
    }

    /// Descends to the piece ending exactly at `offset` and, when it is the
    /// added piece contiguous with `addedStart`, grows it by `delta` —
    /// updating subtree lengths on the way back up. Returns whether it grew.
    private func growAddedPiece(
        _ node: Int32,
        endingAt offset: Int,
        contiguousWith addedStart: Int,
        by delta: Int
    ) -> Bool {
        var result = false
        if node != PieceTable.none && offset > 0 {
            let leftLength = subtreeLength(nodes[Int(node)].left)
            let pieceEnd = leftLength + nodes[Int(node)].piece.length
            if offset <= leftLength {
                result = growAddedPiece(nodes[Int(node)].left, endingAt: offset,
                                        contiguousWith: addedStart, by: delta)
            } else if offset > pieceEnd {
                result = growAddedPiece(nodes[Int(node)].right, endingAt: offset - pieceEnd,
                                        contiguousWith: addedStart, by: delta)
            } else if offset == pieceEnd {
                let piece = nodes[Int(node)].piece
                if piece.source == .added && piece.end == addedStart {
                    nodes[Int(node)].piece.length += delta
                    result = true
                }
            }
            if result {
                update(node)
            }
        }
        return result
    }
}
