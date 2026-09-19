import SwiftUI

/// Stars, 1–5, as a control: click a star to rate, click the same star again
/// to clear. Unrated draws as dim hollow stars; rated, the filled ones light
/// up. One control everywhere stars appear — the transport bar, the row and
/// tile menus, the Tags menu — so the interaction is identical in each.
///
/// The `target` closure decides who gets the rating (what is playing, the
/// row's selection, the whole folder), and `current` reports the rating those
/// targets already carry; the menu variant needs both to tick its items.
struct StarRatingControl: View {
    /// The rating the targets carry now, 0–5.
    let current: Int
    /// Apply a rating to whatever this instance is aiming at.
    let target: (Int) -> Void

    /// Visual size — the transport bar wants full-size, menus a compact one.
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 1 : 2) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    // Clicking the star you already rated is "clear it" —
                    // there is no other way to reach zero from the UI.
                    target(current == star ? 0 : star)
                } label: {
                    Image(systemName: star <= current ? "star.fill" : "star")
                        .font(compact ? .caption2 : .body)
                        .foregroundStyle(star <= current ? Color.yellow : Color.secondary)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(star == current
                      ? "Clear the rating"
                      : "Rate \(star) star\(star == 1 ? "" : "s")")
                .accessibilityLabel(star <= current
                                    ? "Clear the rating"
                                    : "Rate \(star) star\(star == 1 ? "" : "s")")
            }
        }
    }
}

/// The row menu's submenu: a ticked run of star ratings, so the choice reads
/// the same way it does in the transport bar. The current rating is ticked;
/// picking it again clears (the same click-a-lit-star rule, in menu form).
struct StarRatingMenuItems: View {
    /// The rating the targets carry now, 0–5 — ticked when nonzero.
    let current: Int
    /// Apply a rating to the targets.
    let target: (Int) -> Void

    var body: some View {
        Menu("Stars") {
            Picker(selection: Binding(
                get: { current },
                set: { target($0) }
            )) {
                // Unrated exists so the tick can be taken back from the menu
                // too; it is only drawn when something is ticked, so an
                // unrated target does not open on a pointless empty choice.
                if current > 0 {
                    Text("No Rating").tag(0)
                    Divider()
                }
                ForEach(1...5, id: \.self) { star in
                    // The plain text spells the count out; a menu row of
                    // glyph stars renders at a size menus do not control.
                    Text("\(String(repeating: "★", count: star))")
                        .tag(star)
                }
            } label: {}
            .pickerStyle(.inline)
        }
        .pickerStyle(.inline)
    }
}
