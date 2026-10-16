import Foundation

/// The size below which a document is cheap enough to handle whole, so the
/// bounds kept for huge files — the lexer's replay window, the CSV width
/// sample, the cap on collected matches — can be lifted without any change
/// the user has to know about.
enum SmallDocument {

    static let byteLimit = 4 * 1024 * 1024

    static func includes(length: Int) -> Bool {
        return length <= byteLimit
    }
}
