import SwiftUI

/// Sizes are derived from cap heights measured in the design frame, so they
/// track `Design.scale` along with everything else.
enum Typography {
    /// The percent under each provider ring. Cap height 27px in the frame.
    static let percent = Font.system(size: Design.fontSize(capPixels: 27), weight: .semibold)

    /// The short name under a ring — "5h", "Weekly", "Fable". Not in the design
    /// frame: it exists because one account can now be several rings, and it is
    /// deliberately the smallest and quietest type in the notch, so the
    /// percentage above it stays the thing the eye lands on.
    static let ringCaption = Font.system(size: Design.fontSize(capPixels: 16), weight: .medium)

    /// "Claude Usage". Cap height 26px.
    static let cardTitle = Font.system(size: Design.fontSize(capPixels: 26), weight: .semibold)

    /// "Current session", "73% Used", "Resets in 51 min". Cap height 18px.
    static let cardBody = Font.system(size: Design.fontSize(capPixels: 18), weight: .regular)
}
