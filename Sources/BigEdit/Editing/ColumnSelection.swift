import CoreGraphics

/// A rectangular selection: the same span of x positions on every visual row
/// from `anchorRow` to `activeRow`. The x positions are measured from the
/// start of the text, so horizontal scrolling does not move them.
struct ColumnSelection: Equatable {
    var anchorRow: Int
    var activeRow: Int
    var anchorX: CGFloat
    var activeX: CGFloat

    var rows: ClosedRange<Int> {
        min(anchorRow, activeRow)...max(anchorRow, activeRow)
    }

    var xRange: ClosedRange<CGFloat> {
        min(anchorX, activeX)...max(anchorX, activeX)
    }
}
