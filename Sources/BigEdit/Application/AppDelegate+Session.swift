import AppKit

/// Opening from URLs, restoring the last session, and the recent-documents
/// list (kept by the app, since `noteNewRecentDocumentURL` does not persist
/// for a non-document app).
extension AppDelegate {

    func application(_ sender: NSApplication, open urls: [URL]) {
        if !urls.isEmpty {
            didOpenFromURL = true
            openDocuments(at: urls)
        }
    }

    /// Reopens the set of documents from the last session, selecting the one
    /// that was active. Falls back to the single legacy last-file key.
    func restoreSessionIfNeeded() {
        if didOpenFromURL || !documents.isEmpty {
            return
        }
        let defaults = UserDefaults.standard
        var paths = defaults.stringArray(forKey: AppDelegate.openDocumentsDefaultsKey) ?? []
        if paths.isEmpty, let legacy = defaults.string(forKey: AppDelegate.lastFilePathDefaultsKey) {
            paths = [legacy]
        }
        let scrolls = defaults.array(forKey: AppDelegate.scrollRowsDefaultsKey) as? [Double] ?? []
        let savedActive = defaults.integer(forKey: AppDelegate.activeIndexDefaultsKey)
        let activePath = paths.indices.contains(savedActive) ? paths[savedActive] : nil

        // Keep each surviving path with its saved scroll position.
        var restorable: [(path: String, scroll: Double)] = []
        for (i, path) in paths.enumerated() where FileManager.default.fileExists(atPath: path) {
            restorable.append((path, i < scrolls.count ? scrolls[i] : 0))
        }
        if restorable.isEmpty {
            return
        }

        openDocuments(at: restorable.map { URL(fileURLWithPath: $0.path) })
        for (i, item) in restorable.enumerated() where documents.indices.contains(i) {
            if item.scroll > 0 {
                documents[i].pendingScrollRow = item.scroll
            }
        }
        if let activePath, let index = restorable.firstIndex(where: { $0.path == activePath }) {
            selectDocument(at: index)
        }
    }

    /// Persists the open document paths, scroll positions, and active index.
    func persistSession() {
        let defaults = UserDefaults.standard
        defaults.set(documents.map { $0.url.path }, forKey: AppDelegate.openDocumentsDefaultsKey)
        defaults.set(documents.map { $0.view.viewport.scrollRow },
                     forKey: AppDelegate.scrollRowsDefaultsKey)
        defaults.set(activeIndex ?? 0, forKey: AppDelegate.activeIndexDefaultsKey)
        defaults.set(documents.last?.url.path, forKey: AppDelegate.lastFilePathDefaultsKey)
        // Flush so an abrupt termination (e.g. Sparkle's update relaunch) keeps it.
        defaults.synchronize()
    }

    // MARK: - Recent documents

    func addRecentDocument(_ url: URL) {
        let defaults = UserDefaults.standard
        var paths = defaults.stringArray(forKey: AppDelegate.recentDocumentsDefaultsKey) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > AppDelegate.maxRecentDocuments {
            paths = Array(paths.prefix(AppDelegate.maxRecentDocuments))
        }
        defaults.set(paths, forKey: AppDelegate.recentDocumentsDefaultsKey)
        defaults.synchronize()
        // Also feed the system list (Dock menu / Recent Items), best-effort.
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func recentDocumentURLs() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: AppDelegate.recentDocumentsDefaultsKey) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }
}
