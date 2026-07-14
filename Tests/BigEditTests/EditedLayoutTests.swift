import XCTest
@testable import BigEdit

/// The edited layout must answer every line/row question exactly as a fresh
/// index over the edited bytes would. Each check here recomputes the layout
/// facts naively from the materialised content and compares.
final class EditedLayoutTests: XCTestCase {

    // MARK: - Naive reference

    /// Recomputes lines, rows, and chunking from plain bytes, mirroring
    /// `LineIndex` semantics: lines split on `\n`, trailing bytes after the
    /// last newline form a final line, long lines chunk at the wrap width.
    private struct NaiveLayout {
        struct Line {
            let start: Int
            let contentLength: Int   // excludes the newline
        }

        let lines: [Line]
        let wrap: Int

        init(_ bytes: [UInt8], wrap: Int) {
            var collected: [Line] = []
            var lineStart = 0
            for (position, byte) in bytes.enumerated() where byte == 0x0A {
                collected.append(Line(start: lineStart, contentLength: position - lineStart))
                lineStart = position + 1
            }
            if lineStart < bytes.count {
                collected.append(Line(start: lineStart, contentLength: bytes.count - lineStart))
            }
            self.lines = collected
            self.wrap = wrap
        }

        func chunkCount(_ line: Line) -> Int {
            LineIndex.chunkCount(forByteLength: line.contentLength, wrap: wrap)
        }

        var rowCount: Int {
            lines.reduce(0) { $0 + chunkCount($1) }
        }

        func visualLines() -> [LineIndex.VisualLine] {
            var result: [LineIndex.VisualLine] = []
            for (number, line) in lines.enumerated() {
                let chunks = chunkCount(line)
                for chunk in 0..<chunks {
                    let start: Int
                    let end: Int
                    if line.contentLength < LineIndex.longLineThreshold {
                        start = line.start
                        end = line.start + line.contentLength
                    } else {
                        start = line.start + chunk * wrap
                        end = min(line.start + line.contentLength, start + wrap)
                    }
                    result.append(LineIndex.VisualLine(
                        documentLine: number, chunkIndex: chunk,
                        chunkCount: chunks, byteRange: start..<end))
                }
            }
            return result
        }

        func row(forByteOffset offset: Int, totalBytes: Int) -> Int {
            var result = 0
            if !lines.isEmpty {
                let clamped = min(max(0, offset), max(0, totalBytes - 1))
                var row = 0
                for line in lines {
                    let lineEnd = line.start + line.contentLength + 1   // incl. newline
                    let isLast = line.start == lines.last?.start
                    if clamped < lineEnd || isLast {
                        let within = max(0, clamped - line.start)
                        var chunk = 0
                        if line.contentLength >= LineIndex.longLineThreshold {
                            chunk = min(chunkCount(line) - 1, within / wrap)
                        }
                        result = row + chunk
                        break
                    }
                    row += chunkCount(line)
                }
            }
            return result
        }

        func row(forLine target: Int) -> Int {
            var result = 0
            if !lines.isEmpty {
                let clamped = max(0, min(target, lines.count - 1))
                result = lines[0..<clamped].reduce(0) { $0 + chunkCount($1) }
            }
            return result
        }
    }

    // MARK: - Harness

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func makeLayout(_ content: [UInt8]) -> EditedLayout {
        let url = TestHelpers.writeTempFile(Data(content))
        temporaryFiles.append(url)
        guard let file = MappedFile(path: url.path) else {
            fatalError("could not map temp file")
        }
        let index = LineIndex()
        index.buildSynchronously(from: file)
        return EditedLayout(file: file, index: index)
    }

    /// Applies one edit to both the layout and the byte model.
    private func edit(
        _ layout: EditedLayout, _ model: inout [UInt8],
        replace range: Range<Int>, with bytes: [UInt8]
    ) {
        var updated = model
        updated.replaceSubrange(range, with: bytes)
        layout.applyReplacement(range, insertedLength: bytes.count) { wanted in
            Array(updated[wanted])
        }
        model = updated
    }

    private func rowDescription(_ line: LineIndex.VisualLine) -> String {
        "line \(line.documentLine) chunk \(line.chunkIndex)/\(line.chunkCount) "
            + "bytes \(line.byteRange.lowerBound)..<\(line.byteRange.upperBound)"
    }

