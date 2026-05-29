import Foundation
import XCTest
@testable import BigEdit

/// Writes `data` to a fresh temp file under the system temp directory and
/// returns its URL. The file is cleaned up on `tearDown` if registered.
enum TestHelpers {
    static func writeTempFile(_ data: Data) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigEditTest-\(UUID().uuidString)")
        try? data.write(to: url)
        return url
    }

    static func writeTempFile(_ string: String) -> URL {
        return writeTempFile(Data(string.utf8))
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
