import Foundation

/// A byte-offset range selected in the original file.
///
/// The two endpoints are stored as an anchor / active pair so that future
/// shift-extend behaviour knows which end the user is moving; `range` is
/// the normalised half-open range from the lower of the two to the higher.
struct TextSelection {
    var anchorOffset: Int
    var activeOffset: Int

    var range: Range<Int> {
        min(anchorOffset, activeOffset)..<max(anchorOffset, activeOffset)
    }

    var isEmpty: Bool {
        anchorOffset == activeOffset
    }
}
