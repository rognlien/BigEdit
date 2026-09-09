import Foundation

/// A headless mode for testing the line indexer without the GUI.
///
/// Run with `swift run BigEdit --index <path>` to map a file, index it on the
/// calling thread, and print the line count and elapsed time.
enum HeadlessIndexer {

    static func run(path: String) -> Int32 {
        var exitCode: Int32 = 0

        if let file = MappedFile(path: path) {
            let index = LineIndex()
            let start = Date()
            index.buildSynchronously(from: file)
            let elapsed = Date().timeIntervalSince(start)

            let bytes = ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
            print("file:    \(path)")
            print("size:    \(bytes) (\(file.size) bytes)")
            print("lines:   \(index.count)")
            print("rows:    \(index.visualRowCount)  (visual rows at default wrap)")
            print(String(format: "indexed: %.3f s", elapsed))
        } else {
            FileHandle.standardError.write(Data("BigEdit: cannot open \(path)\n".utf8))
            exitCode = 1
        }

        return exitCode
    }

    /// Runs a literal search and prints the match count and first few offsets.
    /// Invoked by `swift run BigEdit --search <pattern> <path>`.
    static func search(pattern: String, path: String) -> Int32 {
        var exitCode: Int32 = 0

        if let file = MappedFile(path: path), let scan = SearchScan(query: pattern) {
            let start = Date()
            scan.runSynchronously(in: file)
            let elapsed = Date().timeIntervalSince(start)

            print("file:    \(path)")
            print("query:   \"\(pattern)\" (\(scan.queryByteLength) bytes)")
            print("matches: \(scan.matchCount)\(scan.isTruncated ? " (capped)" : "")")
            let sampleCount = min(5, scan.matchCount)
            for index in 0..<sampleCount {
                print("  match[\(index)] at byte \(scan.matchOffset(at: index) ?? -1)")
            }
            print(String(format: "scanned: %.3f s", elapsed))
        } else {
            FileHandle.standardError.write(Data("BigEdit: cannot search \(path)\n".utf8))
            exitCode = 1
        }

        return exitCode
    }

    /// Applies a deferred replacement rule and prints the edited preview of the
    /// first rows — the same transformation the viewport renders.
    /// Invoked by `swift run BigEdit --preview <pattern> <replacement> <path>`.
    static func preview(pattern: String, replacement: String, path: String) -> Int32 {
        var exitCode: Int32 = 0

        if let file = MappedFile(path: path),
           let rule = ReplacementRule(pattern: pattern, replacement: replacement) {
            let index = LineIndex()
            index.buildSynchronously(from: file)
            let editModel = EditModel()
            editModel.setRuleSynchronously(rule, file: file)

            print("file:    \(path)")
            print("rule:    \"\(pattern)\" -> \"\(replacement)\"")
            print("matches: \(editModel.matches?.matchCount ?? 0)")
            print("--- first rows (edited preview) ---")

            let rowCount = min(20, index.visualRowCount)
            let rows = index.visualLines(forRows: 0..<rowCount, file: file)
            let buffer = file.buffer
            for visualLine in rows {
                let bytes = editModel.transformedBytes(forOriginalRange: visualLine.byteRange, in: buffer)
                print("\(visualLine.documentLine + 1): \(String(decoding: bytes, as: UTF8.self))")
            }
        } else {
            FileHandle.standardError.write(
                Data("BigEdit: cannot preview (bad file or invalid rule)\n".utf8)
            )
            exitCode = 1
        }

        return exitCode
    }

