import Foundation

/// A line-by-line difference between two documents.
///
/// The edit script is found by patience diff: lines that occur exactly once
/// in both documents are anchors, the longest ordered chain of anchors is
/// kept, and the gaps between them are diffed recursively. A gap with no
/// anchors left goes to Myers' algorithm when it is small, and is reported
/// as a plain replacement when it is not — a bound that keeps a diff of two
/// unrelated 30 MB files from running for minutes to say they differ.
/// Common lines at the start and end are stripped before any of that.
///
/// Lines are compared by their text, exactly: this is `diff`, so the match
/// options of the set operations do not apply here.
enum LineDiff {

    /// One run of the edit script.
    enum Edit: Equatable {
        /// `count` lines present in both, starting at `first` and `second`.
        case equal(first: Int, second: Int, count: Int)
        /// `count` lines of the first document, starting at `first`, that
        /// the second does not have.
        case delete(first: Int, count: Int)
        /// `count` lines of the second document, starting at `second`, that
        /// the first does not have.
        case insert(second: Int, count: Int)
    }

    /// The largest gap Myers runs on; a bigger gap without anchors is one
    /// deletion and one insertion.
    static let myersLimit = 1_000

    /// The edit script turning `first` into `second`, with adjacent runs
    /// of the same kind merged and no empty runs.
    static func diff(_ first: [String], _ second: [String],
                     isCancelled: () -> Bool = { false }) -> [Edit]? {
        var edits: [Edit] = []
        let firstHashes = first.map { $0.hashValue }
        let secondHashes = second.map { $0.hashValue }
        var cancelled = false
        compare(first, second, firstHashes, secondHashes,
                0..<first.count, 0..<second.count, into: &edits,
                isCancelled: isCancelled, cancelled: &cancelled)
        return cancelled ? nil : merged(edits)
    }

    /// `first[range]` is unchanged in `second[range]` when both are equal.
    private static func linesEqual(_ first: [String], _ second: [String],
                                   _ firstHashes: [Int], _ secondHashes: [Int],
                                   _ i: Int, _ j: Int) -> Bool {
        firstHashes[i] == secondHashes[j] && first[i] == second[j]
    }

    // swiftlint:disable:next function_parameter_count
    private static func compare(_ first: [String], _ second: [String],
                                _ firstHashes: [Int], _ secondHashes: [Int],
                                _ firstRange: Range<Int>, _ secondRange: Range<Int>,
                                into edits: inout [Edit], isCancelled: () -> Bool,
                                cancelled: inout Bool) {
        if cancelled || isCancelled() {
            cancelled = true
            return
        }
        var firstLow = firstRange.lowerBound
        var secondLow = secondRange.lowerBound
        var firstHigh = firstRange.upperBound
        var secondHigh = secondRange.upperBound

        // Common prefix.
        var prefix = 0
        while firstLow < firstHigh && secondLow < secondHigh
            && linesEqual(first, second, firstHashes, secondHashes, firstLow, secondLow) {
            firstLow += 1
            secondLow += 1
            prefix += 1
        }
        if prefix > 0 {
            edits.append(.equal(first: firstRange.lowerBound, second: secondRange.lowerBound,
                                count: prefix))
        }
        // Common suffix, reported after the middle.
        var suffix = 0
        while firstLow < firstHigh && secondLow < secondHigh
            && linesEqual(first, second, firstHashes, secondHashes, firstHigh - 1, secondHigh - 1) {
            firstHigh -= 1
            secondHigh -= 1
            suffix += 1
        }

        if firstLow == firstHigh {
            if secondLow < secondHigh {
                edits.append(.insert(second: secondLow, count: secondHigh - secondLow))
            }
        } else if secondLow == secondHigh {
            edits.append(.delete(first: firstLow, count: firstHigh - firstLow))
        } else if let anchors = uniqueAnchors(first, second, firstHashes, secondHashes,
                                              firstLow..<firstHigh, secondLow..<secondHigh),
                  !anchors.isEmpty {
            var previousFirst = firstLow
            var previousSecond = secondLow
            for anchor in anchors {
                compare(first, second, firstHashes, secondHashes,
                        previousFirst..<anchor.first, previousSecond..<anchor.second,
                        into: &edits, isCancelled: isCancelled, cancelled: &cancelled)
                if cancelled {
                    return
                }
                edits.append(.equal(first: anchor.first, second: anchor.second, count: 1))
                previousFirst = anchor.first + 1
                previousSecond = anchor.second + 1
            }
            compare(first, second, firstHashes, secondHashes,
                    previousFirst..<firstHigh, previousSecond..<secondHigh,
                    into: &edits, isCancelled: isCancelled, cancelled: &cancelled)
        } else if (firstHigh - firstLow) + (secondHigh - secondLow) <= myersLimit {
            myers(first, second, firstHashes, secondHashes,
                  firstLow..<firstHigh, secondLow..<secondHigh, into: &edits)
        } else {
            edits.append(.delete(first: firstLow, count: firstHigh - firstLow))
            edits.append(.insert(second: secondLow, count: secondHigh - secondLow))
        }

        if suffix > 0 {
            edits.append(.equal(first: firstHigh, second: secondHigh, count: suffix))
        }
    }

