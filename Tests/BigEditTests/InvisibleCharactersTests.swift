import XCTest
@testable import BigEdit

final class InvisibleCharactersTests: XCTestCase {

    private typealias Mark = InvisibleCharacters.Mark

    private func marks(_ text: String, terminator: InvisibleCharacters.LineTerminator = .none,
                       startsDocument: Bool = false) -> [Mark] {
        InvisibleCharacters.marks(in: text, terminator: terminator, startsDocument: startsDocument)
    }

    func testPlainTextHasNoMarks() {
        XCTAssertEqual(marks("word"), [])
    }

    func testSpacesAndTabsAreMarkedWhereTheyAre() {
        XCTAssertEqual(marks("a b\tc"), [Mark(kind: .space, offset: 1), Mark(kind: .tab, offset: 3)])
    }

    func testALineFeedIsMarkedAfterTheText() {
        XCTAssertEqual(marks("ab", terminator: .lineFeed), [Mark(kind: .lineFeed, offset: 2)])
    }

    func testACRLFEndingIsOneMarkThatDiffersFromALineFeed() {
        XCTAssertEqual(marks("ab", terminator: .carriageReturnLineFeed),
                       [Mark(kind: .carriageReturnLineFeed, offset: 2)])
    }

    func testAnUnterminatedLineHasNoLineEndingMark() {
        XCTAssertEqual(marks("ab", terminator: .none), [])
    }

    func testALoneCarriageReturnIsMarkedInsideTheLineAndAtItsEnd() {
        XCTAssertEqual(marks("a\rb", terminator: .carriageReturn),
                       [Mark(kind: .carriageReturn, offset: 1), Mark(kind: .carriageReturn, offset: 3)])
    }

    func testUnicodeSpacesAreUnusual() {
        let text = "\u{00A0}\u{202F}\u{2007}\u{2003}\u{3000}"

        XCTAssertEqual(marks(text).map(\.kind), Array(repeating: .unusualSpace, count: 5))
    }

    func testZeroWidthCharactersAreMarked() {
        let text = "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}"

        XCTAssertEqual(marks(text).map(\.kind), Array(repeating: .zeroWidth, count: 5))
        XCTAssertEqual(marks(text).map(\.offset), [0, 1, 2, 3, 4])
    }

    func testAByteOrderMarkStartingTheDocumentIsNotMarked() {
        XCTAssertEqual(marks("\u{FEFF}a\u{FEFF}", startsDocument: true), [Mark(kind: .zeroWidth, offset: 2)])
    }

    func testAByteOrderMarkStartingALaterRowIsMarked() {
        XCTAssertEqual(marks("\u{FEFF}a"), [Mark(kind: .zeroWidth, offset: 0)])
    }

    func testControlCharactersAreMarked() {
        XCTAssertEqual(marks("\u{01}\u{1E}\u{7F}\u{85}").map(\.kind), Array(repeating: .control, count: 4))
    }

    func testOffsetsCountUTF16Units() {
        XCTAssertEqual(marks("🙂 漢 e\u{0301} ", terminator: .lineFeed),
                       [Mark(kind: .space, offset: 2), Mark(kind: .space, offset: 4),
                        Mark(kind: .space, offset: 7), Mark(kind: .lineFeed, offset: 8)])
    }

    func testOnlyTheCharactersPeopleHuntForAreProminent() {
        let prominent: [InvisibleCharacters.Kind] = [.unusualSpace, .zeroWidth, .control, .carriageReturn]
        let ordinary: [InvisibleCharacters.Kind] = [.space, .tab, .lineFeed, .carriageReturnLineFeed]

        XCTAssertTrue(prominent.allSatisfy(\.isProminent))
        XCTAssertFalse(ordinary.contains(where: \.isProminent))
    }
}
