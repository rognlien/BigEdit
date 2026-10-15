import XCTest
@testable import BigEdit

/// iCloud placeholders are recognised and the Drive folder is found only
/// when it exists.
final class UbiquitousFileTests: XCTestCase {

    func testPlaceholderNamesResolveToTheRealFile() {
        let placeholder = URL(fileURLWithPath: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/.notes.txt.icloud")
        XCTAssertEqual(UbiquitousFile.resolvedURL(for: placeholder).lastPathComponent, "notes.txt")
    }

    func testOrdinaryNamesAreLeftAlone() {
        for name in ["notes.txt", ".hidden", "x.icloud", ".icloud"] {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            XCTAssertEqual(UbiquitousFile.resolvedURL(for: url), url, name)
        }
    }

    func testALocalFileNeedsNoDownload() {
        let url = TestHelpers.writeTempFile("local")
        defer { TestHelpers.remove(url) }
        XCTAssertFalse(UbiquitousFile.needsDownload(url))
        XCTAssertTrue(UbiquitousFile.isDownloaded(url))
    }

    func testTheDriveFolderIsFoundOnlyWhenItExists() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigEditHome-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(UbiquitousFile.iCloudDriveURL(home: home))
        XCTAssertNil(PatternLibrary.iCloudFileURL(home: home))

        let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        XCTAssertEqual(UbiquitousFile.iCloudDriveURL(home: home), drive)
        XCTAssertEqual(PatternLibrary.iCloudFileURL(home: home)?.lastPathComponent, PatternLibrary.fileName)
        XCTAssertEqual(PatternLibrary.iCloudFileURL(home: home)?.deletingLastPathComponent().lastPathComponent,
                       "BigEdit")
    }
}
