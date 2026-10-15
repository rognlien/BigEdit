import XCTest
@testable import BigEdit

/// The streaming regex replace must produce what replacing over the whole
/// text at once would, whatever the window boundaries, and count what it
/// replaced.
final class RegexReplaceWriterTests: XCTestCase {

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

    private func document(_ content: String) -> EditedDocument {
        document(Array(content.utf8))
    }

    private func replaced(_ content: String, pattern: String, template: String,
                          options: NSRegularExpression.Options = [.anchorsMatchLines],
                          windowSize: Int = FileWriter.lineFilterWindow) throws -> (text: String, count: Int) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigEditRegexOut-\(UUID().uuidString)")
        temporaryFiles.append(destination)
        let rule = try XCTUnwrap(RegexReplacementRule(pattern: pattern, template: template, options: options))
        let result = FileWriter.saveSynchronously(document: document(content), regexRule: rule,
                                                  to: destination, windowSize: windowSize)
        switch result {
        case .success(let count):
            return (try String(contentsOf: destination, encoding: .utf8), count)
        case .failure(let error):
            throw error
        }
    }

    func testReplacesWithGroupsAndCounts() throws {
        let result = try replaced("id 42\nid 7\nnone\n", pattern: "id (\\d+)", template: "#$1")
        XCTAssertEqual(result.text, "#42\n#7\nnone\n")
        XCTAssertEqual(result.count, 2)
    }

    func testAgreesWithWholeTextReplacementAcrossWindowSizes() throws {
        let lines = (0..<400).map { "row \($0): value=\($0 * 3)" }
        let content = lines.joined(separator: "\n") + "\n"
        let expression = try NSRegularExpression(pattern: "value=(\\d)(\\d*)", options: [.anchorsMatchLines])
        let expected = expression.stringByReplacingMatches(
            in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "v$2$1")
        for windowSize in [1, 13, 100, 10_000] {
            let result = try replaced(content, pattern: "value=(\\d)(\\d*)", template: "v$2$1",
                                      windowSize: windowSize)
            XCTAssertEqual(result.text, expected, "window \(windowSize)")
            XCTAssertEqual(result.count, 400)
        }
    }

    func testAnchorsMatchAtLineBoundariesInEveryWindow() throws {
        let content = "a\nb\na\n"
        let result = try replaced(content, pattern: "^a$", template: "A", windowSize: 2)
        XCTAssertEqual(result.text, "A\nb\nA\n")
    }

    func testCRLFSurvives() throws {
        let result = try replaced("x1\r\nx2\r\n", pattern: "x", template: "y")
        XCTAssertEqual(result.text, "y1\r\ny2\r\n")
    }

    func testALineThatIsNotUTF8IsCopiedThrough() throws {
        let bytes: [UInt8] = Array("ok a\n".utf8) + [0x62, 0x61, 0x64, 0x20, 0xFF, 0x61, 0x0A] + Array("ok a\n".utf8)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigEditRegexOut-\(UUID().uuidString)")
        temporaryFiles.append(destination)
        let rule = try XCTUnwrap(RegexReplacementRule(pattern: "a", template: "Z"))
        let result = FileWriter.saveSynchronously(document: document(bytes), regexRule: rule, to: destination)
        guard case .success(let count) = result else {
            return XCTFail("save failed")
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(Array(try Data(contentsOf: destination)),
                       Array("ok Z\n".utf8) + [0x62, 0x61, 0x64, 0x20, 0xFF, 0x61, 0x0A] + Array("ok Z\n".utf8))
    }

    func testDotMatchesNewlineSpansLinesWithinAWindow() throws {
        let result = try replaced("start\nmiddle\nend\n", pattern: "start.*end", template: "X",
                                  options: [.anchorsMatchLines, .dotMatchesLineSeparators])
        XCTAssertEqual(result.text, "X\n")
    }

    func testReadsThroughUnsavedEdits() throws {
        let edited = document("one\ntwo\n")
        edited.replace(0..<3, with: Array("uno".utf8))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigEditRegexOut-\(UUID().uuidString)")
        temporaryFiles.append(destination)
        let rule = try XCTUnwrap(RegexReplacementRule(pattern: "o", template: "0"))
        _ = FileWriter.saveSynchronously(document: edited, regexRule: rule, to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "un0\ntw0\n")
    }

    func testAnInvalidPatternMakesNoRule() {
        XCTAssertNil(RegexReplacementRule(pattern: "(", template: ""))
        XCTAssertNil(RegexReplacementRule(pattern: "", template: ""))
    }
}
