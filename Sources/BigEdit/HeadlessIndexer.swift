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
}
