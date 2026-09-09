import XCTest
@testable import BigEditHelperKit

/// The helper runs as root, so what it agrees to do is the whole security
/// story. These tests cover the decision and the file work against real
/// directories — nothing privileged happens, because the permitted list is
/// injectable.
final class LinkInstallationTests: XCTestCase {

    private var root: URL!
    private var permittedDirectory: URL!
    private var toolURL: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigEditHelperTest-\(UUID().uuidString)")
        permittedDirectory = root.appendingPathComponent("bin")
        try? FileManager.default.createDirectory(
            at: permittedDirectory, withIntermediateDirectories: true)

        toolURL = root.appendingPathComponent("bigedit")
        FileManager.default.createFile(atPath: toolURL.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o755])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var permitted: [String] { [permittedDirectory.standardizedFileURL.path] }

    // MARK: - Doing the work

    func testCreatesTheLink() throws {
        let destination = permittedDirectory.appendingPathComponent("bigedit")
        try LinkInstallation.install(toolPath: toolURL.path,
                                     destinationPath: destination.path,
                                     permittedDirectories: permitted)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: destination.path)
        XCTAssertEqual(URL(fileURLWithPath: target).standardizedFileURL,
                       toolURL.standardizedFileURL)
    }

    func testReplacesAnEarlierLink() throws {
        let destination = permittedDirectory.appendingPathComponent("bigedit")
        let stale = root.appendingPathComponent("old-bigedit")
        FileManager.default.createFile(atPath: stale.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: stale)

        try LinkInstallation.install(toolPath: toolURL.path,
                                     destinationPath: destination.path,
                                     permittedDirectories: permitted)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: destination.path)
        XCTAssertEqual(URL(fileURLWithPath: target).standardizedFileURL,
                       toolURL.standardizedFileURL)
    }

    func testReplacesARegularFile() throws {
        let destination = permittedDirectory.appendingPathComponent("bigedit")
        FileManager.default.createFile(atPath: destination.path, contents: Data("junk".utf8))
        try LinkInstallation.install(toolPath: toolURL.path,
                                     destinationPath: destination.path,
                                     permittedDirectories: permitted)
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.path))
    }

    // MARK: - What it refuses

    func testRefusesADestinationOutsideThePermittedDirectories() {
        let destination = root.appendingPathComponent("elsewhere/bigedit")
        XCTAssertThrowsError(try LinkInstallation.install(
            toolPath: toolURL.path,
            destinationPath: destination.path,
            permittedDirectories: permitted)) { error in
            guard case .destinationNotPermitted = error as? LinkInstallation.Refusal else {
                return XCTFail("expected destinationNotPermitted, got \(error)")
            }
        }
    }

    func testRefusesTraversalOutOfAPermittedDirectory() {
        let destination = permittedDirectory.path + "/../escaped"
        XCTAssertThrowsError(try LinkInstallation.install(
            toolPath: toolURL.path,
            destinationPath: destination,
            permittedDirectories: permitted)) { error in
            guard case .destinationNotPermitted = error as? LinkInstallation.Refusal else {
                return XCTFail("expected destinationNotPermitted, got \(error)")
            }
        }
    }

    func testRefusesASubdirectoryOfAPermittedDirectory() {
        let destination = permittedDirectory.appendingPathComponent("nested/bigedit")
        XCTAssertThrowsError(try LinkInstallation.install(
            toolPath: toolURL.path,
            destinationPath: destination.path,
            permittedDirectories: permitted))
    }

    func testRefusesAToolThatIsNotThere() {
        let destination = permittedDirectory.appendingPathComponent("bigedit")
        XCTAssertThrowsError(try LinkInstallation.install(
            toolPath: root.appendingPathComponent("missing").path,
            destinationPath: destination.path,
            permittedDirectories: permitted)) { error in
            guard case .toolMissing = error as? LinkInstallation.Refusal else {
                return XCTFail("expected toolMissing, got \(error)")
            }
        }
    }

    func testRefusesAToolThatIsNotExecutable() {
        let plain = root.appendingPathComponent("not-executable")
        FileManager.default.createFile(atPath: plain.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o644])
        let destination = permittedDirectory.appendingPathComponent("bigedit")
        XCTAssertThrowsError(try LinkInstallation.install(
            toolPath: plain.path,
            destinationPath: destination.path,
            permittedDirectories: permitted))
    }

    // MARK: - The shipped destination list

    func testTheRealListAcceptsUsrLocalBin() {
        XCTAssertTrue(HelperService.isPermittedDestination("/usr/local/bin/bigedit"))
    }

    func testTheRealListRefusesSomewhereDangerous() {
        XCTAssertFalse(HelperService.isPermittedDestination("/usr/bin/sudo"))
        XCTAssertFalse(HelperService.isPermittedDestination("/etc/sudoers"))
        XCTAssertFalse(HelperService.isPermittedDestination("/usr/local/bin/../../../etc/passwd"))
    }
}
