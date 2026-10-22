import Foundation

/// What one Backspace or Forward Delete removes, decided the way the
/// system text views decide it.
extension TextEncoding {

    /// The byte length of what Backspace removes from the end of `bytes`
    /// when that is several scalars: a whole emoji, flag or accented Latin
    /// letter, but only the last mark of an Indic, Thai, Arabic or Hebrew
    /// cluster. Nil for a single scalar, which a scalar step handles.
    func backwardDeletionLength<Bytes: Collection>(endOf bytes: Bytes) -> Int? where Bytes.Element == UInt8 {
        multiScalarByteLength(of: lastDeletionCluster(in: decode(bytes)))
    }

    /// The byte length of what Forward Delete removes from the start of
    /// `bytes` when that is several scalars: a whole character, except that
    /// an Indic conjunct goes up to its first virama. Nil for a single
    /// scalar.
    func forwardDeletionLength<Bytes: Collection>(startOf bytes: Bytes) -> Int? where Bytes.Element == UInt8 {
        multiScalarByteLength(of: firstComposedCharacter(in: decode(bytes)).map(TextEncoding.endingAtFirstVirama))
    }

    private func lastDeletionCluster(in text: String) -> [Unicode.Scalar]? {
        let string = text as NSString
        var result: [Unicode.Scalar]?
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length),
                                   options: [.byDeletionClusters, .reverse]) { substring, _, _, stop in
            result = substring.map { Array($0.unicodeScalars) }
            stop.pointee = true
        }
        return result
    }

    private func firstComposedCharacter(in text: String) -> [Unicode.Scalar]? {
        let string = text as NSString
        var result: [Unicode.Scalar]?
        if string.length > 0 {
            let range = string.rangeOfComposedCharacterSequence(at: 0)
            result = Array(string.substring(with: range).unicodeScalars)
        }
        return result
    }

    /// `scalars` up to their first virama and any joiner after it.
    private static func endingAtFirstVirama(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var result = scalars
        if let virama = scalars.firstIndex(where: { $0.properties.canonicalCombiningClass == .virama }) {
            let joiners: Set<Unicode.Scalar> = ["\u{200C}", "\u{200D}"]
            var end = virama + 1
            while end < scalars.count, joiners.contains(scalars[end]) {
                end += 1
            }
            result = Array(scalars[..<end])
        }
        return result
    }

    private func multiScalarByteLength(of scalars: [Unicode.Scalar]?) -> Int? {
        var result: Int?
        if let scalars, scalars.count > 1 {
            result = scalars.reduce(0) { $0 + byteLength(of: $1) }
        }
        return result
    }
}
