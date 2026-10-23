import XCTest
@testable import BigEdit

/// Opening a file that is already open finds it however the path is spelled.
final class FileIdentityTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func makeFile() -> URL {
        let url = TestHelpers.writeTempFile("text\n")
        temporaryFiles.append(url)
        return url
    }

    private func sibling(of url: URL, named name: String) -> URL {
        let sibling = url.deletingLastPathComponent().appendingPathComponent(name)
        temporaryFiles.append(sibling)
        return sibling
    }

    func testTheSamePathIsTheSameFile() {
        let url = makeFile()

        XCTAssertEqual(FileIdentity.firstIndex(of: url, in: [makeFile(), url]), 1)
    }

    func testAnotherFileIsNotFound() {
        XCTAssertNil(FileIdentity.firstIndex(of: makeFile(), in: [makeFile()]))
    }

    func testASymbolicLinkFindsItsTarget() throws {
        let url = makeFile()
        let link = sibling(of: url, named: "BigEditLink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)

        XCTAssertEqual(FileIdentity.firstIndex(of: link, in: [url]), 0)
    }

    func testAHardLinkFindsTheSameFile() throws {
        let url = makeFile()
        let link = sibling(of: url, named: "BigEditHardLink-\(UUID().uuidString)")
        try FileManager.default.linkItem(at: url, to: link)

        XCTAssertEqual(FileIdentity.firstIndex(of: link, in: [url]), 0)
    }

    func testAPathWithADotSegmentFindsTheSameFile() {
        let url = makeFile()
        let dotted = url.deletingLastPathComponent()
            .appendingPathComponent(".")
            .appendingPathComponent(url.lastPathComponent)

        XCTAssertEqual(FileIdentity.firstIndex(of: dotted, in: [url]), 0)
    }

    func testAMissingFileIsNotFound() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        XCTAssertNil(FileIdentity.firstIndex(of: missing, in: [missing]))
    }
}
