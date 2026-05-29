import Foundation

/// Holds the single active replacement rule and the background scan of its
/// pattern.
///
/// The rule is *remembered*, never applied to the file on disk. `transformedBytes`
/// produces the edited view of any byte range on demand, so the viewport can
/// show the result live while the original stays untouched until the user saves.
final class EditModel {

    private(set) var rule: ReplacementRule?
    private(set) var matches: SearchScan?

    /// Whether there is a rule with at least one occurrence to apply.
    var isDirty: Bool {
        rule != nil && (matches?.matchCount ?? 0) > 0
    }

    // MARK: - Rule lifecycle

    /// Sets the active rule and starts scanning `file` for its pattern on a
    /// background queue. `onProgress` fires on the main queue as matches arrive.
    func setRule(_ rule: ReplacementRule, file: MappedFile, onProgress: @escaping () -> Void) {
        matches?.cancel()
        self.rule = rule
        if let scan = SearchScan(query: rule.pattern) {
            matches = scan
            scan.start(in: file, onProgress: onProgress)
        } else {
            matches = nil
        }
    }

    /// Sets the rule and scans on the current thread. Used by `--preview`.
    func setRuleSynchronously(_ rule: ReplacementRule, file: MappedFile) {
        matches?.cancel()
        self.rule = rule
        let scan = SearchScan(query: rule.pattern)
        scan?.runSynchronously(in: file)
        matches = scan
    }

    /// Removes the active rule.
    func clear() {
        matches?.cancel()
        rule = nil
        matches = nil
    }

    // MARK: - Transformation

    /// Returns the *edited* bytes for an original byte range — the original
    /// bytes with every pattern occurrence replaced. With no rule, returns the
    /// original bytes unchanged.
    func transformedBytes(
        forOriginalRange range: Range<Int>,
        in buffer: UnsafeRawBufferPointer
    ) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(range.count + 32)

        if let rule, let matches, !range.isEmpty {
            splice(range: range, rule: rule, matches: matches, buffer: buffer, into: &result)
        } else {
            appendBytes(buffer, range, to: &result)
        }
        return result
    }

    /// Copies `range`, substituting `replacement` at each pattern occurrence.
    ///
    /// A match is rendered by the chunk in which it *begins*; a chunk that a
    /// match merely extends into skips the bytes that match covers. This keeps
    /// long lines split across chunks consistent.
    private func splice(
        range: Range<Int>,
        rule: ReplacementRule,
        matches: SearchScan,
        buffer: UnsafeRawBufferPointer,
        into result: inout [UInt8]
    ) {
        let patternLength = rule.patternBytes.count
        // Catch a match that begins just before `range` yet extends into it.
        let searchFrom = max(0, range.lowerBound - patternLength + 1)
        let candidates = matches.matchOffsets(beginningIn: searchFrom..<range.upperBound)

        var cursor = range.lowerBound
        for matchStart in candidates {
            let matchEnd = matchStart + patternLength
            if matchStart >= range.lowerBound {
                if matchStart > cursor {
                    appendBytes(buffer, cursor..<matchStart, to: &result)
                }
                result.append(contentsOf: rule.replacementBytes)
                cursor = matchEnd
            } else {
                // The match began in an earlier chunk; skip its bytes here.
                cursor = max(cursor, matchEnd)
            }
        }
        if cursor < range.upperBound {
            appendBytes(buffer, cursor..<range.upperBound, to: &result)
        }
    }

    private func appendBytes(
        _ buffer: UnsafeRawBufferPointer,
        _ range: Range<Int>,
        to result: inout [UInt8]
    ) {
        if !range.isEmpty {
            result.append(contentsOf: buffer[range])
        }
    }
}