    // MARK: - Patience anchors

    /// The longest chain, in order on both sides, of lines that occur
    /// exactly once in each range. `nil` when there are none.
    private static func uniqueAnchors(_ first: [String], _ second: [String],
                                      _ firstHashes: [Int], _ secondHashes: [Int],
                                      _ firstRange: Range<Int>,
                                      _ secondRange: Range<Int>) -> [(first: Int, second: Int)]? {
        // Count occurrences on each side; a line is a candidate when it is
        // seen once on both.
        var firstPositions: [String: Int] = [:]   // line → index, or -1 when repeated
        for index in firstRange {
            let line = first[index]
            if firstPositions[line] == nil {
                firstPositions[line] = index
            } else {
                firstPositions[line] = -1
            }
        }
        var pairs: [(first: Int, second: Int)] = []
        var secondSeen: [String: Int] = [:]
        for index in secondRange {
            let line = second[index]
            if let position = firstPositions[line], position >= 0 {
                if secondSeen[line] == nil {
                    secondSeen[line] = index
                } else {
                    secondSeen[line] = -1
                }
            }
        }
        for index in secondRange {
            let line = second[index]
            if let position = firstPositions[line], position >= 0,
               let secondPosition = secondSeen[line], secondPosition == index {
                pairs.append((position, index))
            }
        }
        if pairs.isEmpty {
            return nil
        }
        // `pairs` is in second-document order; the longest increasing
        // subsequence of first-document indices is the chain to keep.
        return longestIncreasingChain(pairs)
    }

