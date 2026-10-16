import Foundation

/// The tokens and end states of recently lexed rows, so a redraw — a caret
/// blink, a scroll by a row — does not lex the same rows again. Keyed by the
/// row's text and start state, so an edited row simply misses.
final class RowTokenCache {

    private struct Key: Hashable {
        let text: String
        let startState: HighlightState
    }

    private let capacity: Int
    private var tokenEntries: [Key: ([Token], HighlightState)] = [:]
    private var endStateEntries: [Key: HighlightState] = [:]

    var language = Language.plain {
        didSet {
            removeAll()
        }
    }

    init(capacity: Int = 2048) {
        self.capacity = capacity
    }

    func tokens(_ text: String, startState: HighlightState) -> ([Token], HighlightState) {
        let key = Key(text: text, startState: startState)
        let result = tokenEntries[key] ?? language.tokens(text, startState: startState)
        store(result, for: key, in: &tokenEntries)
        return result
    }

    func endState(_ text: String, start: HighlightState) -> HighlightState {
        let key = Key(text: text, startState: start)
        let result = endStateEntries[key] ?? tokenEntries[key]?.1 ?? language.endState(text, start: start)
        store(result, for: key, in: &endStateEntries)
        return result
    }

    func removeAll() {
        tokenEntries.removeAll()
        endStateEntries.removeAll()
    }

    /// Starts over once full, which keeps the bound without tracking use.
    private func store<Value>(_ value: Value, for key: Key, in entries: inout [Key: Value]) {
        if entries[key] == nil {
            if entries.count >= capacity {
                entries.removeAll(keepingCapacity: true)
            }
            entries[key] = value
        }
    }
}
