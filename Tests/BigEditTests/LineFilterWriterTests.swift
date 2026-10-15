import XCTest
@testable import BigEdit

/// The streaming line filter must produce exactly what filtering the lines
/// in memory would, whatever the window boundaries, and must leave line
/// terminators as it found them.
final class LineFilterWriterTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func document(_ content: String) -> EditedDocument {
        let url = TestHelpers.writeTempFile(content)
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        return EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
    }

    private func outputURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigEditFilterOut-\(UUID().uuidString)")
        temporaryFiles.append(url)
        return url
    }

    private func filtered(_ content: String, windowSize: Int = FileWriter.lineFilterWindow,
                          keep: (String) -> Bool) throws -> (text: String, kept: Int) {
        let destination = outputURL()
        let result = FileWriter.saveSynchronously(
            document: document(content), keepingLinesWhere: keep, to: destination,
            windowSize: windowSize)
        switch result {
        case .success(let kept):
            let data = try Data(contentsOf: destination)
            return (String(decoding: data, as: UTF8.self), kept)
        case .failure(let error):
            throw error
        }
    }

    func testKeepsOnlyAcceptedLinesWithTheirTerminators() throws {
        let result = try filtered("a\nb\nc\n") { $0 != "b" }
        XCTAssertEqual(result.text, "a\nc\n")
        XCTAssertEqual(result.kept, 2)
    }

    func testPreservesCRLFAndAMissingFinalNewline() throws {
        XCTAssertEqual(try filtered("a\r\nb\r\nc") { $0 != "b" }.text, "a\r\nc")
        XCTAssertEqual(try filtered("a\r\nb\r\nc") { $0 == "c" }.text, "c")
    }

    func testSmallWindowsNeverSplitALine() throws {
        let lines = (0..<500).map { "line number \($0) with some padding" }
        let content = lines.joined(separator: "\n") + "\n"
        let expected = lines.filter { !$0.contains("7") }.map { $0 + "\n" }.joined()
        for windowSize in [1, 7, 64, 1000] {
            let result = try filtered(content, windowSize: windowSize) { !$0.contains("7") }
            XCTAssertEqual(result.text, expected, "window \(windowSize)")
        }
    }

    func testALineLongerThanTheWindowIsReadWhole() throws {
        let long = String(repeating: "x", count: 5000)
        let result = try filtered("\(long)\nshort\n\(long)y\n", windowSize: 16) { $0.hasSuffix("y") }
        XCTAssertEqual(result.text, "\(long)y\n")
    }

    func testEmptyDocumentWritesAnEmptyFile() throws {
        let result = try filtered("") { _ in true }
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.kept, 0)
    }

    func testReadsThroughUnsavedEdits() throws {
        let edited = document("one\ntwo\nthree\n")
        edited.replace(4..<7, with: Array("TWO".utf8))
        let destination = outputURL()
        let result = FileWriter.saveSynchronously(
            document: edited, keepingLinesWhere: { $0 != "one" }, to: destination)
        guard case .success(let kept) = result else {
            return XCTFail("save failed")
        }
        XCTAssertEqual(kept, 2)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "TWO\nthree\n")
    }

    func testCancellationLeavesNoFile() {
        let token = CancelToken()
        token.cancel()
        let destination = outputURL()
        let result = FileWriter.saveSynchronously(
            document: document("a\nb\n"), keepingLinesWhere: { _ in true },
            to: destination, cancelToken: token)
        guard case .failure(let error) = result else {
            return XCTFail("a cancelled save must fail")
        }
        XCTAssertEqual(error.localizedDescription, FileWriter.WriteError.cancelled.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
