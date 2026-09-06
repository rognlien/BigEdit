import Foundation

/// How a delimited file is split into fields, plus the display choices that
/// ride along with it.
///
/// Detection proposes a dialect from a bounded head sample — so it stays cheap
/// on a multi-gigabyte file — and every part of it can then be overridden from
/// the format bar.
struct CSVDialect: Equatable {

    /// The character that separates fields.
    var delimiter: Character

    /// The character wrapping fields that contain a delimiter, or `nil` when
    /// the file quotes nothing.
    var quote: Character?

    /// Whether the first row names the columns.
    var hasHeaderRow: Bool

    /// Whether the header row stays pinned to the top while scrolling.
    var pinsHeaderRow: Bool

    /// Whether surrounding spaces are ignored when measuring and drawing a
    /// field. Display only — the file on disk is never rewritten.
    var trimsFieldWhitespace: Bool

    static let defaultQuote: Character = "\""

    init(delimiter: Character = ",",
         quote: Character? = CSVDialect.defaultQuote,
         hasHeaderRow: Bool = true,
         pinsHeaderRow: Bool = true,
         trimsFieldWhitespace: Bool = false) {
        self.delimiter = delimiter
        self.quote = quote
        self.hasHeaderRow = hasHeaderRow
        self.pinsHeaderRow = pinsHeaderRow
        self.trimsFieldWhitespace = trimsFieldWhitespace
    }
}

// MARK: - Detection

extension CSVDialect {

    /// Delimiters worth trying when sniffing an unlabelled file.
    static let candidateDelimiters: [Character] = [",", ";", "\t", "|"]

    /// Extensions that declare delimited data outright, with the delimiter the
    /// name implies.
    private static let declaredExtensions: [String: Character] = [
        "csv": ",", "tsv": "\t", "tab": "\t", "psv": "|"
    ]

    private static let sampleByteLimit = 64 * 1024
    private static let sampleLineLimit = 200
    private static let minimumFieldCount = 2

    /// How many sampled rows must agree on a field count before an *unlabelled*
    /// file is called delimited. Prose with stray commas varies row to row and
    /// so falls well short of this.
    private static let requiredAgreement = 0.9

    /// A named extension is evidence in itself, so a file called `.csv` only has
    /// to be broadly consistent to be accepted.
    private static let requiredAgreementWhenDeclared = 0.5

    /// A dialect for `file`, or `nil` when its head sample does not look like
    /// delimited data.
    ///
    /// Returning `nil` is what keeps the CSV selector hidden for ordinary text.
    static func detect(in file: MappedFile) -> CSVDialect? {
        var result: CSVDialect?
        let lines = sampleLines(of: file)
        if !lines.isEmpty {
            let declared = declaredDelimiter(for: file)
            let threshold = declared == nil ? requiredAgreement : requiredAgreementWhenDeclared
            if let best = bestDelimiter(in: lines, preferring: declared),
               best.agreement >= threshold {
                result = CSVDialect(delimiter: best.delimiter,
                                    hasHeaderRow: looksLikeHeaderRow(lines, delimiter: best.delimiter))
            }
        }
        return result
    }

    /// The delimiter implied by the file's extension, if it names one.
    private static func declaredDelimiter(for file: MappedFile) -> Character? {
        let fileExtension = (file.path as NSString).pathExtension.lowercased()
        return declaredExtensions[fileExtension]
    }

    /// The candidate delimiter that splits `lines` most consistently.
    ///
    /// Scored on how large a share of rows share the most common field count,
    /// then on that count, so a file that is consistent under both `,` and `;`
    /// picks the one that actually yields columns. A delimiter named by the
    /// extension wins any exact tie.
    private static func bestDelimiter(in lines: [String], preferring declared: Character?)
        -> (delimiter: Character, agreement: Double, fieldCount: Int)? {
        var best: (delimiter: Character, agreement: Double, fieldCount: Int)?
        var candidates = candidateDelimiters
        if let declared, let existing = candidates.firstIndex(of: declared) {
            candidates.remove(at: existing)
            candidates.insert(declared, at: 0)
        }
        for delimiter in candidates {
            let probe = CSVDialect(delimiter: delimiter)
            let counts = lines.map { CSVParser.fields(in: $0, dialect: probe).count }
            if let mode = modalValue(of: counts), mode.value >= minimumFieldCount {
                let agreement = Double(mode.occurrences) / Double(counts.count)
                let better = best.map {
                    (agreement, mode.value) > ($0.agreement, $0.fieldCount)
                } ?? true
                if better {
                    best = (delimiter, agreement, mode.value)
                }
            }
        }
        return best
    }

    /// The most frequent value in `values`, and how often it occurs.
    private static func modalValue(of values: [Int]) -> (value: Int, occurrences: Int)? {
        var occurrences: [Int: Int] = [:]
        for value in values {
            occurrences[value, default: 0] += 1
        }
        let ranked = occurrences.max { left, right in
            (left.value, left.key) < (right.value, right.key)
        }
        return ranked.map { (value: $0.key, occurrences: $0.value) }
    }

    /// Whether row one reads like column names: no field in it parses as a
    /// number, while some later row has one. A file that is numeric throughout,
    /// or textual throughout, is left with the default answer.
    private static func looksLikeHeaderRow(_ lines: [String], delimiter: Character) -> Bool {
        var result = true
        let dialect = CSVDialect(delimiter: delimiter)
        if let first = lines.first {
            let headerFields = CSVParser.fields(in: first, dialect: dialect)
            let headerIsTextual = headerFields.allSatisfy { Double($0) == nil }
            let bodyHasNumber = lines.dropFirst().contains { line in
                CSVParser.fields(in: line, dialect: dialect).contains { Double($0) != nil }
            }
            result = headerIsTextual && bodyHasNumber
        }
        return result
    }

    /// Whole lines from the head of `file`, with any trailing partial line
    /// dropped so a row cut by the sample limit cannot skew the field counts.
    private static func sampleLines(of file: MappedFile) -> [String] {
        let buffer = file.buffer
        let count = min(buffer.count, sampleByteLimit)
        var bytes = Array(UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
        if count < buffer.count, let lastNewline = bytes.lastIndex(of: 0x0A) {
            bytes = Array(bytes[0..<lastNewline])
        }
        let text = String(decoding: bytes, as: UTF8.self)

        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if lines.count >= sampleLineLimit {
                break
            }
            let withoutReturn = line.hasSuffix("\r") ? line.dropLast() : line
            if !withoutReturn.isEmpty {
                lines.append(String(withoutReturn))
            }
        }
        return lines
    }
}
