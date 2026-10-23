import AppKit
import XCTest
@testable import BigEdit

/// Edit ▸ Format through a document view: the selection or the whole
/// document is formatted as one undoable edit, and invalid text is left
/// alone with its error placed in the document.
final class FormatCommandTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func open(_ bytes: [UInt8], extension fileExtension: String) -> DocumentView {
        let url = TestHelpers.writeTempFile(Data(bytes)).appendingPathExtension(fileExtension)
        try? Data(bytes).write(to: url)
        temporaryFiles.append(url)
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let view = TestHelpers.isolatedDocumentView()
        view.load(file: file, index: index)
        view.setFileFormat(FileFormat(scanning: file))
        return view
    }

    private func open(_ text: String, extension fileExtension: String = "json") -> DocumentView {
        open(Array(text.utf8), extension: fileExtension)
    }

    private func bytes(of view: DocumentView) -> [UInt8] {
        let document = view.viewport.document!
        return document.bytes(in: 0..<document.length)
    }

    private func text(of view: DocumentView) -> String {
        String(decoding: bytes(of: view), as: UTF8.self)
    }

    private func select(_ range: Range<Int>, in view: DocumentView) {
        view.viewport.selection = TextSelection(anchorOffset: range.lowerBound, activeOffset: range.upperBound)
    }

    @discardableResult
    private func format(_ view: DocumentView, _ style: FormattingStyle = .pretty,
                        options: FormattingOptions = FormattingOptions()) -> FormattingError? {
        var failure: FormattingError?
        view.format(style, options: options) { result in
            if case .failure(let error) = result {
                failure = error
            }
        }
        return failure
    }

    func testPrettyPrintFormatsTheWholeDocumentAndUndoPutsBackEveryByte() {
        let original = "{\"name\" :\"BigEdit\",\t\"tags\":[ 1.10 ,1e400,-0 ],\n\"nested\":{\"deep\":{}}}\n"
        let view = open(original)
        var options = FormattingOptions()
        options.lineWidth = 0

        XCTAssertNil(format(view, options: options))
        let formatted = text(of: view)
        XCTAssertEqual(formatted, """
            {
              "name": "BigEdit",
              "tags": [
                1.10,
                1e400,
                -0
              ],
              "nested": {
                "deep": {}
              }
            }

            """)

        view.viewport.undo(nil)
        XCTAssertEqual(bytes(of: view), Array(original.utf8))

        view.viewport.redo(nil)
        XCTAssertEqual(text(of: view), formatted)
    }

    func testPrettyPrintFormatsOnlyTheSelectionAndSelectsTheResult() {
        let view = open("[1,\n {\"c\":1,\"d\":[2,3]},\n4]")
        let start = "[1,\n ".utf8.count
        select(start..<(start + "{\"c\":1,\"d\":[2,3]}".utf8.count), in: view)

        format(view)

        XCTAssertEqual(text(of: view), "[1,\n {\"c\": 1, \"d\": [2, 3]},\n4]")
        let formattedLength = "{\"c\": 1, \"d\": [2, 3]}".utf8.count
        XCTAssertEqual(view.viewport.selection?.range, start..<(start + formattedLength))

        view.viewport.undo(nil)
        XCTAssertEqual(text(of: view), "[1,\n {\"c\":1,\"d\":[2,3]},\n4]")
    }

    func testCompactIsOneUndoableEdit() {
        let original = "<root>\n  <a>1</a>\n  <b/>\n</root>\n"
        let view = open(original, extension: "xml")

        format(view, .compact)

        XCTAssertEqual(text(of: view), "<root><a>1</a><b/></root>\n")
        view.viewport.undo(nil)
        XCTAssertEqual(text(of: view), original)
        XCTAssertFalse(view.viewport.document!.undoStack.canUndo)
    }

    func testFormattingIsAStepOfItsOwnBetweenTypedText() {
        let view = open("[1, 2]")
        view.viewport.selection = TextSelection(anchorOffset: 5, activeOffset: 5)
        view.viewport.insertText("3", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(text(of: view), "[1, 23]")
        view.viewport.selection = nil

        format(view, .compact)
        view.viewport.selection = TextSelection(anchorOffset: 5, activeOffset: 5)
        view.viewport.insertText("4", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(text(of: view), "[1,234]")

        view.viewport.undo(nil)
        XCTAssertEqual(text(of: view), "[1,23]")
        view.viewport.undo(nil)
        XCTAssertEqual(text(of: view), "[1, 23]")
    }

    func testTextAlreadyFormattedIsLeftWithoutAnEdit() {
        let view = open("{\"a\": 1}\n")

        format(view)

        XCTAssertFalse(view.viewport.document!.hasEdits)
        XCTAssertFalse(view.viewport.document!.undoStack.canUndo)
    }

    func testInvalidTextChangesNothingAndNamesItsPlace() {
        let original = "{\n  \"a\": 1,\n  \"b\" 2\n}\n"
        let view = open(original)

        let error = format(view)

        XCTAssertEqual(error?.message, "Expected “:” but found “2”")
        XCTAssertEqual(error?.line, 3)
        XCTAssertEqual(error?.column, 7)
        XCTAssertEqual(text(of: view), original)
        XCTAssertFalse(view.viewport.document!.hasEdits)
    }

    func testAnErrorInASelectionIsPlacedInTheDocument() {
        let view = open("[\n  1,\n  [ø, 2]\n]")
        let start = "[\n  1,\n  ".utf8.count
        select(start..<(start + "[ø, 2]".utf8.count), in: view)

        let error = format(view)

        XCTAssertEqual(error?.line, 3)
        XCTAssertEqual(error?.column, 4)
        XCTAssertEqual(error?.offset, start + 1)
    }

    func testTheDocumentsLineEndingIsUsed() {
        let view = open("<a>\r\n<b/><c/></a>\r\n", extension: "xml")

        format(view)

        XCTAssertEqual(text(of: view), "<a>\r\n  <b/>\r\n  <c/>\r\n</a>\r\n")
    }

    func testASingleByteEncodingIsFormattedInPlace() {
        let original: [UInt8] = Array("{\"caf".utf8) + [0xE9] + Array("\":[1, 2]}".utf8)
        let view = open(original, extension: "json")
        XCTAssertEqual(view.textEncoding, .windows1252)

        format(view, .compact)

        XCTAssertEqual(bytes(of: view), Array("{\"caf".utf8) + [0xE9] + Array("\":[1,2]}".utf8))
    }

    func testFormatAppliesOnlyToJSONAndXMLShownAsText() {
        let plain = open("1", extension: "txt")
        XCTAssertFalse(plain.canFormat)
        plain.chooseLanguage(LanguageRegistry.json)
        XCTAssertTrue(plain.canFormat)

        let table = open("name,age\nbob,42\nann,7\neve,3\n", extension: "json")
        XCTAssertTrue(table.canFormat)
        table.formatBar.setMode(.csv)
        table.formatBar(table.formatBar, didSelect: .csv)
        XCTAssertFalse(table.canFormat)
    }

    // MARK: - Text longer than the in-place limit

    /// Formats `view` through the streamed path, and waits for it.
    @discardableResult
    private func formatStreamed(_ view: DocumentView, _ style: FormattingStyle = .pretty) -> FormattingError? {
        let limit = DocumentView.formattingInPlaceLimit
        DocumentView.formattingInPlaceLimit = 8
        defer { DocumentView.formattingInPlaceLimit = limit }
        let finished = expectation(description: "formatted")
        var failure: FormattingError?
        view.format(style, options: FormattingOptions()) { result in
            if case .failure(let error) = result {
                failure = error
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        return failure
    }

    func testLongTextStreamsInAsOneUndoableEdit() throws {
        let original = "{\"list\": [" + (1...300).map { "{\"n\":\($0)}" }.joined(separator: ",") + "]}\n"
        let view = open(original)
        var formatter = JSONFormatter(style: .pretty)
        let formatted = try formatter.format(Array(original.utf8))

        XCTAssertNil(formatStreamed(view))

        XCTAssertEqual(bytes(of: view), formatted)
        XCTAssertEqual(view.viewport.selection?.range, 0..<0)
        view.viewport.undo(nil)
        XCTAssertEqual(text(of: view), original)
        view.viewport.redo(nil)
        XCTAssertEqual(bytes(of: view), formatted)
    }

    func testALongSelectionStreamsInAndIsSelected() {
        let view = open("<a>\n<b><c/><d/></b>\n</a>\n", extension: "xml")
        let start = "<a>\n".utf8.count
        select(start..<(start + "<b><c/><d/></b>".utf8.count), in: view)

        formatStreamed(view)

        XCTAssertEqual(text(of: view), "<a>\n<b>\n  <c/>\n  <d/>\n</b>\n</a>\n")
        XCTAssertEqual(view.viewport.selection?.range, start..<(start + "<b>\n  <c/>\n  <d/>\n</b>".utf8.count))
    }

    func testInvalidLongTextChangesNothing() {
        let original = "[\n  1,\n  2\n  3\n]"
        let view = open(original)

        let error = formatStreamed(view)

        XCTAssertEqual(error?.line, 4)
        XCTAssertEqual(error?.column, 3)
        XCTAssertEqual(text(of: view), original)
        XCTAssertFalse(view.viewport.document!.hasEdits)
    }

    func testLongTextAlreadyFormattedIsLeftWithoutAnEdit() {
        let line = String(repeating: "x", count: 90)
        let view = open("[\n  \"\(line)\",\n  2\n]\n")

        XCTAssertNil(formatStreamed(view))

        XCTAssertFalse(view.viewport.document!.hasEdits)
    }

    func testTheMenuItemsAreDisabledWithoutADocument() {
        let delegate = AppDelegate()
        let menu = delegate.buildFormatMenu()

        XCTAssertEqual(menu.items.map(\.title), ["Pretty Print", "Compact"])
        XCTAssertFalse(menu.items.contains { delegate.validateMenuItem($0) })
    }

    /// ⌥⌘L is free in AppKit's standard key bindings, which write Option
    /// as `~` and Command as `@`.
    func testThePrettyPrintShortcutOverridesNoStandardKeyBinding() throws {
        let item = AppDelegate().buildFormatMenu().items[0]
        let url = URL(fileURLWithPath: "/System/Library/Frameworks/AppKit.framework/Resources/StandardKeyBinding.dict")
        let bindings = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])

        XCTAssertEqual(item.keyEquivalent, "l")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
        for key in ["~@l", "@~l"] {
            XCTAssertNil(bindings[key], key)
        }
    }
}
