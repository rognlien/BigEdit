import Foundation

/// Whether Format ▸ Pretty Print or Format ▸ Compact is being applied.
enum FormattingStyle {
    case pretty
    case compact
}

/// How Pretty Print lays a document out: the indentation each level of
/// nesting adds, the width short structures are fitted within, and the line
/// ending and encoding of the document being formatted.
struct FormattingOptions: Equatable {

    enum Indentation: String, CaseIterable, Identifiable {
        case twoSpaces
        case fourSpaces
        case tab

        var id: String { rawValue }

        var title: String {
            switch self {
            case .twoSpaces: return "2 Spaces"
            case .fourSpaces: return "4 Spaces"
            case .tab: return "Tab"
            }
        }

        /// The bytes one level of indentation writes.
        var bytes: [UInt8] {
            switch self {
            case .twoSpaces: return [0x20, 0x20]
            case .fourSpaces: return [0x20, 0x20, 0x20, 0x20]
            case .tab: return [0x09]
            }
        }

        /// The columns one level of indentation takes on screen.
        var columns: Int {
            switch self {
            case .twoSpaces: return 2
            case .fourSpaces: return 4
            case .tab: return ViewportView.tabWidth
            }
        }
    }

    static let defaultLineWidth = 80
    static let lineWidthRange = 0...400

    var indentation = Indentation.twoSpaces

    /// What fits within this many columns is kept on one line. Zero turns
    /// the fitting off.
    var lineWidth = FormattingOptions.defaultLineWidth

    /// Whether a JSON container kept on one line has a space after each
    /// `:` and `,`.
    var spacesAfterSeparators = true

    var newline: [UInt8] = [0x0A]
    var encoding = TextEncoding.utf8
}
