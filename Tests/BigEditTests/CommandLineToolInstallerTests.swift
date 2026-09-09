import XCTest
@testable import BigEdit
@testable import BigEditHelperKit

/// The installer picks where the command goes and whether the privileged path
/// is needed; the privileged work itself is the helper's, and is covered by
/// LinkInstallationTests.
final class CommandLineToolInstallerTests: XCTestCase {

    func testDestinationIsTheToolNameOnThePath() {
        XCTAssertEqual(CommandLineToolInstaller.destinationURL.path, "/usr/local/bin/bigedit")
    }

    func testDestinationDirectoryIsOneTheHelperWillAcceptToo() {
        // The two lists have to agree, or the helper refuses everything the
        // installer asks for.
        XCTAssertTrue(
            HelperService.isPermittedDestination(CommandLineToolInstaller.destinationURL.path))
    }

    func testNothingIsInstalledUntilItIs() {
        // isInstalled must not claim success just because something else sits
        // at the destination; it compares the link's target with this bundle.
        XCTAssertFalse(CommandLineToolInstaller.isInstalled)
    }
}
