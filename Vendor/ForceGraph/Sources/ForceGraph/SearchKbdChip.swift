import SwiftUI

/// A `<kbd>`-style shortcut hint: a small keycap glyph plus what it does.
/// Reads as the tertiary tier of the HUD type hierarchy (11pt monospaced,
/// secondary tone) — present but never competing with the query.
struct SearchKbdChip: View {
    /// SF Symbol for the key (`return`, `escape`, `arrow.up.arrow.down`).
    let symbol: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(minWidth: 18, minHeight: 16)
                .padding(.horizontal, 4)
                .background(.quaternary, in: .rect(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
                )
            Text(label)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) shortcut")
    }
}
