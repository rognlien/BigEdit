import Foundation

/// Character widths for a delimited file's columns, measured once from a
/// bounded sample.
///
/// Measuring a sample rather than the visible rows is deliberate: widths taken
/// from whatever happens to be on screen would shift every time you scroll, so
/// the table would never sit still. The cost stays bounded by the sample, not
/// by the file — a 50 GB CSV is measured from the same head slice as a 50 KB
/// one.
struct CSVColumnLayout: Equatable {

    /// Width of each column in characters, in column order.
    let columnWidths: [Int]

    /// Blank characters drawn between one column and the next.
    static let columnGap = 2

    /// A column wider than this is truncated with an ellipsis, so one runaway
    /// field cannot push every later column off the screen. This caps the
    /// *measured* width only — dragging a column wider is always allowed.
    static let maximumColumnWidth = 40

    private static let sampleByteLimit = 1024 * 1024
    private static let sampleRowLimit = 2000

    /// Column widths for `file` under `dialect`, measured from its head.
    static func measure(file: MappedFile, dialect: CSVDialect) -> CSVColumnLayout {
        var widths: [Int] = []
        for line in sampleLines(of: file) {
            let fields = CSVParser.fields(in: line, dialect: dialect)
            for (column, field) in fields.enumerated() {
                let width = min(field.count, maximumColumnWidth)
                if column < widths.count {
                    widths[column] = max(widths[column], width)
                } else {
                    widths.append(width)
                }
            }
        }
        return CSVColumnLayout(columnWidths: widths)
    }

    /// The character offset of each column's trailing edge — where its divider
    /// is drawn and grabbed. One per column, so the last column resizes too.
    var dividerCharacterOffsets: [Int] {
        var offsets: [Int] = []
        var cursor = 0
        for width in columnWidths {
            cursor += width
            offsets.append(cursor)
            cursor += CSVColumnLayout.columnGap
        }
        return offsets
    }

    /// A copy with `column` set to `width`, never narrower than one character.
    /// A column beyond the measured ones is ignored, since it has no divider.
    func settingWidth(_ width: Int, forColumn column: Int) -> CSVColumnLayout {
        var widths = columnWidths
        if column >= 0 && column < widths.count {
            widths[column] = max(1, width)
        }
        return CSVColumnLayout(columnWidths: widths)
    }

    /// `fields` padded into columns, as one line of monospaced text.
    ///
    /// A row with more fields than the measured layout keeps its extra fields
    /// at their natural width rather than dropping them.
    func alignedRow(_ fields: [String]) -> String {
        var result = ""
        for (column, field) in fields.enumerated() {
            let width = column < columnWidths.count ? columnWidths[column] : field.count
            result += CSVColumnLayout.fit(field, to: width)
            if column < fields.count - 1 {
                result += String(repeating: " ", count: CSVColumnLayout.columnGap)
            }
        }
        return result
    }

    /// `field` padded with spaces to `width`, or truncated with an ellipsis
    /// when it overflows.
    private static func fit(_ field: String, to width: Int) -> String {
        var result = field
        if field.count > width {
            result = width > 1 ? String(field.prefix(width - 1)) + "…" : String(field.prefix(width))
        } else if field.count < width {
            result = field + String(repeating: " ", count: width - field.count)
        }
        return result
    }

    /// Whole lines from the head of `file`, with any trailing partial line
    /// dropped so a cut row cannot understate a column's width.
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
            if lines.count >= sampleRowLimit {
                break
            }
            let withoutReturn = line.hasSuffix("\r") ? line.dropLast() : line
            lines.append(String(withoutReturn))
        }
        return lines
    }
}
