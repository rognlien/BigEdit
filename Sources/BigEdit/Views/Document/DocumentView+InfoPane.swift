import AppKit

/// The info pane and the statistics scan that fills it.
extension DocumentView {

    var isInfoPaneVisible: Bool {
        infoPaneVisible
    }

    func toggleInfoPane() {
        if infoPaneVisible {
            hideInfoPane()
        } else {
            showInfoPane()
        }
    }

    func showInfoPane() {
        infoPaneVisible = true
        if statisticsScan == nil, let document = viewport.document {
            startStatisticsScan(in: document)
        }
        layoutComponents()
        updateInfoPane()
    }

    func hideInfoPane() {
        infoPaneVisible = false
        layoutComponents()
    }

    /// Kicks off the background word / character count for `file`.
    func startStatisticsScan(in document: EditedDocument) {
        let scan = StatisticsScan(encoding: textEncoding)
        statisticsScan = scan
        scan.start(in: document) { [weak self, weak scan] in
            if let self, let scan, self.statisticsScan === scan {
                self.updateInfoPane()
            }
        }
    }

    /// Refreshes the info pane fields from the file, the index, and the
    /// stats scan.
    func updateInfoPane() {
        guard infoPaneVisible || statisticsScan != nil else {
            return
        }
        if let file = viewport.file {
            let url = URL(fileURLWithPath: file.path)
            infoPane.setName(url.lastPathComponent)
            infoPane.setPath(file.path)
            infoPane.setType(DocumentView.fileTypeDescription(for: file))
            if let document = viewport.document, document.hasEdits {
                infoPane.setSize("\(formatSize(document.length)) (edited)")
            } else {
                infoPane.setSize(formatSize(file.size))
            }

            if let document = viewport.document {
                let lineCount = document.layout.documentLineCount
                let count = numberFormatter.string(from: NSNumber(value: lineCount)) ?? "\(lineCount)"
                let suffix = document.lineIndex.isComplete ? "" : " (indexing…)"
                infoPane.setLines("\(count)\(suffix)")
            } else {
                infoPane.setLines("—")
            }

            if let stats = statisticsScan {
                let words = numberFormatter.string(from: NSNumber(value: stats.wordCount)) ?? "\(stats.wordCount)"
                let chars = numberFormatter.string(from: NSNumber(value: stats.characterCount)) ?? "\(stats.characterCount)"
                let suffix = stats.isComplete ? "" : " (\(Int(stats.progress * 100))%)"
                infoPane.setWords("\(words)\(suffix)")
                infoPane.setCharacters("\(chars)\(suffix)")
            } else {
                infoPane.setWords("—")
                infoPane.setCharacters("—")
            }
        } else {
            infoPane.clear()
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        let humanReadable = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let exact = numberFormatter.string(from: NSNumber(value: bytes)) ?? "\(bytes)"
        return "\(humanReadable) (\(exact) bytes)"
    }

    private static func fileTypeDescription(for file: MappedFile) -> String {
        let fileExtension = (file.path as NSString).pathExtension
        if fileExtension.isEmpty {
            return "Plain text"
        }
        return fileExtension.uppercased()
    }
}
