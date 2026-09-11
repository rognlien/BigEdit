import AppKit

/// View ▸ Follow File: absorbing appends to a document's file as they land.
extension AppDelegate {

    /// Toggles `tail -f` behaviour for the active document: appends on disk
    /// are indexed incrementally and shown as they arrive, and the view stays
    /// pinned to the end if it was there.
    @objc func toggleFollowing() {
        if let document = activeDocument {
            document.isFollowing.toggle()
            document.view.isFollowing = document.isFollowing
            if document.isFollowing && document.hasDiskChanges {
                absorbGrowth(of: document)       // catch up on what we missed
            }
        }
    }

    /// Absorbs an append to `document`'s file. Anything that is not a plain
    /// append — a smaller file, a new inode, or old bytes that changed — is a
    /// replacement, and gets the full reload instead.
    func absorbGrowth(of document: Document) {
        let path = document.url.path
        switch FileGrowth.detect(path: path, previous: document.file) {
        case .unchanged:
            break
        case .replaced:
            reload(document, from: document.url, preserveScroll: true)
        case .appended:
            let previous = document.file
            if let grown = MappedFile(path: path), FileGrowth.isAppend(previous: previous, grown: grown) {
                document.index.extend(with: grown, previousSize: previous.size) { [weak self, weak document] apply in
                    // Skipped if the document was reloaded or closed meanwhile:
                    // the extension belongs to a mapping nobody shows any more.
                    if let self, let document, document.file === previous {
                        let wasAtEnd = document.view.viewport.isScrolledToEnd
                        apply()
                        document.adoptGrownFile(grown)
                        document.hasDiskChanges = false
                        document.view.adoptGrownFile(grown, index: document.index, pinToEnd: wasAtEnd)
                        self.documentDidUpdate(document)
                    }
                }
            } else {
                reload(document, from: document.url, preserveScroll: true)
            }
        }
    }
}
