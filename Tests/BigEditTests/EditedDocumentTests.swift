import XCTest
@testable import BigEdit

/// `EditedDocument.replace` is the single mutation entry point behind typing,
/// deletion, and paste. These tests drive it the way the viewport does and
/// check that content, layout, and the saved file all stay consistent.
final class EditedDocumentTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func makeDocument(_ content: String) -> EditedDocument {
        let url = TestHelpers.writeTempFile(content)
        temporaryFiles.append(url)
        guard let file = MappedFile(path: url.path) else {
            fatalError("could not map temp file")
        }
        let index = LineIndex()
        index.buildSynchronously(from: file)
        return EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
    }

    private func text(of document: EditedDocument) -> String {
        String(decoding: document.bytes(in: 0..<document.length), as: UTF8.self)
    }

    func testTypingStyleEdits() {
        let document = makeDocument("hello world\nsecond line\n")

        document.replace(5..<5, with: Array(",".utf8))            // type into line 1
        document.replace(7..<12, with: Array("EARTH".utf8))       // replace "world"
        XCTAssertEqual(text(of: document), "hello, EARTH\nsecond line\n")

        // Layout answers must match the edited content.
        XCTAssertEqual(document.layout.documentLineCount, 2)
        XCTAssertEqual(document.layout.length, document.length)
        XCTAssertEqual(document.layout.visualRow(forDocumentLine: 1), 1)
    }

    func testNewlineInsertionAndJoin() {
        let document = makeDocument("alpha beta\n")

        document.replace(5..<6, with: [0x0A])                     // split the line
        XCTAssertEqual(text(of: document), "alpha\nbeta\n")
        XCTAssertEqual(document.layout.documentLineCount, 2)

        document.replace(5..<6, with: Array(" ".utf8))            // join again
        XCTAssertEqual(text(of: document), "alpha beta\n")
        XCTAssertEqual(document.layout.documentLineCount, 1)
    }

    func testCharacterSteppingThroughEditedText() {
        let document = makeDocument("ab")
        document.replace(1..<1, with: Array("€".utf8))            // 3-byte character

        XCTAssertEqual(text(of: document), "a€b")
        XCTAssertEqual(document.nextCharacterOffset(after: 1), 4)
        XCTAssertEqual(document.previousCharacterOffset(before: 4), 1)
    }

    func testEditThenSaveRoundTrip() {
        let document = makeDocument("one\ntwo\nthree\n")
        document.replace(4..<7, with: Array("2".utf8))
        document.replace(0..<0, with: Array("start: ".utf8))

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigEditTestOut-\(UUID().uuidString)")
        temporaryFiles.append(outputURL)
        let result = FileWriter.saveSynchronously(document: document, to: outputURL)

        switch result {
        case .success:
            let written = try? String(contentsOf: outputURL, encoding: .utf8)
            XCTAssertEqual(written, "start: one\n2\nthree\n")
        case .failure(let error):
            XCTFail("Save failed: \(error.localizedDescription)")
        }
    }

    /// Random edits through the document must keep the piece table, the
    /// layout, and a naive byte model in exact agreement.
    func testFuzzKeepsContentAndLayoutInAgreement() {
        for seed: UInt64 in [31, 3131] {
            var generator = SeededGenerator(seed: seed)
            var model = (0..<800).map { _ in
                Int.random(in: 0..<12, using: &generator) == 0
                    ? UInt8(0x0A)
                    : UInt8.random(in: 32...126, using: &generator)
            }
            let document = makeDocument(String(decoding: model, as: UTF8.self))

            for step in 0..<80 {
                let lower = Int.random(in: 0...model.count, using: &generator)
                let upper = Int.random(in: lower...min(model.count, lower + 60), using: &generator)
                let insert = (0..<Int.random(in: 0...30, using: &generator)).map { _ in
                    Int.random(in: 0..<10, using: &generator) == 0
                        ? UInt8(0x0A)
                        : UInt8.random(in: 32...126, using: &generator)
                }
                document.replace(lower..<upper, with: insert)
                model.replaceSubrange(lower..<upper, with: insert)

                let context = "seed \(seed) step \(step)"
                XCTAssertEqual(document.length, model.count, context)
                XCTAssertEqual(document.bytes(in: 0..<document.length), model, context)
                XCTAssertEqual(document.layout.length, model.count, context)

                let expectedLines = model.split(separator: 0x0A, omittingEmptySubsequences: false)
                var lineCount = expectedLines.count
                if model.last == 0x0A || model.isEmpty {
                    lineCount -= 1   // a trailing newline does not start a line
                }
                XCTAssertEqual(document.layout.documentLineCount, lineCount, context)
            }
        }
    }
}
