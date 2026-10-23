import XCTest
@testable import BigEdit

/// Pretty Print and Compact for JSON copy every token as it was and rewrite
/// only the whitespace between them, whatever windows the input arrives in.
final class JSONFormatterTests: XCTestCase {

    private func format(_ text: String, _ style: FormattingStyle = .pretty,
                        options: FormattingOptions = FormattingOptions()) throws -> String {
        var formatter = JSONFormatter(style: style, options: options)
        return String(decoding: try formatter.format(Array(text.utf8)), as: UTF8.self)
    }

    private func pretty(_ text: String, width: Int = FormattingOptions.defaultLineWidth,
                        indentation: FormattingOptions.Indentation = .twoSpaces,
                        spaces: Bool = true) throws -> String {
        var options = FormattingOptions()
        options.lineWidth = width
        options.indentation = indentation
        options.spacesAfterSeparators = spaces
        return try format(text, options: options)
    }

    private func compact(_ text: String) throws -> String {
        try format(text, .compact)
    }

    /// Formats `bytes` fed `windowLength` bytes at a time, taking the
    /// output after every window.
    private func formatInWindows(_ bytes: [UInt8], windowLength: Int, style: FormattingStyle = .pretty,
                                 options: FormattingOptions = FormattingOptions()) throws -> [UInt8] {
        var formatter = JSONFormatter(style: style, options: options)
        var output: [UInt8] = []
        var start = 0
        while start < bytes.count {
            let end = min(bytes.count, start + windowLength)
            try formatter.feed(bytes[start..<end])
            output += formatter.takeOutput()
            start = end
        }
        try formatter.finish()
        return output + formatter.takeOutput()
    }

