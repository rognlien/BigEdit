import XCTest
@testable import BigEdit

/// A watcher holds a descriptor on the file it watches. Once the watcher is
/// gone that descriptor must be closed too, or a deleted file's disk space is
/// never reclaimed.
final class FileWatcherTests: XCTestCase {

    private var url: URL!

    override func setUp() {
        super.setUp()
        url = TestHelpers.writeTempFile("contents\n")
    }

    override func tearDown() {
        TestHelpers.remove(url)
        super.tearDown()
    }

    func testCancelledWatcherClosesItsDescriptorOnceReleased() {
        var watcher = FileWatcher(path: url.path) {}
        XCTAssertTrue(isOpen(url))
        watcher?.cancel()
        watcher = nil
        drainMainQueue()
        XCTAssertFalse(isOpen(url))
    }

    func testReleasedWatcherClosesItsDescriptor() {
        var watcher = FileWatcher(path: url.path) {}
        XCTAssertNotNil(watcher)
        watcher = nil
        drainMainQueue()
        XCTAssertFalse(isOpen(url))
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    /// Whether any descriptor in this process refers to the file at `url`.
    private func isOpen(_ url: URL) -> Bool {
        let target = url.resolvingSymlinksInPath().path
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return (0..<getdtablesize()).contains { descriptor in
            fcntl(descriptor, F_GETPATH, &buffer) != -1
                && URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path == target
        }
    }
}
