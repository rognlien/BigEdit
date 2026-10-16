import Foundation

/// Start-of-row highlight states remembered every `interval` rows, as an
/// unbroken chain from the top of the document. Every state in the chain was
/// replayed from the one before it, so each is exact; a state picked up
/// further down without that chain is only a guess and is never stored.
struct HighlightCheckpoints {

    static let interval = 256

    private var states: [HighlightState] = [.normal]

    /// The last remembered row at or above `row`, with its start state.
    func nearest(atOrAbove row: Int) -> (row: Int, state: HighlightState) {
        let index = min(states.count - 1, max(0, row) / HighlightCheckpoints.interval)
        return (index * HighlightCheckpoints.interval, states[index])
    }

    /// Remembers `state` as the start state of `row` when it extends the chain
    /// by one; any other row is ignored.
    mutating func record(_ state: HighlightState, atRow row: Int) {
        if row == states.count * HighlightCheckpoints.interval {
            states.append(state)
        }
    }

    /// Forgets every state at or below `row`, whose rows may have changed.
    mutating func invalidate(fromRow row: Int) {
        let kept = max(1, (max(0, row) + HighlightCheckpoints.interval - 1) / HighlightCheckpoints.interval)
        if kept < states.count {
            states.removeSubrange(kept...)
        }
    }

    mutating func reset() {
        states = [.normal]
    }
}