    private func verify(
        _ layout: EditedLayout, against model: [UInt8], wrap: Int = LineIndex.defaultWrapBytes,
        probesUsing generator: inout SeededGenerator, context: String = ""
    ) {
        let naive = NaiveLayout(model, wrap: wrap)
        XCTAssertEqual(layout.length, model.count, "length \(context)")
        XCTAssertEqual(layout.documentLineCount, naive.lines.count, "lines \(context)")
        XCTAssertEqual(layout.visualRowCount, naive.rowCount, "rows \(context)")

        let expected = naive.visualLines().map(rowDescription)
        let actual = layout.visualLines(forRows: 0..<naive.rowCount).map(rowDescription)
        XCTAssertEqual(actual, expected, "visual lines \(context)")

        for _ in 0..<12 where !model.isEmpty {
            let offset = Int.random(in: 0..<model.count, using: &generator)
            XCTAssertEqual(layout.visualRow(forLogicalByteOffset: offset),
                           naive.row(forByteOffset: offset, totalBytes: model.count),
                           "row for byte \(offset) \(context)")
        }
        for _ in 0..<6 where !naive.lines.isEmpty {
            let line = Int.random(in: 0..<naive.lines.count, using: &generator)
            XCTAssertEqual(layout.visualRow(forDocumentLine: line),
                           naive.row(forLine: line),
                           "row for line \(line) \(context)")
        }
    }

    // MARK: - Unit cases

    func testUneditedLayoutMatchesTheIndex() {
        var generator = SeededGenerator(seed: 1)
        let model = Array("alpha\nbeta\ngamma\n".utf8)
        let layout = makeLayout(model)
        XCTAssertFalse(layout.hasSpans)
        verify(layout, against: model, probesUsing: &generator)
    }

    func testEditWithinASingleLine() {
        var generator = SeededGenerator(seed: 2)
        var model = Array("alpha\nbeta\ngamma\n".utf8)
        let layout = makeLayout(model)

        edit(layout, &model, replace: 6..<10, with: Array("BETTER".utf8))

        XCTAssertEqual(String(decoding: model, as: UTF8.self), "alpha\nBETTER\ngamma\n")
        verify(layout, against: model, probesUsing: &generator)
    }

    func testInsertingANewlineSplitsALine() {
        var generator = SeededGenerator(seed: 3)
        var model = Array("alpha\nbeta\ngamma\n".utf8)
        let layout = makeLayout(model)

        edit(layout, &model, replace: 8..<8, with: Array("\nsplit ".utf8))

        XCTAssertEqual(String(decoding: model, as: UTF8.self), "alpha\nbe\nsplit ta\ngamma\n")
        verify(layout, against: model, probesUsing: &generator)
    }

    func testDeletingANewlineJoinsLines() {
        var generator = SeededGenerator(seed: 4)
        var model = Array("alpha\nbeta\ngamma\n".utf8)
        let layout = makeLayout(model)

        edit(layout, &model, replace: 5..<6, with: [])   // the newline after "alpha"

        XCTAssertEqual(String(decoding: model, as: UTF8.self), "alphabeta\ngamma\n")
        verify(layout, against: model, probesUsing: &generator)
    }

    func testEditsAtDocumentStartAndEnd() {
        var generator = SeededGenerator(seed: 5)
        var model = Array("alpha\nbeta".utf8)
        let layout = makeLayout(model)

        edit(layout, &model, replace: 0..<0, with: Array("first\n".utf8))
        verify(layout, against: model, probesUsing: &generator, context: "prepend")

        edit(layout, &model, replace: model.count..<model.count, with: Array(" tail".utf8))
        verify(layout, against: model, probesUsing: &generator, context: "append to line")

        edit(layout, &model, replace: model.count..<model.count, with: Array("\nnew line\n".utf8))
        verify(layout, against: model, probesUsing: &generator, context: "append lines")

        edit(layout, &model, replace: model.count..<model.count, with: Array("post".utf8))
        verify(layout, against: model, probesUsing: &generator, context: "append after newline")
    }

    func testDeletingWholeLines() {
        var generator = SeededGenerator(seed: 6)
        var model = Array("one\ntwo\nthree\nfour\n".utf8)
        let layout = makeLayout(model)

        edit(layout, &model, replace: 4..<14, with: [])   // "two\nthree\n"

        XCTAssertEqual(String(decoding: model, as: UTF8.self), "one\nfour\n")
        verify(layout, against: model, probesUsing: &generator)
    }

    func testSeparateEditsKeepSeparateSpansAndMergeWhenBridged() {
        var generator = SeededGenerator(seed: 7)
        var model = Array((0..<20).map { "line number \($0)\n" }.joined().utf8)
        let layout = makeLayout(model)

        edit(layout, &model, replace: 5..<5, with: Array("AAA".utf8))
        edit(layout, &model, replace: 200..<205, with: Array("BB".utf8))
        XCTAssertEqual(layout.spanCount, 2)
        verify(layout, against: model, probesUsing: &generator, context: "two spans")

        // An edit covering the region between them bridges the spans.
        edit(layout, &model, replace: 10..<190, with: Array("bridge\nacross\n".utf8))
        XCTAssertEqual(layout.spanCount, 1)
        verify(layout, against: model, probesUsing: &generator, context: "merged")
    }

