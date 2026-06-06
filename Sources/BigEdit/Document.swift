import AppKit

/// One open file. Each document owns its own `DocumentView`, so per-document
/// state — scroll position, search, the deferred-edit rule, the info pane — is
/// preserved for free when the user switches between documents.
final class Document {

    private(set) var url: URL
    private(set) var fileName: String
    private(set) var file: MappedFile
    private(set) var index: LineIndex
    let view: DocumentView

    /// Watches the file on disk; owned by the document so it stops on close.
    var watcher: FileWatcher?

    /// True when the file changed on disk since it was loaded.
    var hasDiskChanges = false

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    init(url: URL, file: MappedFile, index: LineIndex, view: DocumentView) {
        self.url = url
        self.fileName = url.lastPathComponent
        self.file = file
        self.index = index
        self.view = view
    }

    /// Re-points an existing document at `newURL` after a save, swapping in a
    /// freshly mapped file and index. The caller restarts indexing and reloads
    /// the view.
    func reload(url newURL: URL, file newFile: MappedFile, index newIndex: LineIndex) {
        url = newURL
        fileName = newURL.lastPathComponent
        file = newFile
        index = newIndex
    }

    /// True while the document has an unsaved deferred-edit rule.
    var isEdited: Bool {
        view.isEdited
    }

    /// Human-readable file size, e.g. "1.2 MB".
    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
    }

    /// The sidebar's secondary line: size and line count, with an indexing
    /// hint until the line index finishes.
    var secondaryLine: String {
        if hasDiskChanges {
            return "\(displaySize) · changed on disk"
        }
        if index.isComplete {
            let lines = Document.numberFormatter.string(from: NSNumber(value: index.count))
                ?? "\(index.count)"
            return "\(displaySize) · \(lines) lines"
        }
        return "\(displaySize) · indexing…"
    }
}
