import SwiftUI

/// The one line the main window says when a screen comes or goes.
///
/// It is **not** a refusal: a display being unplugged is not something he did
/// wrong, so it is drawn in the ordinary text colour rather than the alarm one.
/// It carries `RefusalOwner.displays`, so it can never wipe a live verdict
/// refusal and a later unrelated success can never wipe it (DESIGN.md §7.7).
///
/// Its height is reserved whether or not there is anything to say, so the note
/// arriving never moves the two verdict buttons — `DESIGN.md` principle 2, and
/// the complaint FLOW-04 measured at 212 pt.
public struct DisplayNoteRow: View {
    public let note: String?
    /// The band's height, reserved whether or not it is filled.
    public static let height: CGFloat = 20

    public init(_ note: String?) { self.note = note }

    public var body: some View {
        Text(note ?? " ")
            .font(.callout)
            .foregroundStyle(note == nil ? .clear : .primary)
            .lineLimit(1)
            .frame(height: Self.height, alignment: .center)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(note == nil)
            .accessibilityIdentifier("note.\(RefusalOwner.displays.id)")
    }
}

extension RefusalOwner {
    /// A screen coming or going owns its own line, so it and a verdict refusal
    /// can never overwrite each other.
    public static let displays = RefusalOwner("displays")
}
