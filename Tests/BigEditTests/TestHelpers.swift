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

/// A deterministic random generator (SplitMix64) so fuzz tests are
/// reproducible: a failing seed can be replayed exactly.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
        return mixed ^ (mixed >> 31)
    }
}
