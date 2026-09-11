import Foundation

/// Watches a single file path for on-disk changes and reports them on the main
/// queue. Bursts of events are coalesced, and the watch is re-established after
/// an atomic replace (rename/delete) — which is how most editors save.
final class FileWatcher {

    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var notifyPending = false

    init?(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        if !start() {
            return nil
        }
    }

    deinit {
        cancel()
    }

    @discardableResult
    private func start() -> Bool {
        let descriptor = open(path, O_EVTONLY)
        if descriptor < 0 {
            return false
        }
        fileDescriptor = descriptor
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .link, .revoke],
            queue: .main
        )
        newSource.setEventHandler { [weak self, weak newSource] in
            self?.handle(newSource?.data ?? [])
        }
        newSource.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
            }
            self?.fileDescriptor = -1
        }
        source = newSource
        newSource.resume()
        return true
    }

    private func handle(_ flags: DispatchSource.FileSystemEvent) {
        // An atomic save replaces the file (delete/rename), invalidating our
        // descriptor — re-open the path so we keep watching the new inode.
        if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
            restart()
        }
        coalesceNotify()
    }

    private func restart() {
        source?.cancel()
        source = nil
        // The replacement may not exist for a brief moment; retry shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            if self?.source == nil {
                self?.start()
            }
        }
    }

    private func coalesceNotify() {
        if notifyPending {
            return
        }
        notifyPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.notifyPending = false
            self?.onChange()
        }
    }

    func cancel() {
        source?.cancel()
        source = nil
    }
}