    /// Patience sorting: the longest subsequence of `pairs` whose `first`
    /// indices increase.
    private static func longestIncreasingChain(_ pairs: [(first: Int, second: Int)])
        -> [(first: Int, second: Int)] {
        var pileTops: [Int] = []              // index into pairs of each pile's top
        var predecessor = [Int](repeating: -1, count: pairs.count)
        for (index, pair) in pairs.enumerated() {
            // Binary search for the first pile whose top is >= pair.first.
            var low = 0
            var high = pileTops.count
            while low < high {
                let mid = (low + high) / 2
                if pairs[pileTops[mid]].first < pair.first {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            if low > 0 {
                predecessor[index] = pileTops[low - 1]
            }
            if low == pileTops.count {
                pileTops.append(index)
            } else {
                pileTops[low] = index
            }
        }
        var chain: [(first: Int, second: Int)] = []
        var cursor = pileTops.last ?? -1
        while cursor >= 0 {
            chain.append(pairs[cursor])
            cursor = predecessor[cursor]
        }
        return chain.reversed()
    }

    // MARK: - Myers

    /// The classic O(ND) shortest-edit-script search over a gap small
    /// enough that its V arrays are nothing to hold.
    // swiftlint:disable:next function_parameter_count
    private static func myers(_ first: [String], _ second: [String],
                              _ firstHashes: [Int], _ secondHashes: [Int],
                              _ firstRange: Range<Int>, _ secondRange: Range<Int>,
                              into edits: inout [Edit]) {
        let n = firstRange.count
        let m = secondRange.count
        let firstBase = firstRange.lowerBound
        let secondBase = secondRange.lowerBound
        let maximum = n + m
        let offset = maximum
        var furthest = [Int](repeating: 0, count: 2 * maximum + 2)
        var trace: [[Int]] = []

        var finished = false
        var depth = 0
        while depth <= maximum && !finished {
            trace.append(furthest)
            var k = -depth
            while k <= depth {
                var x: Int
                if k == -depth || (k != depth && furthest[offset + k - 1] < furthest[offset + k + 1]) {
                    x = furthest[offset + k + 1]
                } else {
                    x = furthest[offset + k - 1] + 1
                }
                var y = x - k
                while x < n && y < m
                    && linesEqual(first, second, firstHashes, secondHashes,
                                  firstBase + x, secondBase + y) {
                    x += 1
                    y += 1
                }
                furthest[offset + k] = x
                if x >= n && y >= m {
                    finished = true
                    break
                }
                k += 2
            }
            if !finished {
                depth += 1
            }
        }

        // Walk the trace back to recover the path, then emit it forwards.
        var path: [(x: Int, y: Int)] = []
        var x = n
        var y = m
        var d = trace.count - 1
        while d >= 0 {
            let v = trace[d]
            let k = x - y
            let previousK: Int
            if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                previousK = k + 1
            } else {
                previousK = k - 1
            }
            let previousX = v[offset + previousK]
            let previousY = previousX - previousK
            while x > previousX && y > previousY {
                path.append((x, y))
                x -= 1
                y -= 1
            }
            if d > 0 {
                path.append((x, y))
            }
            x = previousX
            y = previousY
            d -= 1
        }
        path.append((0, 0))
        path.reverse()

        for index in 1..<path.count {
            let from = path[index - 1]
            let to = path[index]
            if to.x == from.x + 1 && to.y == from.y + 1 {
                edits.append(.equal(first: firstBase + from.x, second: secondBase + from.y, count: 1))
            } else if to.x == from.x + 1 {
                edits.append(.delete(first: firstBase + from.x, count: 1))
            } else if to.y == from.y + 1 {
                edits.append(.insert(second: secondBase + from.y, count: 1))
            }
        }
    }

    // MARK: - Merging

    /// Joins adjacent runs of the same kind and drops empty ones.
    private static func merged(_ edits: [Edit]) -> [Edit] {
        var result: [Edit] = []
        for edit in edits {
            switch (result.last, edit) {
            case (.some(.equal(let f, let s, let c)), .equal(let f2, let s2, let c2))
                where f + c == f2 && s + c == s2:
                result[result.count - 1] = .equal(first: f, second: s, count: c + c2)
            case (.some(.delete(let f, let c)), .delete(let f2, let c2)) where f + c == f2:
                result[result.count - 1] = .delete(first: f, count: c + c2)
            case (.some(.insert(let s, let c)), .insert(let s2, let c2)) where s + c == s2:
                result[result.count - 1] = .insert(second: s, count: c + c2)
            default:
                switch edit {
                case .equal(_, _, let count), .delete(_, let count), .insert(_, let count):
                    if count > 0 {
                        result.append(edit)
                    }
                }
            }
        }
        return result
    }

    // MARK: - Unified format

    /// `edits` as a unified diff with `context` lines around each change,
    /// the shape `diff -u` and `git diff` write and `patch` reads.
    static func unified(_ edits: [Edit], first: [String], second: [String],
                        firstName: String, secondName: String, context: Int = 3) -> String {
        var output = "--- \(firstName)\n+++ \(secondName)\n"
        for hunk in hunks(edits, first: first, second: second, context: context) {
            output += hunk.header + "\n"
            for line in hunk.lines {
                output += line + "\n"
            }
        }
        return output
    }

    struct Hunk: Equatable {
        /// 0-based index of the hunk's first line in each document; for a
        /// document the hunk takes nothing from, where it would go.
        let firstStart: Int
        let firstCount: Int
        let secondStart: Int
        let secondCount: Int
        /// Each line prefixed with a space, `-` or `+`.
        let lines: [String]

        /// `@@ -1,3 +1,4 @@`, with 1-based starts, the way diff writes it.
        var header: String {
            "@@ -\(Hunk.span(firstStart, firstCount)) +\(Hunk.span(secondStart, secondCount)) @@"
        }

        private static func span(_ start: Int, _ count: Int) -> String {
            // An empty span is written with the line before it, as diff does.
            let shown = count == 0 ? start : start + 1
            return count == 1 ? "\(shown)" : "\(shown),\(count)"
        }
    }

    /// One line of the flattened script, with its position in both
    /// documents — for a deleted or inserted line, the position in the other
    /// document is where it would be.
    private struct DiffLine {
        enum Kind { case equal, delete, insert }
        let kind: Kind
        let first: Int
        let second: Int
    }

    private static func flattened(_ edits: [Edit]) -> [DiffLine] {
        var lines: [DiffLine] = []
        var firstCursor = 0
        var secondCursor = 0
        for edit in edits {
            switch edit {
            case .equal(let first, let second, let count):
                for position in 0..<count {
                    lines.append(DiffLine(kind: .equal, first: first + position, second: second + position))
                }
                firstCursor = first + count
                secondCursor = second + count
            case .delete(let first, let count):
                for position in 0..<count {
                    lines.append(DiffLine(kind: .delete, first: first + position, second: secondCursor))
                }
                firstCursor = first + count
            case .insert(let second, let count):
                for position in 0..<count {
                    lines.append(DiffLine(kind: .insert, first: firstCursor, second: second + position))
                }
                secondCursor = second + count
            }
        }
        return lines
    }

    /// Groups the changes into hunks, each wrapped in up to `context` equal
    /// lines on either side; changes closer than twice that share a hunk.
    static func hunks(_ edits: [Edit], first: [String], second: [String], context: Int) -> [Hunk] {
        let lines = flattened(edits)
        var hunks: [Hunk] = []
        var index = 0
        while index < lines.count {
            if lines[index].kind == .equal {
                index += 1
                continue
            }
            let start = max(0, index - context)
            var end = index
            var cursor = index
            while cursor < lines.count {
                while cursor < lines.count && lines[cursor].kind != .equal {
                    cursor += 1
                }
                end = cursor
                var equalEnd = cursor
                while equalEnd < lines.count && lines[equalEnd].kind == .equal {
                    equalEnd += 1
                }
                if equalEnd < lines.count && equalEnd - cursor <= 2 * context {
                    cursor = equalEnd          // the next change joins this hunk
                } else {
                    break
                }
            }
            let hunkEnd = min(lines.count, end + context)
            let slice = lines[start..<hunkEnd]
            var text: [String] = []
            var firstCount = 0
            var secondCount = 0
            for line in slice {
                switch line.kind {
                case .equal:
                    text.append(" " + first[line.first])
                    firstCount += 1
                    secondCount += 1
                case .delete:
                    text.append("-" + first[line.first])
                    firstCount += 1
                case .insert:
                    text.append("+" + second[line.second])
                    secondCount += 1
                }
            }
            if let head = slice.first {
                hunks.append(Hunk(firstStart: head.first, firstCount: firstCount,
                                  secondStart: head.second, secondCount: secondCount, lines: text))
            }
            index = hunkEnd
        }
        return hunks
    }
}
