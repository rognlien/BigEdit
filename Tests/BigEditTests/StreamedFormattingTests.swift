import XCTest
@testable import BigEdit

/// Formatting a document a window at a time into its add buffer gives what
/// formatting it whole gives, wherever the windows cut tokens and
/// characters, and never holds more than a window's worth at once.
final class StreamedFormattingTests: XCTestCase {

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
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        document.isEditable = true
        return document
    }

    private func narrow(_ width: Int) -> FormattingOptions {
        var options = FormattingOptions()
        options.lineWidth = width
        return options
    }

    /// Streams `range` of `document` (all of it by default) and returns the
    /// appended bytes, and how many parts they came in.
    private func stream(_ document: EditedDocument, range: Range<Int>? = nil, windowLength: Int,
                        formatter: any StreamingFormatter) throws -> (bytes: [UInt8], parts: [Int])? {
        var parts: [Int] = []
        let streamed = StreamedFormatting(document: document, range: range ?? 0..<document.length,
                                          windowLength: windowLength)
        let output = try streamed.run(formatter: formatter, isCancelled: { false }, onProgress: { _ in }) { bytes in
            parts.append(bytes.count)
            return document.appendToAddBuffer(bytes)
        }
        return output.map { (document.addBuffer.bytes(in: $0.added), parts) }
    }

    private func whole(_ bytes: [UInt8], formatter: any StreamingFormatter) throws -> [UInt8] {
        var formatter = formatter
        return try formatter.format(bytes)
    }

    func testJSONSplitAcrossAnyWindowsComesOutAsWhole() throws {
        let input = Array(#"{"naïve 🙂": ["øé\"\\", 1.10e-3, -0, true, null], "e": {}, "ææææææ": [[1, 2], [3]]}"#.utf8)
        for style in [FormattingStyle.pretty, .compact] {
            let expected = try whole(input, formatter: JSONFormatter(style: style, options: narrow(14)))
            for windowLength in 1...13 {
                let streamed = try stream(document(input), windowLength: windowLength,
                                          formatter: JSONFormatter(style: style, options: narrow(14)))
                XCTAssertEqual(streamed?.bytes, expected, "window \(windowLength)")
            }
        }
    }

    func testXMLSplitAcrossAnyWindowsComesOutAsWhole() throws {
        let input = Array("""
            <?xml version="1.0"?><!DOCTYPE r [<!ENTITY e "]>">]><r a="Ærø" b='1'><!-- c --><p>mixed <b>ø</b></p>\
            <![CDATA[x]]><x/><?pi ?><q xml:space="preserve"> <z/> </q><t>🙂</t><u v="1" w="2" x="3"/></r>
            """.utf8)
        for style in [FormattingStyle.pretty, .compact] {
            let expected = try whole(input, formatter: XMLFormatter(style: style, options: narrow(16)))
            for windowLength in 1...13 {
                let streamed = try stream(document(input), windowLength: windowLength,
                                          formatter: XMLFormatter(style: style, options: narrow(16)))
                XCTAssertEqual(streamed?.bytes, expected, "window \(windowLength)")
            }
        }
    }

    /// A character split between windows still counts once when fitting.
    func testCharactersSplitAcrossWindowsAreCountedOnce() throws {
        let input = Array(#"["🙂🙂🙂🙂", "øøø"]"#.utf8)
        let expected = Array(#"["🙂🙂🙂🙂", "øøø"]"#.utf8)

        for windowLength in [1, 2, 3, 5, 7] {
            let streamed = try stream(document(input), windowLength: windowLength,
                                      formatter: JSONFormatter(style: .pretty, options: narrow(17)))
            XCTAssertEqual(streamed?.bytes, expected, "window \(windowLength)")
        }
    }

    func testOnlyTheRangeIsFormatted() throws {
        let input = Array(#"before {"a" : [1,2]} after"#.utf8)
        let document = document(input)

        let streamed = try stream(document, range: 7..<20, windowLength: 4, formatter: JSONFormatter(style: .compact))

        XCTAssertEqual(streamed?.bytes, Array(#"{"a":[1,2]}"#.utf8))
        XCTAssertEqual(document.bytes(in: 0..<document.length), input, "the document itself is untouched")
    }

    func testTheOutputIsHandedOnAWindowAtATime() throws {
        let items = (0..<5_000).map { "{\"id\": \($0), \"name\": \"item \($0)\"}" }
        let input = Array(("[" + items.joined(separator: ",") + "]").utf8)

        let streamed = try XCTUnwrap(stream(document(input), windowLength: 4096,
                                            formatter: JSONFormatter(style: .pretty, options: narrow(0))))

        XCTAssertGreaterThan(streamed.parts.count, input.count / 4096)
        XCTAssertLessThan(streamed.parts.max() ?? 0, 4 * 4096)
        XCTAssertEqual(streamed.bytes, try whole(input, formatter: JSONFormatter(style: .pretty, options: narrow(0))))
    }

    func testInvalidTextThrowsWhereItStopsBeingValid() {
        let document = document(Array("[1, 2,\n 3 4]".utf8))
        let streamed = StreamedFormatting(document: document, range: 0..<document.length, windowLength: 3)

        XCTAssertThrowsError(try streamed.run(formatter: JSONFormatter(style: .pretty), isCancelled: { false },
                                              onProgress: { _ in }, append: document.appendToAddBuffer)) { error in
            XCTAssertEqual(error as? FormattingError,
                           FormattingError(message: "Expected “,” or “]” but found “4”", line: 2, column: 4, offset: 10))
        }
    }

    func testCancellingStopsAtTheNextWindow() throws {
        let document = document(Array(String(repeating: "[1, 2] ", count: 1_000).utf8))
        var windows = 0
        let streamed = StreamedFormatting(document: document, range: 0..<document.length, windowLength: 64)

        let output = try streamed.run(formatter: JSONFormatter(style: .compact), isCancelled: { windows >= 3 },
                                      onProgress: { _ in windows += 1 }, append: document.appendToAddBuffer)

        XCTAssertNil(output)
        XCTAssertEqual(windows, 3)
    }

    func testTextAlreadyFormattedIsNoticed() throws {
        let formatted = document(Array("{\"a\": [1, 2]}\n".utf8))
        let unformatted = document(Array("{\"a\": [1,2]}\n".utf8))

        for (document, isUnchanged) in [(formatted, true), (unformatted, false)] {
            let streamed = StreamedFormatting(document: document, range: 0..<document.length, windowLength: 3)
            let output = try streamed.run(formatter: JSONFormatter(style: .pretty), isCancelled: { false },
                                          onProgress: { _ in }, append: document.appendToAddBuffer)
            XCTAssertEqual(output?.isUnchanged, isUnchanged)
            XCTAssertEqual(output?.containsNewline, true)
        }
    }

    func testBytesAppendedFromElsewhereInterrupt() {
        let document = document(Array("[1, 2, 3, 4, 5, 6]".utf8))
        let streamed = StreamedFormatting(document: document, range: 0..<document.length, windowLength: 4)

        XCTAssertThrowsError(try streamed.run(formatter: JSONFormatter(style: .compact), isCancelled: { false },
                                              onProgress: { _ in }) { bytes in
            _ = document.appendToAddBuffer([0x20])
            return document.appendToAddBuffer(bytes)
        }) { error in
            XCTAssertTrue(error is StreamedFormatting.Interrupted)
        }
    }
}