    private func error(_ text: String) -> FormattingError? {
        var formatter = JSONFormatter(style: .pretty)
        var caught: FormattingError?
        do {
            _ = try formatter.format(Array(text.utf8))
        } catch let error as FormattingError {
            caught = error
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        return caught
    }

    // MARK: - Layout

    func testAContainerThatFitsStaysOnOneLine() throws {
        XCTAssertEqual(try pretty(#"{"x":1,"y":2}"#), #"{"x": 1, "y": 2}"#)
        XCTAssertEqual(try pretty(#"[ "a" ,"b" ]"#), #"["a", "b"]"#)
    }

    func testAContainerTooWideBreaksOneMemberPerLineAndItsChildrenFitOnTheirOwn() throws {
        let input = #"{"name":"BigEdit","tags":["a","b"],"nested":{"deep":[1,2,3]}}"#

        XCTAssertEqual(try pretty(input, width: 40), """
            {
              "name": "BigEdit",
              "tags": ["a", "b"],
              "nested": {"deep": [1, 2, 3]}
            }
            """)
    }

    func testFittingCountsTheIndentationTheKeyAndAPossibleComma() throws {
        let input = #"[[1,2,3],[4,5,6]]"#

        XCTAssertEqual(try pretty(input, width: 12), "[\n  [1, 2, 3],\n  [4, 5, 6]\n]")
        XCTAssertEqual(try pretty(input, width: 11), "[\n  [\n    1,\n    2,\n    3\n  ],\n  [\n    4,\n    5,\n    6\n  ]\n]")
        XCTAssertEqual(try pretty(input, width: 28), "[[1, 2, 3], [4, 5, 6]]")
    }

    func testWidthZeroAlwaysBreaks() throws {
        XCTAssertEqual(try pretty(#"{"a":[1,2],"b":{},"c":[]}"#, width: 0), """
            {
              "a": [
                1,
                2
              ],
              "b": {},
              "c": []
            }
            """)
    }

    func testEmptyContainersStayEmptyWhereverTheyAre() throws {
        XCTAssertEqual(try pretty("{ }"), "{}")
        XCTAssertEqual(try pretty("[\n]"), "[]")
        XCTAssertEqual(try pretty(#"[{},[]]"#, width: 1), "[\n  {},\n  []\n]")
    }

    func testSpacesAfterSeparatorsCanBeTurnedOff() throws {
        XCTAssertEqual(try pretty(#"{"x": 1, "y": [1, 2]}"#, spaces: false), #"{"x":1,"y":[1,2]}"#)
        XCTAssertEqual(try pretty(#"{"x":1}"#, width: 0, spaces: false), "{\n  \"x\": 1\n}")
    }

    func testIndentationChoices() throws {
        let input = #"{"a":{"b":1}}"#

        XCTAssertEqual(try pretty(input, width: 0, indentation: .fourSpaces),
                       "{\n    \"a\": {\n        \"b\": 1\n    }\n}")
        XCTAssertEqual(try pretty(input, width: 0, indentation: .tab), "{\n\t\"a\": {\n\t\t\"b\": 1\n\t}\n}")
    }

    func testCompactRemovesEveryWhitespaceBetweenTokens() throws {
        XCTAssertEqual(try compact("{\n  \"a\" : [ 1 , 2 ],\n\t\"b\": \"x y\"\n}"), #"{"a":[1,2],"b":"x y"}"#)
    }

    func testTheDocumentsLineEndingIsUsed() throws {
        var options = FormattingOptions()
        options.lineWidth = 0
        options.newline = [0x0D, 0x0A]

        XCTAssertEqual(try format("[1,2]\r\n", options: options), "[\r\n  1,\r\n  2\r\n]\r\n")
    }

    func testATrailingNewlineIsKeptButNotAdded() throws {
        XCTAssertEqual(try pretty("[1]\n\n"), "[1]\n")
        XCTAssertEqual(try pretty("  [1]  "), "[1]")
        XCTAssertEqual(try compact("[ 1 ]\n"), "[1]\n")
    }

    func testValuesOneAfterAnotherGoOnLinesOfTheirOwn() throws {
        let lines = "{\"a\":1}\n{\"b\": [1,2]}\n3 \"x\"\n"

        XCTAssertEqual(try pretty(lines), "{\"a\": 1}\n{\"b\": [1, 2]}\n3\n\"x\"\n")
        XCTAssertEqual(try compact(lines), "{\"a\":1}\n{\"b\":[1,2]}\n3\n\"x\"\n")
    }

    func testALeadingByteOrderMarkIsCopiedThrough() throws {
        var formatter = JSONFormatter(style: .pretty)
        let output = try formatter.format([0xEF, 0xBB, 0xBF] + Array(#"{ "a" : 1 }"#.utf8))

        XCTAssertEqual(output, [0xEF, 0xBB, 0xBF] + Array(#"{"a": 1}"#.utf8))
        XCTAssertEqual(error("\u{FEFF}[x]")?.column, 2)
    }

    func testEmptyInputGivesEmptyOutput() throws {
        XCTAssertEqual(try pretty(""), "")
        XCTAssertEqual(try pretty(" \n "), "")
    }

    // MARK: - Tokens are copied as they were

    func testNumbersKeepTheirSpelling() throws {
        let input = "[1.10,1e400,-0,0.5E-3,2E+10,-12.0e-007,0]"

        XCTAssertEqual(try compact(input), input)
        XCTAssertEqual(try pretty(input), "[1.10, 1e400, -0, 0.5E-3, 2E+10, -12.0e-007, 0]")
    }

    func testStringsKeepTheirEscapes() throws {
        let input = #"{"a\"b":"\\ \/ \b\f\n\r\t \u00e9 \uD83D\uDE00 \u00E9"}"#

        XCTAssertEqual(try compact(input), input)
        XCTAssertEqual(try pretty(input, width: 0),
                       "{\n  \"a\\\"b\": \"\\\\ \\/ \\b\\f\\n\\r\\t \\u00e9 \\uD83D\\uDE00 \\u00E9\"\n}")
    }

    func testKeyOrderAndDuplicateKeysAreKept() throws {
        XCTAssertEqual(try compact(#"{"z":1,"a":2,"z":3}"#), #"{"z":1,"a":2,"z":3}"#)
    }

    func testNonASCIIIsCopiedAndCountedByCharacter() throws {
        let input = #"["Ærøskøbing","🙂🙂"]"#

        XCTAssertEqual(try pretty(input), #"["Ærøskøbing", "🙂🙂"]"#)
        // 20 characters fit in 20 columns, although they are 29 bytes.
        XCTAssertEqual(try pretty(input, width: 20), #"["Ærøskøbing", "🙂🙂"]"#)
        XCTAssertEqual(try pretty(input, width: 19), "[\n  \"Ærøskøbing\",\n  \"🙂🙂\"\n]")
    }

    func testDeepNestingDoesNotOverflowTheStack() throws {
        let depth = 1_000
        let input = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)

        let output = try pretty(input)

        XCTAssertEqual(try compact(output), input)
        XCTAssertEqual(try pretty(output), output)
    }

    // MARK: - Invalid input

    func testErrorsNameTheLineAndColumn() {
        XCTAssertEqual(error(#"{"a" 1}"#),
                       FormattingError(message: "Expected “:” but found “1”", line: 1, column: 6, offset: 5))
        XCTAssertEqual(error("{\n  \"a\": x\n}"),
                       FormattingError(message: "Expected a value but found “x”", line: 2, column: 8, offset: 9))
        XCTAssertEqual(error("[1,]")?.message, "Expected a value but found “]”")
        XCTAssertEqual(error("[1,]")?.column, 4)
        XCTAssertEqual(error(#"{"a":1,}"#)?.message, "Expected a string key but found “}”")
        XCTAssertEqual(error(#"[1 2]"#)?.message, "Expected “,” or “]” but found “2”")
        XCTAssertEqual(error(#"{"a":1]"#)?.message, "Expected “,” or “}” but found “]”")
        XCTAssertEqual(error("]")?.message, "Expected a value but found “]”")
    }

    func testColumnsCountCharactersNotBytes() {
        XCTAssertEqual(error(#"["øø" x]"#)?.column, 7)
    }

    func testUnclosedContainersPointAtWhereTheyOpened() {
        XCTAssertEqual(error("[\n  {\"a\": 1\n"),
                       FormattingError(message: "“{” is never closed", line: 2, column: 3, offset: 4))
    }

    func testInvalidScalars() {
        XCTAssertEqual(error("01")?.message, "Invalid number")
        XCTAssertEqual(error("[-]")?.message, "Invalid number")
        XCTAssertEqual(error("1.")?.message, "Invalid number")
        XCTAssertEqual(error("1e+")?.message, "Invalid number")
        XCTAssertEqual(error("[tru]")?.message, "Expected “true”")
        XCTAssertEqual(error("nul")?.message, "Expected “null”")
        XCTAssertEqual(error(#""abc"#), FormattingError(message: "The string is never closed",
                                                        line: 1, column: 1, offset: 0))
        XCTAssertEqual(error("\"a\nb\"")?.message, "A string cannot contain the control character 0x0A; escape it")
        XCTAssertEqual(error(#""\x""#)?.message, "“\\x” is not a valid escape")
        XCTAssertEqual(error(#""\u12G4""#)?.message, "Expected a hexadecimal digit in a \\u escape")
        XCTAssertEqual(error("// note\n1")?.message, "Comments are not allowed in JSON")
        XCTAssertEqual(error("[1] x")?.message, "Expected a value but found “x”")
    }

    // MARK: - Streaming

    func testAnyWindowingGivesTheSameOutput() throws {
        let input = Array(#"{"naïve": ["🙂", 1.5e-3, true, null, false, {"k": "\u00e9\"\\"}], "e": {}}"#.utf8)
        var narrow = FormattingOptions()
        narrow.lineWidth = 16
        let whole = try formatInWindows(input, windowLength: input.count, options: narrow)

        for windowLength in 1...9 {
            XCTAssertEqual(try formatInWindows(input, windowLength: windowLength, options: narrow), whole,
                           "window \(windowLength)")
            XCTAssertEqual(try formatInWindows(input, windowLength: windowLength, style: .compact),
                           try formatInWindows(input, windowLength: input.count, style: .compact))
        }
    }

    func testOutputArrivesBeforeTheInputEnds() throws {
        var formatter = JSONFormatter(style: .pretty)
        try formatter.feed(Array(("[\"" + String(repeating: "x", count: 100_000)).utf8)[...])

        XCTAssertGreaterThan(formatter.takeOutput().count, 90_000)
    }

    // MARK: - Round trips

    func testCompactOfPrettyIsCompactAndPrettyIsIdempotent() throws {
        let samples = [
            #"{"a":[1,2,{"b":null}],"c":"d","e":{"f":[[],{}]}}"#,
            #"[1.10,1e400,-0,"\u00e9",true]"#,
            "{\"list\":[" + (1...60).map(String.init).joined(separator: ",") + "]}",
            "1\n[2]\n{\"x\": 3}\n"
        ]
        for width in [0, 10, 40, 80] {
            for indentation in FormattingOptions.Indentation.allCases {
                for sample in samples {
                    let once = try pretty(sample, width: width, indentation: indentation)
                    XCTAssertEqual(try compact(once), try compact(sample))
                    XCTAssertEqual(try pretty(once, width: width, indentation: indentation), once)
                }
            }
        }
    }

    func testRandomDocumentsStayTheSameValue() throws {
        var generator = SeededGenerator(seed: 2026)
        for _ in 0..<200 {
            let sample = randomValue(depth: 0, using: &generator)
            let width = [0, 20, 80][Int.random(in: 0..<3, using: &generator)]
            let once = try pretty(sample, width: width)
            XCTAssertEqual(try compact(once), try compact(sample))
            XCTAssertEqual(try pretty(once, width: width), once)
            let decoded = try JSONSerialization.jsonObject(with: Data(once.utf8), options: .fragmentsAllowed)
            let original = try JSONSerialization.jsonObject(with: Data(sample.utf8), options: .fragmentsAllowed)
            XCTAssertEqual(decoded as? NSObject, original as? NSObject)
        }
    }

    private func randomValue(depth: Int, using generator: inout SeededGenerator) -> String {
        let pick = Int.random(in: 0..<(depth > 4 ? 4 : 7), using: &generator)
        var value: String
        switch pick {
        case 0: value = "\(Int.random(in: -1000...1000, using: &generator))"
        case 1: value = ["\"a b\"", "\"ø\\n\"", "\"\\u00e9\"", "\"\""][Int.random(in: 0..<4, using: &generator)]
        case 2: value = ["true", "false", "null"][Int.random(in: 0..<3, using: &generator)]
        case 3: value = "1.25e2"
        case 4, 5:
            let count = Int.random(in: 0..<5, using: &generator)
            let members = (0..<count).map { index in
                "\"k\(index)\" :\(randomValue(depth: depth + 1, using: &generator))"
            }
            value = "{ " + members.joined(separator: " ,\n") + "}"
        default:
            let count = Int.random(in: 0..<5, using: &generator)
            let items = (0..<count).map { _ in randomValue(depth: depth + 1, using: &generator) }
            value = "[" + items.joined(separator: ",") + " ]"
        }
        return value
    }
}
