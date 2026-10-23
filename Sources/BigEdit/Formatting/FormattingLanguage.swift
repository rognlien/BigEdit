import Foundation

/// The languages Edit ▸ Format can lay out.
enum FormattingLanguage: Equatable {
    case json
    case xml

    /// The formatting language of `language`, or nil when it has none.
    static func of(_ language: Language) -> FormattingLanguage? {
        var result: FormattingLanguage?
        if language == LanguageRegistry.json {
            result = .json
        } else if language == LanguageRegistry.xml {
            result = .xml
        }
        return result
    }

    var displayName: String {
        switch self {
        case .json: return "JSON"
        case .xml: return "XML"
        }
    }

    func formatter(style: FormattingStyle, options: FormattingOptions) -> any StreamingFormatter {
        switch self {
        case .json: return JSONFormatter(style: style, options: options)
        case .xml: return XMLFormatter(style: style, options: options)
        }
    }
}
