import Foundation

/// How a document was last shown: the view mode, the CSV options and
/// resized columns, and the language chosen in place of the detected one.
struct DocumentViewState: Codable, Equatable {

    var mode: String
    var delimiter: String
    var quote: String?
    var hasHeaderRow: Bool
    var pinsHeaderRow: Bool
    var trimsFieldWhitespace: Bool
    var columnWidths: [Int: Int]
    var language: String?

    init(mode: FormatBar.Mode, dialect: CSVDialect, columnWidths: [Int: Int], language: Language?) {
        self.mode = mode.rawValue
        self.delimiter = String(dialect.delimiter)
        self.quote = dialect.quote.map(String.init)
        self.hasHeaderRow = dialect.hasHeaderRow
        self.pinsHeaderRow = dialect.pinsHeaderRow
        self.trimsFieldWhitespace = dialect.trimsFieldWhitespace
        self.columnWidths = columnWidths
        self.language = language?.identifier
    }

    var viewMode: FormatBar.Mode {
        FormatBar.Mode(rawValue: mode) ?? .text
    }

    /// The CSV options, or nil when the stored delimiter is not one character.
    var dialect: CSVDialect? {
        var result: CSVDialect?
        if delimiter.count == 1, let delimiterCharacter = delimiter.first, quote.map({ $0.count == 1 }) ?? true {
            result = CSVDialect(delimiter: delimiterCharacter, quote: quote?.first,
                                hasHeaderRow: hasHeaderRow, pinsHeaderRow: pinsHeaderRow,
                                trimsFieldWhitespace: trimsFieldWhitespace)
        }
        return result
    }

    /// The chosen language, or nil for the detected one.
    var chosenLanguage: Language? {
        language.flatMap { $0 == Language.plain.identifier ? .plain : LanguageRegistry.language(identifier: $0) }
    }
}

/// The view states of recently shown documents, by path, in user defaults.
/// Only the most recently stored ones are kept.
final class DocumentViewStateStore {

    static let shared = DocumentViewStateStore(defaults: .standard)

    private static let statesKey = "DocumentViewStates"
    private static let orderKey = "DocumentViewStateOrder"
    static let capacity = 200

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func state(forPath path: String) -> DocumentViewState? {
        let states = defaults.dictionary(forKey: DocumentViewStateStore.statesKey) as? [String: Data]
        return states?[path].flatMap { try? JSONDecoder().decode(DocumentViewState.self, from: $0) }
    }

    func store(_ state: DocumentViewState, forPath path: String) {
        var states = defaults.dictionary(forKey: DocumentViewStateStore.statesKey) as? [String: Data] ?? [:]
        var order = defaults.stringArray(forKey: DocumentViewStateStore.orderKey) ?? []
        states[path] = try? JSONEncoder().encode(state)
        order.removeAll { $0 == path }
        order.insert(path, at: 0)
        for evicted in order.dropFirst(DocumentViewStateStore.capacity) {
            states[evicted] = nil
        }
        defaults.set(states, forKey: DocumentViewStateStore.statesKey)
        defaults.set(Array(order.prefix(DocumentViewStateStore.capacity)), forKey: DocumentViewStateStore.orderKey)
    }
}
