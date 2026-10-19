import AppKit

/// One open file. Each document owns its own `DocumentView`, so per-document
/// state — scroll position, search, the deferred-edit rule, the info pane — is
/// preserved for free when the user switches between documents.
final class Document {

    private(set) var url: URL
    private(set) var file: MappedFile
    private(set) var index: LineIndex
    let view: DocumentView

    /// Set while the document is untitled — its file a placeholder that has
    /// never been saved anywhere — to the number it is shown with.
    var untitledNumber: Int?

    /// Watches the file on disk; owned by the document so it stops on close.
    var watcher: FileWatcher?

    /// True when the file changed on disk since it was loaded.
    var hasDiskChanges = false

    /// Whether appends on disk are absorbed as they happen, the way `tail -f`
    /// follows a log. Only meaningful while the document has no edits.
    var isFollowing = false

    /// Detected encoding / line endings, for the status bar.
    private(set) var format: FileFormat

    /// A scroll row to apply once indexing has produced enough rows (used when
    /// restoring a previous session). Cleared after it's applied.
    var pendingScrollRow: Double?

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    init(url: URL, file: MappedFile, index: LineIndex, view: DocumentView) {
        self.url = url
        self.file = file
        self.index = index
        self.view = view
        self.format = FileFormat(scanning: file)
    }

    /// Re-points an existing document at `newURL` after a save, swapping in a
    /// freshly mapped file and index. The caller restarts indexing and reloads
    /// the view. With `keepingEncoding`, the file is one just written from
    /// this document, so it is still in the encoding the document was in.
    func reload(url newURL: URL, file newFile: MappedFile, index newIndex: LineIndex,
                keepingEncoding: Bool = false) {
        url = newURL
        file = newFile
        index = newIndex
        let scanned = FileFormat(scanning: newFile)
        format = keepingEncoding ? scanned.keepingSingleByteEncoding(of: format) : scanned
    }

    /// Swaps in a larger mapping of the same file after an append. The index
    /// has already been extended to cover it, so it is kept.
    func adoptGrownFile(_ grown: MappedFile) {
        file = grown
        format = FileFormat(scanning: grown)
    }

    /// The name shown for the document: its file's, or "Untitled" and a
    /// number while it is untitled.
    var fileName: String {
        untitledNumber.map(UntitledDocuments.name(numbered:)) ?? url.lastPathComponent
    }

    var isUntitled: Bool {
        untitledNumber != nil
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
