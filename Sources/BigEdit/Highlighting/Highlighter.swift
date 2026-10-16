import Foundation

/// A row-at-a-time lexer for one language. Only `State` is carried between
/// rows, which keeps highlighting tied to the viewport rather than the file.
protocol Highlighter {
    associatedtype State: Hashable

    /// The state at the start of a document.
    static var initialState: State { get }

    /// The row's tokens and the state at its end.
    static func tokens(_ text: String, startState: State) -> ([Token], State)

    /// The state at the row's end, without building its tokens.
    static func endState(_ text: String, start: State) -> State
}
