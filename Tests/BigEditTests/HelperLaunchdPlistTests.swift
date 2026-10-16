import XCTest
@testable import BigEditHelperKit

/// SMAppService finds the daemon by its plist and the app reaches it by Mach
/// service name, so the plist and HelperService have to agree.
final class HelperLaunchdPlistTests: XCTestCase {

    private var plist: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BigEditHelper/Launchd.plist")
        let data = try Data(contentsOf: url)
        plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testLabelIsTheMachServiceName() {
        XCTAssertEqual(plist["Label"] as? String, HelperService.machServiceName)
    }

    func testMachServiceIsAdvertised() {
        let services = plist["MachServices"] as? [String: Bool]
        XCTAssertEqual(services?[HelperService.machServiceName], true)
    }

    func testPlistNameFollowsTheLabel() {
        XCTAssertEqual(HelperService.launchdPlistName, "\(HelperService.machServiceName).plist")
    }

    func testProgramIsInsideTheBundle() {
        XCTAssertEqual(plist["BundleProgram"] as? String, "Contents/MacOS/BigEditHelper")
        XCTAssertNil(plist["Program"])
    }

    func testDaemonIsAssociatedWithTheApp() {
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], ["io.maendeleo.BigEdit"])
    }

    func testLabelDiffersFromTheBlessedHelpers() {
        XCTAssertNotEqual(plist["Label"] as? String, "io.maendeleo.BigEdit.helper")
    }
}
