import Foundation

/// Maps between a delimited line's bytes and the characters of its aligned
/// rendering, so a click on a padded cell lands on the byte it shows and a
/// selection or search highlight is drawn where those bytes are drawn.
///
/// Each cell knows the raw field's byte range in the line and the character
/// range the layout gives it. Inside a cell, characters count from the
/// field's value — after an opening quote and, when the dialect trims,
/// leading spaces — so the mapping follows what `CSVParser` shows.
struct CSVRowMap {

    struct Cell: Equatable {
        /// The raw field's bytes within the line, delimiters excluded.
        let byteRange: Range<Int>
        /// The field's shown value within `byteRange`: inside the quotes of a
        /// quoted field, and inside the spaces of a trimmed one.
        let valueStart: Int
        let valueEnd: Int
        /// The cell's characters within the aligned row.
        let displayRange: Range<Int>
    }

    let cells: [Cell]
    private let bytes: [UInt8]

    /// The line's length in bytes, without its ending.
    var lineLength: Int { bytes.count }
    private let isSingleByte: Bool

    /// Builds the map for one line of `bytes` (no line ending) under
    /// `dialect`, aligned by `layout` in `encoding`.
    init(lineBytes: [UInt8], dialect: CSVDialect, layout: CSVColumnLayout, encoding: TextEncoding) {
        bytes = lineBytes
        isSingleByte = encoding.isSingleByte
        let ranges = CSVParser.fieldByteRanges(in: lineBytes, dialect: dialect, encoding: encoding)
        var cells: [Cell] = []
        var displayCursor = 0
        for (column, range) in ranges.enumerated() {
            let valueStart = CSVRowMap.valueStart(in: lineBytes, field: range, dialect: dialect,
                                                  encoding: encoding)
            let valueEnd = CSVRowMap.valueEnd(in: lineBytes, field: range, valueStart: valueStart,
                                              dialect: dialect, encoding: encoding)
            let characters = CSVRowMap.characterCount(of: lineBytes[valueStart..<valueEnd],
                                                      isSingleByte: encoding.isSingleByte)
            let width = column < layout.columnWidths.count ? layout.columnWidths[column] : characters
            cells.append(Cell(byteRange: range, valueStart: valueStart, valueEnd: valueEnd,
                              displayRange: displayCursor..<(displayCursor + width)))
            displayCursor += width + CSVColumnLayout.columnGap
        }
        self.cells = cells
    }

    /// The index of the cell drawn at character `column`, or nil before the
    /// first one.
    func cellIndex(forDisplayColumn column: Int) -> Int? {
        cells.lastIndex { $0.displayRange.lowerBound <= column }
    }

    /// The index of the cell holding the byte at `offset` (line-relative).
    func cellIndex(forByte offset: Int) -> Int? {
        cells.lastIndex { $0.byteRange.lowerBound <= offset }
    }

    /// The character column at which the byte at `offset` (line-relative)
    /// is drawn. A byte before a cell's value, or a delimiter, maps to the
    /// cell's edge.
    func displayColumn(forByte offset: Int) -> Int {
        var column = 0
        if let cell = cells.last(where: { $0.byteRange.lowerBound <= offset }) {
            let inValue = min(max(offset, cell.valueStart), cell.byteRange.upperBound)
            let characters = CSVRowMap.characterCount(of: bytes[cell.valueStart..<inValue],
                                                      isSingleByte: isSingleByte)
            column = cell.displayRange.lowerBound + min(characters, cell.displayRange.count)
            if offset > cell.byteRange.upperBound {
                column = cell.displayRange.upperBound      // on the delimiter or beyond
            }
        }
        return column
    }

    /// The line-relative byte offset shown at character `column`. A column in
    /// the gap after a cell maps to the end of that cell's value; one past
    /// the last cell maps to the end of the line.
    func byteOffset(forDisplayColumn column: Int) -> Int {
        var offset = 0
        if let cell = cells.last(where: { $0.displayRange.lowerBound <= column }) {
            let characters = min(max(0, column - cell.displayRange.lowerBound), cell.displayRange.count)
            offset = CSVRowMap.byteOffset(afterCharacters: characters, in: bytes, from: cell.valueStart,
                                          to: cell.byteRange.upperBound, isSingleByte: isSingleByte)
            if column >= cell.displayRange.upperBound && cell == cells.last {
                offset = bytes.count
            }
        }
        return offset
    }

    private static func valueStart(in bytes: [UInt8], field: Range<Int>, dialect: CSVDialect,
                                   encoding: TextEncoding) -> Int {
        var start = field.lowerBound
        if dialect.trimsFieldWhitespace {
            while start < field.upperBound && (bytes[start] == 0x20 || bytes[start] == 0x09) {
                start += 1
            }
        }
        if let quote = dialect.quote, let quoteBytes = encoding.encode(String(quote)),
           start < field.upperBound, quoteBytes.count == 1, bytes[start] == quoteBytes[0] {
            start += 1
        }
        return start
    }

    private static func valueEnd(in bytes: [UInt8], field: Range<Int>, valueStart: Int,
                                 dialect: CSVDialect, encoding: TextEncoding) -> Int {
        var end = field.upperBound
        if dialect.trimsFieldWhitespace {
            while end > valueStart && (bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09) {
                end -= 1
            }
        }
        let isQuoted = valueStart > field.lowerBound && !(dialect.trimsFieldWhitespace
            && (bytes[valueStart - 1] == 0x20 || bytes[valueStart - 1] == 0x09))
        if isQuoted, let quote = dialect.quote, let quoteBytes = encoding.encode(String(quote)),
           quoteBytes.count == 1, end > valueStart, bytes[end - 1] == quoteBytes[0] {
            end -= 1
        }
        return end
    }

    /// Characters in `slice`: every byte in a single-byte encoding, every
    /// scalar start in UTF-8.
    private static func characterCount(of slice: ArraySlice<UInt8>, isSingleByte: Bool) -> Int {
        isSingleByte ? slice.count : slice.filter { ($0 & 0xC0) != 0x80 }.count
    }

    private static func byteOffset(afterCharacters count: Int, in bytes: [UInt8], from start: Int,
                                   to end: Int, isSingleByte: Bool) -> Int {
        var offset = start
        var seen = 0
        while offset < end {
            let isCharacterStart = isSingleByte || (bytes[offset] & 0xC0) != 0x80
            if isCharacterStart {
                if seen == count {
                    break
                }
                seen += 1
            }
            offset += 1
        }
        return offset
    }
}
