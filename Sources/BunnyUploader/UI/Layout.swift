import CoreGraphics

/// Fixed sizes of windows and parts.
enum Layout {
    static let windowMinWidth: CGFloat = 560
    static let windowMinHeight: CGFloat = 420
    static let settingsWidth: CGFloat = 460
    static let dropZoneHeight: CGFloat = 110
    /// Width of the number beside the thread stepper.
    static let stepperValueWidth: CGFloat = 24
    /// Symbol sizes: the empty-state symbol and the drop-zone symbol.
    static let heroSymbol: CGFloat = 34
    static let dropSymbol: CGFloat = 26
    /// Dashed border of the drop zone.
    static let dropBorderWidth: CGFloat = 2
    static let dropBorderDash: [CGFloat] = [8, 6]
    static let selectionBorderWidth: CGFloat = 1
}
