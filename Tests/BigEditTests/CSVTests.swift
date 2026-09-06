import XCTest
@testable import BigEdit

/// Detection decides whether the CSV selector appears at all, and the parser
/// and column layout decide what the aligned table looks like, so both are
/// worth pinning down precisely.
final class CSVTests: XCTestCase {

    // MARK: - Helpers

    /// Detects a dialect for `contents`, written to a file named `name` so the
    /// extension-driven path can be exercised too.
    private func detect(_ contents: String, named name: String = "sample.txt") -> CSVDialect? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigEditTest-\(UUID().uuidString)-\(name)")
        try? Data(contents.utf8).write(to: url)
        defer { TestHelpers.remove(url) }
        guard let file = MappedFile(path: url.path) else { return nil }
        return CSVDialect.detect(in: file)
    }

    private func columnLayout(_ contents: String, dialect: CSVDialect) -> CSVColumnLayout? {
        let url = TestHelpers.writeTempFile(contents)
        defer { TestHelpers.remove(url) }
        guard let file = MappedFile(path: url.path) else { return nil }
        return CSVColumnLayout.measure(file: file, dialect: dialect)
    }

    // MARK: - Field splitting

    func testSplitsPlainFields() {
        let fields = CSVParser.fields(in: "a,b,c", dialect: CSVDialect())
        XCTAssertEqual(fields, ["a", "b", "c"])
    }

    func testQuotedFieldKeepsItsDelimiter() {
        let fields = CSVParser.fields(in: "1,\"Smith, John\",Oslo", dialect: CSVDialect())
        XCTAssertEqual(fields, ["1", "Smith, John", "Oslo"])
    }

    func testDoubledQuoteIsALiteralQuote() {
        let fields = CSVParser.fields(in: "a,\"say \"\"hi\"\"\",b", dialect: CSVDialect())
        XCTAssertEqual(fields, ["a", "say \"hi\"", "b"])
    }

    func testStrayQuoteInsideAFieldIsLiteral() {
        // Every standard reader treats a quote that is not at the field's start
        // as an ordinary character, rather than as an opening quote.
        let fields = CSVParser.fields(in: "ab\"cd", dialect: CSVDialect())
        XCTAssertEqual(fields, ["ab\"cd"])
    }

    func testTextAfterAClosingQuoteIsKept() {
        XCTAssertEqual(CSVParser.fields(in: "\"ab\"cd", dialect: CSVDialect()), ["abcd"])
    }

    func testLeadingSpaceStopsAFieldBeingQuoted() {
        XCTAssertEqual(CSVParser.fields(in: " \"ab\"", dialect: CSVDialect()), [" \"ab\""])
    }

    func testEmptyFieldsArePreserved() {
        let fields = CSVParser.fields(in: "a,,c,", dialect: CSVDialect())
        XCTAssertEqual(fields, ["a", "", "c", ""])
    }

    func testEmptyLineIsOneEmptyField() {
        XCTAssertEqual(CSVParser.fields(in: "", dialect: CSVDialect()), [""])
    }

    func testTrimOptionIgnoresSurroundingSpaces() {
        var dialect = CSVDialect()
        dialect.trimsFieldWhitespace = true
        XCTAssertEqual(CSVParser.fields(in: " a , b ", dialect: dialect), ["a", "b"])
    }

    func testTrimIsOffByDefault() {
        XCTAssertEqual(CSVParser.fields(in: " a , b ", dialect: CSVDialect()), [" a ", " b "])
    }

    func testQuoteCharacterCanBeDisabled() {
        var dialect = CSVDialect()
        dialect.quote = nil
        XCTAssertEqual(CSVParser.fields(in: "a,\"b,c\"", dialect: dialect), ["a", "\"b", "c\""])
    }

    func testAlternateDelimiter() {
        var dialect = CSVDialect()
        dialect.delimiter = ";"
        XCTAssertEqual(CSVParser.fields(in: "a;b;c", dialect: dialect), ["a", "b", "c"])
    }

    // MARK: - Detection

    func testDetectsCommaSeparatedData() {
        let dialect = detect("id,name,city\n1,Ada,London\n2,Alan,Oslo\n")
        XCTAssertEqual(dialect?.delimiter, ",")
    }

    func testDetectsSemicolonSeparatedData() {
        let dialect = detect("id;name;city\n1;Ada;London\n2;Alan;Oslo\n")
        XCTAssertEqual(dialect?.delimiter, ";")
    }

    func testDetectsTabSeparatedData() {
        let dialect = detect("id\tname\n1\tAda\n2\tAlan\n")
        XCTAssertEqual(dialect?.delimiter, "\t")
    }

    func testProseIsNotDelimitedData() {
        let prose = """
            The quick brown fox, they said, jumped.
            It was a fine day.
            Later, much later, the dog woke up, yawned, and stretched.
            Nothing else happened.
            """
        XCTAssertNil(detect(prose))
    }

    func testJSONIsNotDelimitedData() {
        let json = """
            {"id": 1, "name": "Ada"}
            {"id": 2}
            {"id": 3, "name": "Alan", "city": "Oslo"}
            """
        XCTAssertNil(detect(json))
    }

    func testEmptyFileIsNotDelimitedData() {
        XCTAssertNil(detect(""))
    }

    func testCSVExtensionAcceptsLessConsistentData() {
        // Ragged rows that would fail the unlabelled threshold, in a file whose
        // name declares the format.
        let ragged = "a,b\nc,d\ne\nf,g\nh,i,j\n"
        XCTAssertNil(detect(ragged))
        XCTAssertEqual(detect(ragged, named: "data.csv")?.delimiter, ",")
    }

    func testQuotedDelimitersDoNotBreakDetection() {
        let dialect = detect("id,name\n1,\"Smith, John\"\n2,\"Doe, Jane\"\n3,\"Roe, Rita\"\n")
        XCTAssertEqual(dialect?.delimiter, ",")
    }

    func testHeaderIsDetectedWhenFirstRowIsTextual() {
        let dialect = detect("id,name,amount\n1,Ada,1250\n2,Alan,980\n")
        XCTAssertEqual(dialect?.hasHeaderRow, true)
    }

    func testNoHeaderWhenFirstRowIsNumericToo() {
        let dialect = detect("1,Ada,1250\n2,Alan,980\n3,Grace,700\n")
        XCTAssertEqual(dialect?.hasHeaderRow, false)
    }

    // MARK: - Column layout

    func testColumnWidthsAreTheWidestSampledField() {
        let layout = columnLayout("id,name\n1,Ada Lovelace\n2,Alan\n", dialect: CSVDialect())
        XCTAssertEqual(layout?.columnWidths, [2, 12])
    }

    func testAlignedRowPadsToColumnWidths() {
        let layout = CSVColumnLayout(columnWidths: [3, 6])
        let row = layout.alignedRow(["1", "Ada"])
        XCTAssertEqual(row, "1    Ada   ")
    }

    func testAlignedRowTruncatesAnOverlongField() {
        let layout = CSVColumnLayout(columnWidths: [4])
        XCTAssertEqual(layout.alignedRow(["abcdefgh"]), "abc…")
    }

    func testAlignedRowKeepsExtraFieldsBeyondTheMeasuredColumns() {
        let layout = CSVColumnLayout(columnWidths: [2])
        XCTAssertEqual(layout.alignedRow(["ab", "extra"]), "ab  extra")
    }

    func testColumnWidthIsCapped() {
        let wide = String(repeating: "x", count: 200)
        let layout = columnLayout("a\n\(wide)\n", dialect: CSVDialect())
        XCTAssertEqual(layout?.columnWidths, [CSVColumnLayout.maximumColumnWidth])
    }

    func testRowsAlignIntoAGrid() {
        let contents = "id,name,city\n1,Ada Lovelace,London\n2,Alan,Oslo\n"
        guard let layout = columnLayout(contents, dialect: CSVDialect()) else {
            return XCTFail("no layout")
        }
        let rows = contents.split(separator: "\n").map {
            layout.alignedRow(CSVParser.fields(in: String($0), dialect: CSVDialect()))
        }
        // Every row is the same width, which is what makes the columns line up.
        XCTAssertEqual(Set(rows.map(\.count)).count, 1)
        XCTAssertTrue(rows[1].hasPrefix("1   Ada Lovelace  London"))
    }
}
