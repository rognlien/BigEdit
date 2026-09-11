import XCTest
@testable import BigEdit

/// A click on an aligned cell must land on the byte it shows, and a byte
/// must draw where its cell is — through padding, quotes and multi-byte
/// characters.
final class CSVRowMapTests: XCTestCase {

    private let dialect = CSVDialect()

    private func map(_ line: String, widths: [Int], encoding: TextEncoding = .utf8) -> CSVRowMap {
        CSVRowMap(lineBytes: Array(line.utf8), dialect: dialect,
                  layout: CSVColumnLayout(columnWidths: widths), encoding: encoding)
    }

    func testCellsCarryByteAndDisplayRanges() {
        let map = map("ab,cde", widths: [4, 3])

        XCTAssertEqual(map.cells, [
            CSVRowMap.Cell(byteRange: 0..<2, valueStart: 0, valueEnd: 2, displayRange: 0..<4),
            CSVRowMap.Cell(byteRange: 3..<6, valueStart: 3, valueEnd: 6, displayRange: 6..<9)
        ])
    }

    func testBytesMapIntoTheirPaddedCells() {
        let map = map("ab,cde", widths: [4, 3])

        XCTAssertEqual(map.displayColumn(forByte: 0), 0)
        XCTAssertEqual(map.displayColumn(forByte: 2), 2, "end of the first value")
        XCTAssertEqual(map.displayColumn(forByte: 3), 6, "start of the second cell")
        XCTAssertEqual(map.displayColumn(forByte: 5), 8)
        XCTAssertEqual(map.displayColumn(forByte: 6), 9, "end of the line")
    }

    func testDisplayColumnsMapBackToBytes() {
        let map = map("ab,cde", widths: [4, 3])

        XCTAssertEqual(map.byteOffset(forDisplayColumn: 1), 1)
        XCTAssertEqual(map.byteOffset(forDisplayColumn: 3), 2, "padding lands at the value's end")
        XCTAssertEqual(map.byteOffset(forDisplayColumn: 5), 2, "so does the gap")
        XCTAssertEqual(map.byteOffset(forDisplayColumn: 7), 4)
        XCTAssertEqual(map.byteOffset(forDisplayColumn: 12), 6, "past the last cell is the line end")
    }

    func testQuotesAreSkippedSoTheShownValueLinesUp() {
        let map = map("\"a,b\",c", widths: [3, 1])

        XCTAssertEqual(map.cells[0].valueStart, 1)
        XCTAssertEqual(map.cells[0].valueEnd, 4, "inside the closing quote")
        XCTAssertEqual(map.displayColumn(forByte: 1), 0, "first shown character")
        XCTAssertEqual(map.displayColumn(forByte: 3), 2)
        XCTAssertEqual(map.byteOffset(forDisplayColumn: 2), 3)
    }

    func testMultiByteCharactersCountAsOneColumn() {
        let map = map("æøå,x", widths: [3, 1])

        XCTAssertEqual(map.displayColumn(forByte: 2), 1, "after æ")
        XCTAssertEqual(map.displayColumn(forByte: 6), 3)
        XCTAssertEqual(map.byteOffset(forDisplayColumn: 2), 4, "before å")
    }

    func testSingleByteEncodingCountsEveryByte() {
        let bytes: [UInt8] = [0xE6, 0xF8, 0x2C, 0x78]     // "æø,x" in Windows-1252
        let map = CSVRowMap(lineBytes: bytes, dialect: dialect,
                            layout: CSVColumnLayout(columnWidths: [2, 1]), encoding: .windows1252)

        XCTAssertEqual(map.displayColumn(forByte: 1), 1)
        XCTAssertEqual(map.byteOffset(forDisplayColumn: 4), 3)
    }

    func testExtraFieldsBeyondTheLayoutKeepTheirNaturalWidth() {
        let map = map("a,b,ccc", widths: [1, 1])

        XCTAssertEqual(map.cells[2].displayRange, 6..<9)
    }
}
