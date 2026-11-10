import SwiftUI

/// Colors beyond the system accent. The accent itself comes from `.tint` / `Color.accentColor`,
/// so it follows the accent the person set for their Mac.
enum Palette {
    /// Done, saved, copied.
    static let success = Color.green
    /// Failed, missing credentials, Cancel.
    static let failure = Color.red
}

/// Fills and borders of the app's own surfaces. Neutral states are translucent so they
/// pick up the window tint; accent states use the accent at a fixed strength.
enum Surface {
    /// Resting fill of an upload row.
    static let row = Color.secondary.opacity(0.06)
    /// Fill and border of the selected row.
    static let rowSelected = Color.accentColor.opacity(0.14)
    static let rowSelectedBorder = Color.accentColor.opacity(0.6)
    /// Dashed border of the drop zone at rest, and its fill while a file hovers over it.
    static let dropBorder = Color.secondary.opacity(0.4)
    static let dropTarget = Color.accentColor.opacity(0.08)
}
