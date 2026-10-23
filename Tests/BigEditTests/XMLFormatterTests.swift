import XCTest
@testable import BigEdit

/// Pretty Print and Compact for XML rewrite only the whitespace-only text
/// between elements, and leave text, markup and anything whose whitespace
/// may matter exactly as it was.
final class XMLFormatterTests: XCTestCase {

    private func format(_ text: String, _ style: FormattingStyle = .pretty,
                        options: FormattingOptions = FormattingOptions(),
                        lookaheadLimit: Int = XMLFormatter.lookaheadLimit) throws -> String {
        var formatter = XMLFormatter(style: style, options: options, lookaheadLimit: lookaheadLimit)
        return String(decoding: try formatter.format(Array(text.utf8)), as: UTF8.self)
    }

    private func pretty(_ text: String, width: Int = FormattingOptions.defaultLineWidth,
                        indentation: FormattingOptions.Indentation = .twoSpaces) throws -> String {
        var options = FormattingOptions()
        options.lineWidth = width
        options.indentation = indentation
        return try format(text, options: options)
    }

    private func compact(_ text: String) throws -> String {
        try format(text, .compact)
    }

    private func formatInWindows(_ bytes: [UInt8], windowLength: Int, style: FormattingStyle = .pretty,
                                 options: FormattingOptions = FormattingOptions()) throws -> [UInt8] {
        var formatter = XMLFormatter(style: style, options: options)
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
        var formatter = XMLFormatter(style: .pretty)
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

    func testElementsGoOnLinesOfTheirOwnAndShortTextStaysWithItsElement() throws {
        XCTAssertEqual(try pretty(#"<root><name>Bob</name><b x="1"/><list><item>1</item></list></root>"#), """
            <root>
              <name>Bob</name>
              <b x="1"/>
              <list>
                <item>1</item>
              </list>
            </root>
            """)
    }

    func testThePrologCommentsAndProcessingInstructionsAreKeptVerbatim() throws {
        let input = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE note [ <!ENTITY a "b>c"> <!ELEMENT note ANY> ]>
            <!--  top  --><note><to>Tove</to><!-- inner
              comment --><?php echo 1; ?><body>Hi &amp; bye &a; &#x41;</body></note>
            """

        XCTAssertEqual(try pretty(input), """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE note [ <!ENTITY a "b>c"> <!ELEMENT note ANY> ]>
            <!--  top  -->
            <note>
              <to>Tove</to>
              <!-- inner
              comment -->
              <?php echo 1; ?>
              <body>Hi &amp; bye &a; &#x41;</body>
            </note>
            """)
    }

    func testMixedContentIsCopiedExactlyWithEverythingInside() throws {
        let input = "<root>\n<p>Hello <b> bold </b>  world</p>\n<p>\n  <i>x</i> tail <div>\n<e/>\n</div>\n</p>\n</root>"

        XCTAssertEqual(try pretty(input), """
            <root>
              <p>Hello <b> bold </b>  world</p>
              <p>
              <i>x</i> tail <div>
            <e/>
            </div>
            </p>
            </root>
            """)
    }

    func testTextAloneIsNeverTouchedHoweverLongOrSpaced() throws {
        let long = String(repeating: "word ", count: 40)

        XCTAssertEqual(try pretty("<a><b>  \(long) </b><c>\n</c><d></d></a>", width: 20),
                       "<a>\n  <b>  \(long) </b>\n  <c>\n</c>\n  <d></d>\n</a>")
    }

    func testPreservedSpaceIsCopiedUntilDefaultTurnsFormattingBackOn() throws {
        let input = #"<pre xml:space="preserve">  <x xml:space="default"><a/><b/></x>  <y> <z/> </y></pre>"#

        XCTAssertEqual(try pretty(input),
                       "<pre xml:space=\"preserve\">  <x xml:space=\"default\">\n    <a/>\n    <b/>\n  </x>  <y> <z/> </y></pre>")
    }

    func testCDATAIsTextAndKeptVerbatim() throws {
        XCTAssertEqual(try pretty("<r><c><![CDATA[ <not> a ]] tag ]]></c><d/></r>"),
                       "<r>\n  <c><![CDATA[ <not> a ]] tag ]]></c>\n  <d/>\n</r>")
        XCTAssertEqual(try pretty("<r>\n <![CDATA[x]]>\n <d/>\n</r>"), "<r>\n <![CDATA[x]]>\n <d/>\n</r>")
    }

    func testTagsAreTidiedAndSelfClosingTagsStaySelfClosing() throws {
        XCTAssertEqual(try pretty(#"<a  x = "1"   y='2' ><b /><c></c ></a >"#),
                       "<a x=\"1\" y='2'>\n  <b/>\n  <c></c >\n</a>")
    }

    func testAttributesOfATagTooWideAreAlignedUnderTheFirst() throws {
        XCTAssertEqual(try pretty(#"<root><element first="1" second="2" third="3"/></root>"#, width: 30), """
            <root>
              <element first="1"
                       second="2"
                       third="3"/>
            </root>
            """)
        XCTAssertEqual(try pretty(#"<element first="1" second="2"><x/></element>"#, width: 20,
                                  indentation: .tab), "<element first=\"1\"\n         second=\"2\">\n\t<x/>\n</element>")
        XCTAssertEqual(try pretty(#"<single attribute="is never wrapped"/>"#, width: 10),
                       #"<single attribute="is never wrapped"/>"#)
        XCTAssertEqual(try pretty(#"<e a="1" b="2" c="3"/>"#, width: 0), #"<e a="1" b="2" c="3"/>"#)
    }

    func testIndentationChoices() throws {
        XCTAssertEqual(try pretty("<a><b><c/></b></a>", indentation: .fourSpaces),
                       "<a>\n    <b>\n        <c/>\n    </b>\n</a>")
        XCTAssertEqual(try pretty("<a><b><c/></b></a>", indentation: .tab), "<a>\n\t<b>\n\t\t<c/>\n\t</b>\n</a>")
    }

    func testTheDocumentsLineEndingIsUsedAndATrailingNewlineKept() throws {
        var options = FormattingOptions()
        options.newline = [0x0D, 0x0A]

        XCTAssertEqual(try format("<a>\r\n<b/></a>\r\n\r\n", options: options), "<a>\r\n  <b/>\r\n</a>\r\n")
        XCTAssertEqual(try pretty("<a/>"), "<a/>")
    }

    func testCompactRemovesOnlyWhitespaceBetweenElements() throws {
        let input = "<?xml version=\"1.0\"?>\n<root>\n  <a>1</a>\n  <b>\n    <c/>\n  </b>\n  <p>a <i>x</i> </p>\n</root>\n"

        XCTAssertEqual(try compact(input), "<?xml version=\"1.0\"?><root><a>1</a><b><c/></b><p>a <i>x</i> </p></root>\n")
    }

    func testNonASCIIIsCopiedAndCountedByCharacter() throws {
        XCTAssertEqual(try pretty("<liste><navn by=\"Ærø\" å=\"ø\">Ærøskøbing 🙂</navn></liste>", width: 23),
                       "<liste>\n  <navn by=\"Ærø\" å=\"ø\">Ærøskøbing 🙂</navn>\n</liste>")
        XCTAssertEqual(try pretty("<liste><navn by=\"Ærø\" å=\"ø\">Ærøskøbing 🙂</navn></liste>", width: 22),
                       "<liste>\n  <navn by=\"Ærø\"\n        å=\"ø\">Ærøskøbing 🙂</navn>\n</liste>")
    }

    func testALeadingByteOrderMarkIsCopiedThrough() throws {
        var formatter = XMLFormatter(style: .compact)

        XCTAssertEqual(try formatter.format([0xEF, 0xBB, 0xBF] + Array("<a> <b/> </a>".utf8)),
                       [0xEF, 0xBB, 0xBF] + Array("<a><b/></a>".utf8))
    }

    func testDeepNesting() throws {
        let depth = 1_000
        let input = String(repeating: "<a>", count: depth) + "x" + String(repeating: "</a>", count: depth)

        let output = try pretty(input)

        XCTAssertEqual(try compact(output), input)
        XCTAssertEqual(try pretty(output), output)
    }

    // MARK: - Lookahead

    func testContentLongerThanTheLookaheadIsTakenToBeElementsOnly() throws {
        XCTAssertEqual(try format("<r><a/><b/><c/>text <d/></r>", lookaheadLimit: 8),
                       "<r>\n  <a/>\n  <b/>\n  <c/>text <d/></r>")
        XCTAssertEqual(try format("<r><a/><b/><c/>text <d/></r>"), "<r><a/><b/><c/>text <d/></r>")
    }

    func testOutputArrivesBeforeTheInputEnds() throws {
        var formatter = XMLFormatter(style: .pretty)
        try formatter.feed(Array(("<r><t>" + String(repeating: "x", count: 100_000)).utf8)[...])

        XCTAssertGreaterThan(formatter.takeOutput().count, 90_000)
    }

    // MARK: - Invalid input

    func testErrorsNameTheLineAndColumn() {
        XCTAssertEqual(error("<a><b></a>"),
                       FormattingError(message: "Expected “</b>” but found “</a>”", line: 1, column: 7, offset: 6))
        XCTAssertEqual(error("<a>\n  <b>\n</a>")?.line, 3)
        XCTAssertEqual(error("<a>\n<b>"), FormattingError(message: "“<b>” is never closed", line: 2, column: 1, offset: 4))
        XCTAssertEqual(error("<a><!-- x"),
                       FormattingError(message: "The comment is never closed", line: 1, column: 4, offset: 3))
        XCTAssertEqual(error("<a><![CDATA[x</a>")?.message, "The CDATA section is never closed")
        XCTAssertEqual(error("<?xml version='1.0'")?.message, "The processing instruction is never closed")
        XCTAssertEqual(error("<!DOCTYPE a [ <!ENTITY b 'c'> <a/>")?.message, "The declaration is never closed")
        XCTAssertEqual(error("<a x=1/>"),
                       FormattingError(message: "Expected a quoted attribute value", line: 1, column: 6, offset: 5))
        XCTAssertEqual(error("<a x/>")?.message, "Expected “=” after the attribute name")
        XCTAssertEqual(error("<a x=\"1/>")?.message, "The tag is never closed")
        XCTAssertEqual(error("<a/ >")?.message, "Expected “>” after “/”")
        XCTAssertEqual(error("</a>")?.message, "“</a>” closes no element")
        XCTAssertEqual(error("<a/>x")?.message, "Text is not allowed outside an element")
        XCTAssertEqual(error("<a>< b/></a>")?.column, 4)
        XCTAssertEqual(error("<a><!1></a>")?.message, "Expected a comment, a CDATA section or a declaration after “<!”")
        XCTAssertEqual(error("<a></ a>")?.message, "Expected an element name after “</”")
        XCTAssertEqual(error("<a></a b>")?.message, "Expected “>” to end the end tag")
    }

    func testErrorColumnsCountCharacters() {
        XCTAssertEqual(error("<ø><æ></ø>")?.column, 7)
    }

    // MARK: - Streaming

    func testAnyWindowingGivesTheSameOutput() throws {
        let input = Array("""
            <?xml version="1.0"?><!DOCTYPE r [<!ENTITY e "]>">]><r a="Ærø" b='1'><!-- c -- --><p>mixed <b>ø</b></p>\
            <![CDATA[]]]]><x/><?pi ??>  <q xml:space="preserve"> <z/> </q><t>🙂</t></r>
            """.utf8)
        var narrow = FormattingOptions()
        narrow.lineWidth = 12

        for style in [FormattingStyle.pretty, .compact] {
            let whole = try formatInWindows(input, windowLength: input.count, style: style, options: narrow)
            for windowLength in 1...9 {
                XCTAssertEqual(try formatInWindows(input, windowLength: windowLength, style: style, options: narrow),
                               whole, "window \(windowLength)")
            }
        }
    }

    // MARK: - Round trips

    func testCompactOfPrettyIsCompactAndPrettyIsIdempotent() throws {
        let samples = [
            #"<root><name>Bob</name><b x="1" y="2" z="3"/><list><item>1</item><item>2</item></list></root>"#,
            "<?xml version=\"1.0\"?>\n<!-- c --><r>\n<p>Hello <b>x</b> world</p><e></e><f/></r>\n",
            #"<pre xml:space="preserve"> <a/> <x xml:space="default"><b/><c/></x></pre>"#,
            "<a><![CDATA[x]]></a>"
        ]
        for width in [0, 10, 40, 80] {
            for indentation in FormattingOptions.Indentation.allCases {
                for sample in samples {
                    let once = try pretty(sample, width: width, indentation: indentation)
                    XCTAssertEqual(try compact(once), try compact(sample), sample)
                    XCTAssertEqual(try pretty(once, width: width, indentation: indentation), once, sample)
                }
            }
        }
    }
}
