import CoreGraphics

/// Corner radii. Inner corners are concentric: inner = outer - inset.
enum Radius {
    /// Upload rows.
    static let row: CGFloat = 10
    /// Cards: the drop zone.
    static let md: CGFloat = 12
}
