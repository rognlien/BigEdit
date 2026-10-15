import AppKit

/// Opening files that live in iCloud Drive but are not downloaded yet.
extension AppDelegate {

    /// Opens each URL, first fetching any that iCloud has not downloaded —
    /// a placeholder would otherwise open as an empty file.
    func openDocuments(at urls: [URL]) {
        let resolved = urls.map(UbiquitousFile.resolvedURL(for:))
        let pending = resolved.filter(UbiquitousFile.needsDownload)
        if pending.isEmpty {
            openReadyDocuments(at: resolved)
        } else {
            download(pending) { [weak self] ready in
                let failed = Set(pending).subtracting(ready)
                self?.openReadyDocuments(at: resolved.filter { !failed.contains($0) })
            }
        }
    }

    /// Starts the downloads and shows a cancellable sheet until every file
    /// has arrived, then hands back the ones that did.
    private func download(_ urls: [URL], completion: @escaping ([URL]) -> Void) {
        var started: [URL] = []
        for url in urls {
            do {
                try UbiquitousFile.startDownload(url)
                started.append(url)
            } catch {
                presentSaveError("Could not start downloading \(url.lastPathComponent) from iCloud: "
                                 + error.localizedDescription)
            }
        }
        guard !started.isEmpty else {
            completion([])
            return
        }
        let names = started.count == 1 ? started[0].lastPathComponent : "\(started.count) files"
        let sheet = SaveProgressSheet(title: "Downloading \(names) from iCloud…")
        sheet.setIndeterminate("Waiting for iCloud Drive")
        var cancelled = false
        sheet.onCancel = { cancelled = true }
        saveProgressSheet = sheet
        window.beginSheet(sheet.window) { _ in }

        let begun = Date()
        var timer: Timer?
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            let arrived = started.filter(UbiquitousFile.isDownloaded)
            let waiting = started.count - arrived.count
            if waiting > 0 && !cancelled {
                let elapsed = Int(Date().timeIntervalSince(begun))
                sheet.setIndeterminate(waiting == 1 ? "Waiting for iCloud Drive (\(elapsed) s)"
                                                    : "\(waiting) files still to come (\(elapsed) s)")
                return
            }
            timer?.invalidate()
            timer = nil
            self?.window.endSheet(sheet.window)
            self?.saveProgressSheet = nil
            completion(cancelled ? arrived : started)
        }
    }
}
