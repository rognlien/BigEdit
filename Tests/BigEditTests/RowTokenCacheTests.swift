import XCTest
@testable import BigEdit

final class RowTokenCacheTests: XCTestCase {

    private let inComment = HighlightState(JSONHighlighter.State.blockComment, of: JSONHighlighter.self)

    func testCachedRowsMatchTheHighlighter() {
        let cache = RowTokenCache()
        cache.language = LanguageRegistry.json
        let rows = ["{\"a\": 1, /* open", "still inside", "done */ \"b\": true}"]

        var state = HighlightState.normal
        for row in rows {
            for _ in 0..<2 {
                let expected = LanguageRegistry.json.tokens(row, startState: state)
                let cached = cache.tokens(row, startState: state)
                XCTAssertEqual(cached.0, expected.0)
                XCTAssertEqual(cached.1, expected.1)
                XCTAssertEqual(cache.endState(row, start: state), expected.1)
            }
            state = cache.endState(row, start: state)
        }
    }

    func testTheStartStateIsPartOfTheKey() {
        let cache = RowTokenCache()
        cache.language = LanguageRegistry.json

        let outside = cache.tokens("\"text\"", startState: .normal)
        let inside = cache.tokens("\"text\"", startState: inComment)

        XCTAssertNotEqual(outside.0, inside.0)
    }

    func testChangingTheLanguageStartsOver() {
        let cache = RowTokenCache()
        cache.language = LanguageRegistry.json
        _ = cache.tokens("<a>", startState: .normal)

        cache.language = LanguageRegistry.xml

        XCTAssertEqual(cache.tokens("<a>", startState: .normal).0,
                       LanguageRegistry.xml.tokens("<a>", startState: .normal).0)
    }

    func testAFullCacheKeepsAnswering() {
        let cache = RowTokenCache(capacity: 2)
        cache.language = LanguageRegistry.json

        for value in 0..<10 {
            XCTAssertEqual(cache.tokens("\(value)", startState: .normal).0,
                           LanguageRegistry.json.tokens("\(value)", startState: .normal).0)
        }
    }
}
