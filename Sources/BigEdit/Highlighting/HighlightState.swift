import Foundation

/// The carried syntax state at a row boundary, so multi-row constructs colour
/// every row, not just the one where they open. Each highlighter has its own
/// `State`; this wraps it so the viewport can carry and compare states
/// without knowing the language.
struct HighlightState: Hashable {

    static let normal = HighlightState(wrapped: nil)

    private let wrapped: AnyHashable?

    private init(wrapped: AnyHashable?) {
        self.wrapped = wrapped
    }

    /// A highlighter's state, folded to `.normal` when it is the initial one.
    init<H: Highlighter>(_ state: H.State, of highlighter: H.Type) {
        self.init(wrapped: state == H.initialState ? nil : AnyHashable(state))
    }

    /// The state as `highlighter` sees it; the initial state when this one was
    /// made by another language.
    func state<H: Highlighter>(for highlighter: H.Type) -> H.State {
        return wrapped?.base as? H.State ?? H.initialState
    }
}