    func testEmptyOriginalDocument() {
        var generator = SeededGenerator(seed: 8)
        var model: [UInt8] = []
        let layout = makeLayout(model)
        verify(layout, against: model, probesUsing: &generator, context: "empty")

        edit(layout, &model, replace: 0..<0, with: Array("fresh\ncontent".utf8))
        verify(layout, against: model, probesUsing: &generator, context: "first insert")
    }

    func testDeletingEverything() {
        var generator = SeededGenerator(seed: 9)
        var model = Array("alpha\nbeta\n".utf8)
        let layout = makeLayout(model)

        edit(layout, &model, replace: 0..<model.count, with: [])
        verify(layout, against: model, probesUsing: &generator, context: "all deleted")

        edit(layout, &model, replace: 0..<0, with: Array("reborn\n".utf8))
        verify(layout, against: model, probesUsing: &generator, context: "after revival")
    }

    func testLongLineEditingAndWrapChanges() {
        var generator = SeededGenerator(seed: 10)
        var model = Array("short\n".utf8)
        model.append(contentsOf: Array(repeating: UInt8(ascii: "x"), count: 3000))
        model.append(contentsOf: Array("\ntail\n".utf8))
        let layout = makeLayout(model)
        verify(layout, against: model, probesUsing: &generator, context: "before edit")

        // Insert inside the long line — the span inherits the wrapping.
        edit(layout, &model, replace: 1500..<1500, with: Array("MIDDLE".utf8))
        verify(layout, against: model, probesUsing: &generator, context: "long line edited")

        // Make a short line long by pasting into it.
        let padding = [UInt8](repeating: UInt8(ascii: "y"), count: 2000)
        edit(layout, &model, replace: 2..<2, with: padding)
        verify(layout, against: model, probesUsing: &generator, context: "line grew long")

        layout.setWrapBytes(100)
        verify(layout, against: model, wrap: 100, probesUsing: &generator, context: "narrow wrap")

        layout.setWrapBytes(500)
        verify(layout, against: model, wrap: 500, probesUsing: &generator, context: "wide wrap")
    }

    // MARK: - Fuzz

    func testFuzzAgainstNaiveLayout() {
        for seed: UInt64 in [11, 77, 4242] {
            var generator = SeededGenerator(seed: seed)
            var model = randomContent(length: 1500, using: &generator)
            let layout = makeLayout(model)
            var wrap = LineIndex.defaultWrapBytes

            for step in 0..<80 {
                let lower = Int.random(in: 0...model.count, using: &generator)
                let upper = Int.random(in: lower...min(model.count, lower + 120), using: &generator)
                let insert = randomContent(
                    length: Int.random(in: 0...80, using: &generator), using: &generator)
                edit(layout, &model, replace: lower..<upper, with: insert)

                if step % 17 == 16 {
                    wrap = Int.random(in: 40...400, using: &generator)
                    layout.setWrapBytes(wrap)
                }
                verify(layout, against: model, wrap: wrap, probesUsing: &generator,
                       context: "seed \(seed) step \(step)")
            }
        }
    }

    /// Fuzz over content containing very long lines, so span chunking and
    /// gap chunking interact.
    func testFuzzWithLongLines() {
        for seed: UInt64 in [13, 900] {
            var generator = SeededGenerator(seed: seed)
            var model: [UInt8] = []
            for _ in 0..<8 {
                let lineLength = Int.random(in: 0...2500, using: &generator)
                model.append(contentsOf: (0..<lineLength).map { _ in
                    UInt8.random(in: 97...122, using: &generator)
                })
                model.append(0x0A)
            }
            let layout = makeLayout(model)

            for step in 0..<40 {
                let lower = Int.random(in: 0...model.count, using: &generator)
                let upper = Int.random(in: lower...min(model.count, lower + 600), using: &generator)
                var insert = randomContent(
                    length: Int.random(in: 0...400, using: &generator), using: &generator)
                if Bool.random(using: &generator) {
                    // Sometimes paste a long unbroken run.
                    insert = (0..<Int.random(in: 1100...2000, using: &generator)).map { _ in
                        UInt8.random(in: 97...122, using: &generator)
                    }
                }
                edit(layout, &model, replace: lower..<upper, with: insert)
                verify(layout, against: model, probesUsing: &generator,
                       context: "seed \(seed) step \(step)")
            }
        }
    }

    /// Random printable bytes with newlines mixed in at roughly 1-in-14.
    private func randomContent(length: Int, using generator: inout SeededGenerator) -> [UInt8] {
        (0..<length).map { _ in
            Int.random(in: 0..<14, using: &generator) == 0
                ? 0x0A
                : UInt8.random(in: 32...126, using: &generator)
        }
    }
}
