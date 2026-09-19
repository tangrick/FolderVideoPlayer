import SwiftUI

// Extracted from the removed classification window, which was the last thing
// keeping this style alive. The playlist's classify column is its only user.
//
/// The filled-versus-outline pair the label chips wear: the label in force on
/// a row is filled and disabled; the other reads as an offer.
///
/// A ternary between two button styles does not compile inside a builder, so
/// the choice lives in its own style struct (the house rule for this exact
/// pitfall). Shared by the old review window's chips and the playlist rows'
/// classify column.
struct LabelChipStyle: ButtonStyle {
    var applied: Bool
    /// A floor on the chip's width. The chip in force carries a checkmark
    /// and so is wider than the one beside it — without a floor the pair
    /// shifts sideways from row to row and the column looks ragged.
    var minWidth: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .frame(minWidth: minWidth)
            .foregroundStyle(applied ? .white : Color.accentColor)
            .background(applied ? Color.accentColor : .clear,
                        in: .rect(cornerRadius: 5))
            .overlay {
                if !applied {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