    /// Runs the streaming save: writes `<input>` to `<output>` with every
    /// occurrence of `pattern` replaced by `replacement`.
    /// Invoked by `swift run BigEdit --replace <pattern> <replacement> <in> <out>`.
    static func replace(
        pattern: String,
        replacement: String,
        inputPath: String,
        outputPath: String
    ) -> Int32 {
        var exitCode: Int32 = 0

        if let file = MappedFile(path: inputPath),
           let rule = ReplacementRule(pattern: pattern, replacement: replacement) {
            let destination = URL(fileURLWithPath: outputPath)
            let start = Date()
            let result = FileWriter.saveSynchronously(file: file, rule: rule, to: destination)
            let elapsed = Date().timeIntervalSince(start)

            switch result {
            case .success:
                let outSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size]) as? Int ?? -1
                print("input:   \(inputPath) (\(file.size) bytes)")
                print("output:  \(outputPath) (\(outSize) bytes)")
                print("rule:    \"\(pattern)\" -> \"\(replacement)\"")
                print(String(format: "wrote:   %.3f s", elapsed))
            case .failure(let error):
                FileHandle.standardError.write(
                    Data("BigEdit: save failed: \(error.localizedDescription)\n".utf8)
                )
                exitCode = 1
            }
        } else {
            FileHandle.standardError.write(
                Data("BigEdit: cannot replace (bad input or invalid rule)\n".utf8)
            )
            exitCode = 1
        }

        return exitCode
    }

    /// Counts lines, words, and characters of a file the same way the info
    /// pane does — for cross-checking against `wc -lwm`.
    /// Invoked by `swift run BigEdit --stats <path>`.
    static func stats(path: String) -> Int32 {
        var exitCode: Int32 = 0

        if let file = MappedFile(path: path) {
            let index = LineIndex()
            let stats = StatisticsScan()
            index.buildSynchronously(from: file)
            stats.runSynchronously(in: file)

            print("file:    \(path)")
            print("size:    \(file.size) bytes")
            print("lines:   \(index.count)")
            print("words:   \(stats.wordCount)")
            print("chars:   \(stats.characterCount)")
        } else {
            FileHandle.standardError.write(
                Data("BigEdit: cannot stat \(path)\n".utf8)
            )
            exitCode = 1
        }

        return exitCode
    }

    /// End-to-end smoke test of the editing stack, driven by
    /// `scripts/verify-editing.sh`: applies a deterministic sequence of edits
    /// through the piece table, walks the whole undo history back and forward
    /// again, and streams the result to `outputPath`. The script compares the
    /// output against an independently computed expected file and watches
    /// peak memory. Invoked by `swift run BigEdit --edit-smoke <in> <out>`.
    /// Prints the detected CSV dialect and the first rows exactly as the
    /// viewport would draw them in CSV mode, so the alignment can be checked
    /// against an independent CSV reader without opening the GUI.
    static func csv(path: String, rowLimit: Int) -> Int32 {
        var status: Int32 = 1
        if let file = MappedFile(path: path) {
            if let dialect = CSVDialect.detect(in: file) {
                let columnLayout = CSVColumnLayout.measure(file: file, dialect: dialect)
                let delimiterName = dialect.delimiter == "\t" ? "\\t" : String(dialect.delimiter)
                print("delimiter: \(delimiterName)")
                print("quote: \(dialect.quote.map(String.init) ?? "none")")
                print("header row: \(dialect.hasHeaderRow)")
                print("columns: \(columnLayout.columnWidths)")
                printAlignedRows(of: file, dialect: dialect,
                                 columnLayout: columnLayout, rowLimit: rowLimit)
                status = 0
            } else {
                print("not delimited data")
            }
        } else {
            FileHandle.standardError.write(Data("error: cannot open \(path)\n".utf8))
        }
        return status
    }

    /// Writes the first `rowLimit` rows of `file`, padded into columns.
    private static func printAlignedRows(of file: MappedFile, dialect: CSVDialect,
                                         columnLayout: CSVColumnLayout, rowLimit: Int) {
        let buffer = file.buffer
        let sampleLimit = min(buffer.count, 1024 * 1024)
        let bytes = Array(UnsafeRawBufferPointer(rebasing: buffer[0..<sampleLimit]))
        let text = String(decoding: bytes, as: UTF8.self)
        var printed = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if printed >= rowLimit {
                break
            }
            let withoutReturn = line.hasSuffix("\r") ? line.dropLast() : line
            if withoutReturn.isEmpty {
                continue
            }
            let fields = CSVParser.fields(in: String(withoutReturn), dialect: dialect)
            print(columnLayout.alignedRow(fields))
            printed += 1
        }
    }

    /// Applies a line operation to a file and writes the result, so the
    /// transformations can be checked against sort, uniq, grep and sed.
    ///
    /// Usage: --process-lines <operation> <in> <out> [pattern] [replacement]
    /// where operation is dedupe, remove, keep, sort, natural-sort or regex.
    static func processLines(operation: String, inputPath: String, outputPath: String,
                             pattern: String?, replacement: String?) -> Int32 {
        var status: Int32 = 1
        guard let contents = try? String(contentsOfFile: inputPath, encoding: .utf8) else {
            FileHandle.standardError.write(Data("error: cannot read \(inputPath)\n".utf8))
            return status
        }
        // A trailing newline means a final empty component, which is not a line.
        var lines = contents.components(separatedBy: "\n")
        let endedWithNewline = lines.last == ""
        if endedWithNewline {
            lines.removeLast()
        }

        guard let lineOperation = parseOperation(operation, pattern: pattern,
                                                 replacement: replacement) else {
            FileHandle.standardError.write(Data("error: unknown operation \(operation)\n".utf8))
            return status
        }

        do {
            if let processed = try LineProcessor.apply(lineOperation, to: lines) {
                var output = processed.joined(separator: "\n")
                if endedWithNewline && !processed.isEmpty {
                    output += "\n"
                }
                try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
                print("\(lines.count) lines in, \(processed.count) out")
                status = 0
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        }
        return status
    }

    private static func parseOperation(_ name: String, pattern: String?,
                                       replacement: String?) -> LineOperation? {
        var operation: LineOperation?
        switch name {
        case "dedupe":
            operation = .removeDuplicateLines
        case "remove":
            operation = .removeLinesContaining(pattern: pattern ?? "", caseSensitive: true)
        case "keep":
            operation = .keepLinesContaining(pattern: pattern ?? "", caseSensitive: true)
        case "sort":
            operation = .sortLines(natural: false, keyPattern: pattern)
        case "natural-sort":
            operation = .sortLines(natural: true, keyPattern: pattern)
        case "regex":
            operation = .replaceWithinLines(pattern: pattern ?? "", replacement: replacement ?? "")
        default:
            operation = nil
        }
        return operation
    }

    static func editSmoke(inputPath: String, outputPath: String) -> Int32 {
        var exitCode: Int32 = 0

        if let file = MappedFile(path: inputPath) {
            let index = LineIndex()
            index.buildSynchronously(from: file)
            let document = EditedDocument(file: file, editModel: EditModel(),
                                          lineIndex: index)
            let start = Date()

            // Sixteen scattered insertions, applied at descending offsets so
            // each logical offset equals its original offset; then a deletion
            // at the head and an appended tail. verify-editing.sh replays the
            // identical sequence in Python to produce the expected file.
            let step = file.size / 17
            for marker in stride(from: 16, through: 1, by: -1) {
                let offset = marker * step
                document.replace(offset..<offset, with: Array("<<EDIT \(marker)>>\n".utf8))
            }
            if document.length >= 10 {
                document.replace(0..<10, with: [])
            }
            document.replace(document.length..<document.length,
                             with: Array("<<END>>\n".utf8))
            let editedLength = document.length
            let editedLines = document.layout.documentLineCount

            // The full history must walk back to the original and forward
            // to the edited state again.
            while document.undoStack.canUndo {
                _ = document.undoStack.undo(in: document)
            }
            if document.length != file.size {
                FileHandle.standardError.write(
                    Data("BigEdit: undo walk did not restore the original length\n".utf8))
                exitCode = 1
            }
            while document.undoStack.canRedo {
                _ = document.undoStack.redo(in: document)
            }
            if document.length != editedLength {
                FileHandle.standardError.write(
                    Data("BigEdit: redo walk did not restore the edits\n".utf8))
                exitCode = 1
            }

            let editElapsed = Date().timeIntervalSince(start)
            let saveStart = Date()
            let result = FileWriter.saveSynchronously(
                document: document, to: URL(fileURLWithPath: outputPath))
            if case .failure(let error) = result {
                FileHandle.standardError.write(
                    Data("BigEdit: save failed: \(error.localizedDescription)\n".utf8))
                exitCode = 1
            }

            print("file:    \(inputPath)")
            print("size:    \(file.size) bytes → \(editedLength) bytes edited")
            print("lines:   \(index.count) → \(editedLines) edited")
            print(String(format: "edits:   %.3f s (including full undo/redo walk)", editElapsed))
            print(String(format: "saved:   %.3f s", Date().timeIntervalSince(saveStart)))
        } else {
            FileHandle.standardError.write(
                Data("BigEdit: cannot open \(inputPath)\n".utf8)
            )
            exitCode = 1
        }

        return exitCode
    }
}
