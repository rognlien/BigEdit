import XCTest
@testable import BigEdit

/// The results list builds each row from a match on demand: the right line
/// number, a snippet cut around the match without splitting a character, and
/// the match's position inside that snippet.
final class SearchResultsPanelTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func document(_ bytes: [UInt8]) -> EditedDocument {
        let url = TestHelpers.writeTempFile(Data(bytes))
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        return EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
    }

    private func document(_ text: String) -> EditedDocument {
        document(Array(text.utf8))
    }

    private func matches(_ query: String, in document: EditedDocument) -> [Range<Int>] {
        let scan = SearchScan(query: query)!
        scan.runSynchronously(in: document)
        return scan.matches(beginningIn: 0..<Int.max)
    }

    // MARK: - Rows

    func testRowHasTheLineNumberAndTheMatchPosition() {
        let doc = document("alpha\nbeta needle gamma\nend\n")
        let match = matches("needle", in: doc)[0]
        let row = SearchResultRow.make(match: match, in: doc, encoding: .utf8)!
        XCTAssertEqual(row.lineNumber, 2)
        XCTAssertEqual(row.text, "beta needle gamma")
        XCTAssertEqual(row.matchRange, NSRange(location: 5, length: 6))
    }

    func testALongLineIsCutAroundTheMatchWithEllipses() {
        let text = String(repeating: "x", count: 500) + "needle" + String(repeating: "y", count: 500) + "\n"
        let doc = document(text)
        let match = matches("needle", in: doc)[0]
        let row = SearchResultRow.make(match: match, in: doc, encoding: .utf8)!
        XCTAssertTrue(row.text.hasPrefix("…"))
        XCTAssertTrue(row.text.hasSuffix("…"))
        XCTAssertEqual((row.text as NSString).substring(with: row.matchRange), "needle")
        XCTAssertLessThan(row.text.count, 400)
    }

    func testTheCutNeverSplitsAMultiByteCharacter() {
        // Eighty-odd bytes of two-byte characters before the match, so the
        // cut lands inside one unless it is moved to a boundary.
        let text = String(repeating: "ø", count: 60) + "needle\n"
        let doc = document(text)
        let match = matches("needle", in: doc)[0]
        let row = SearchResultRow.make(match: match, in: doc, encoding: .utf8)!
        XCTAssertFalse(row.text.contains("\u{FFFD}"), "no replacement character means no torn ø")
        XCTAssertEqual((row.text as NSString).substring(with: row.matchRange), "needle")
    }

    func testAMatchAcrossLinesShowsALineBreakSymbol() {
        let doc = document("one\ntwo\n")
        let scan = SearchScan(regularExpression: "one\\ntwo")!
        scan.runSynchronously(in: doc)
        let match = scan.matches(beginningIn: 0..<Int.max)[0]
        let row = SearchResultRow.make(match: match, in: doc, encoding: .utf8)!
        XCTAssertEqual(row.lineNumber, 1)
        XCTAssertFalse(row.text.contains("\n"))
        XCTAssertTrue(row.text.contains("⏎"))
    }

    func testAWindows1252LineDecodesInItsEncoding() {
        var bytes: [UInt8] = Array("bl".utf8)
        bytes.append(0xE5)                              // å
        bytes.append(contentsOf: Array("b".utf8))
        bytes.append(0xE6)                              // æ
        bytes.append(contentsOf: Array("r needle\n".utf8))
        let doc = document(bytes)
        let scan = SearchScan(query: "needle", encoding: .windows1252)!
        scan.runSynchronously(in: doc)
        let match = scan.matches(beginningIn: 0..<Int.max)[0]
        let row = SearchResultRow.make(match: match, in: doc, encoding: .windows1252)!
        XCTAssertEqual(row.text, "blåbær needle")
        XCTAssertEqual((row.text as NSString).substring(with: row.matchRange), "needle")
    }

    func testEditedDocumentRowsFollowTheEdits() {
        let doc = document("first\nsecond\n")
        doc.replace(0..<0, with: Array("needle here\n".utf8))
        let match = matches("needle", in: doc)[0]
        let row = SearchResultRow.make(match: match, in: doc, encoding: .utf8)!
        XCTAssertEqual(row.lineNumber, 1)
        XCTAssertEqual(row.text, "needle here")
    }

    // MARK: - The panel

    func testPanelListsRowsFromTheProviderAndCapsThem() {
        let panel = SearchResultsPanel(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        panel.rowProvider = { index in
            SearchResultRow(lineNumber: index + 1, text: "row \(index)", matchRange: NSRange(location: 0, length: 3))
        }
        panel.update(matchCount: 3, isComplete: true, isTruncated: false)
        XCTAssertEqual(panel.listedRowCount, 3)
        panel.update(matchCount: SearchResultsPanel.rowLimit + 50, isComplete: true, isTruncated: false)
        XCTAssertEqual(panel.listedRowCount, SearchResultsPanel.rowLimit)
    }

    func testProgrammaticSelectionDoesNotReportAChoice() {
        let panel = SearchResultsPanel(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        panel.rowProvider = { _ in SearchResultRow(lineNumber: 1, text: "x", matchRange: NSRange(location: 0, length: 1)) }
        var reported: [Int] = []
        panel.onSelect = { reported.append($0) }
        panel.update(matchCount: 5, isComplete: true, isTruncated: false)
        panel.select(index: 2)
        XCTAssertTrue(reported.isEmpty, "keeping the list in step with ⌘G must not loop back")
    }
}
