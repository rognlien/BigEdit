import XCTest
@testable import BigEdit

final class FileWriterTests: XCTestCase {

    func testRoundTripMatchesSedSemantics() {
        let content = "foo bar foo\nbaz foo\nno match here\nfoofoo\n"
        let inputURL = TestHelpers.writeTempFile(content)
        let outputURL = inputURL.deletingLastPathComponent()
            .appendingPathComponent("BigEditTestOut-\(UUID().uuidString)")
        defer {
            TestHelpers.remove(inputURL)
            TestHelpers.remove(outputURL)
        }
        let file = MappedFile(path: inputURL.path)!
        let rule = ReplacementRule(pattern: "foo", replacement: "XX")!

        let result = FileWriter.saveSynchronously(file: file, rule: rule, to: outputURL)
        switch result {
        case .success:
            let written = try? String(contentsOf: outputURL, encoding: .utf8)
            XCTAssertEqual(written, "XX bar XX\nbaz XX\nno match here\nXXXX\n")
        case .failure(let error):
            XCTFail("Save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Piece-table save

    private func makeDocument(_ content: String, at url: URL) -> EditedDocument {
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        return EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
    }

    /// Applies an edit to the document's piece table the way the editor will:
    /// append the bytes, splice the range.
    private func edit(_ document: EditedDocument, replace range: Range<Int>, with text: String) {
        let addedRange = document.addBuffer.append(Array(text.utf8))
        document.pieceTable.replace(range, withAddedRange: addedRange)
    }

    func testPieceSaveRoundTripsEdits() {
        let inputURL = TestHelpers.writeTempFile("one\ntwo\nthree\n")
        let outputURL = inputURL.deletingLastPathComponent()
            .appendingPathComponent("BigEditTestOut-\(UUID().uuidString)")
        defer {
            TestHelpers.remove(inputURL)
            TestHelpers.remove(outputURL)
        }
        let document = makeDocument("one\ntwo\nthree\n", at: inputURL)
        edit(document, replace: 4..<7, with: "TWO and a half")     // replace "two"
        edit(document, replace: 0..<0, with: "zero\n")             // prepend a line
        let length = document.length
        edit(document, replace: length..<length, with: "tail")     // append

        let result = FileWriter.saveSynchronously(document: document, to: outputURL)
        switch result {
        case .success:
            let written = try? String(contentsOf: outputURL, encoding: .utf8)
            XCTAssertEqual(written, "zero\none\nTWO and a half\nthree\ntail")
        case .failure(let error):
            XCTFail("Save failed: \(error.localizedDescription)")
        }
    }

    func testPieceSaveOfUneditedDocumentIsByteIdentical() {
        let content = "byte-for-byte copy\r\nwith CRLF and no trailing newline"
        let inputURL = TestHelpers.writeTempFile(content)
        let outputURL = inputURL.deletingLastPathComponent()
            .appendingPathComponent("BigEditTestOut-\(UUID().uuidString)")
        defer {
            TestHelpers.remove(inputURL)
            TestHelpers.remove(outputURL)
        }
        let document = makeDocument(content, at: inputURL)

        let result = FileWriter.saveSynchronously(document: document, to: outputURL)
        switch result {
        case .success:
            XCTAssertEqual(try? Data(contentsOf: outputURL), Data(content.utf8))
        case .failure(let error):
            XCTFail("Save failed: \(error.localizedDescription)")
        }
    }

    func testPieceSaveFuzzMatchesModel() {
        for seed: UInt64 in [21, 210] {
            var generator = SeededGenerator(seed: seed)
            var model = (0..<600).map { _ in
                Int.random(in: 0..<12, using: &generator) == 0
                    ? UInt8(0x0A)
                    : UInt8.random(in: 32...126, using: &generator)
            }
            let inputURL = TestHelpers.writeTempFile(Data(model))
            let outputURL = inputURL.deletingLastPathComponent()
                .appendingPathComponent("BigEditTestOut-\(UUID().uuidString)")
            defer {
                TestHelpers.remove(inputURL)
                TestHelpers.remove(outputURL)
            }
            let document = makeDocument("", at: inputURL)

            for _ in 0..<60 {
                let lower = Int.random(in: 0...model.count, using: &generator)
                let upper = Int.random(in: lower...min(model.count, lower + 50), using: &generator)
                let insert = (0..<Int.random(in: 0...30, using: &generator)).map { _ in
                    UInt8.random(in: 32...126, using: &generator)
                }
                let addedRange = document.addBuffer.append(insert)
                document.pieceTable.replace(lower..<upper, withAddedRange: addedRange)
                model.replaceSubrange(lower..<upper, with: insert)
            }

            let result = FileWriter.saveSynchronously(document: document, to: outputURL)
            switch result {
            case .success:
                XCTAssertEqual(try? Data(contentsOf: outputURL), Data(model), "seed \(seed)")
            case .failure(let error):
                XCTFail("Save failed: \(error.localizedDescription)")
            }
        }
    }

    func testCancelledPieceSaveLeavesDestinationUntouched() {
        let inputURL = TestHelpers.writeTempFile("some content\n")
        let destinationURL = TestHelpers.writeTempFile("previous destination bytes")
        defer {
            TestHelpers.remove(inputURL)
            TestHelpers.remove(destinationURL)
        }
        let document = makeDocument("some content\n", at: inputURL)
        edit(document, replace: 0..<4, with: "MORE")
        let token = CancelToken()
        token.cancel()

        let result = FileWriter.saveSynchronously(document: document, to: destinationURL,
                                                  cancelToken: token)
        if case .success = result {
            XCTFail("A pre-cancelled save must fail")
        }
        let untouched = try? String(contentsOf: destinationURL, encoding: .utf8)
        XCTAssertEqual(untouched, "previous destination bytes")
        let tempPath = destinationURL.path + ".bigedit-tmp"
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempPath))
    }

    func testPieceSavePreservesDestinationPermissions() {
        let inputURL = TestHelpers.writeTempFile("content\n")
        let destinationURL = TestHelpers.writeTempFile("old")
        defer {
            TestHelpers.remove(inputURL)
            TestHelpers.remove(destinationURL)
        }
        chmod(destinationURL.path, 0o600)
        let document = makeDocument("content\n", at: inputURL)
        edit(document, replace: 0..<0, with: "new ")

        let result = FileWriter.saveSynchronously(document: document, to: destinationURL)
        switch result {
        case .success:
            var info = stat()
            XCTAssertEqual(stat(destinationURL.path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, 0o600)
        case .failure(let error):
            XCTFail("Save failed: \(error.localizedDescription)")
        }
    }

    func testEmptyReplacementDeletesAllOccurrences() {
        let content = "abc-abc-abc"
        let inputURL = TestHelpers.writeTempFile(content)
        let outputURL = inputURL.deletingLastPathComponent()
            .appendingPathComponent("BigEditTestOut-\(UUID().uuidString)")
        defer {
            TestHelpers.remove(inputURL)
            TestHelpers.remove(outputURL)
        }
        let file = MappedFile(path: inputURL.path)!
        let rule = ReplacementRule(pattern: "abc", replacement: "")!

        let result = FileWriter.saveSynchronously(file: file, rule: rule, to: outputURL)
        switch result {
        case .success:
            let written = try? String(contentsOf: outputURL, encoding: .utf8)
            XCTAssertEqual(written, "--")
        case .failure(let error):
            XCTFail("Save failed: \(error.localizedDescription)")
        }
    }
}
