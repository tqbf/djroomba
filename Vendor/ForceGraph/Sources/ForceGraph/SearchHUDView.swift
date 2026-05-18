import SwiftUI

/// The floating type-anywhere search HUD: a small command-palette panel,
/// top-centre, vibrancy material, that slides+fades in on the first keystroke.
///
/// Per the interaction spec & macos-design: `.regularMaterial`, 12pt corner
/// radius, layered shadow, SF Mono query, a live match count, and `<kbd>`-style
/// shortcut chips. It is a *SwiftUI overlay above the Canvas* (the rendering
/// spec forbids drawing HUD chrome into the Canvas). Pure presentation — all
/// state lives in `GraphEngine`; this view only reads it.
struct SearchHUDView: View {
    let query: String
    let matchCount: Int
    let activeIndex: Int?
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            queryRow
            Divider().opacity(0.5)
            hintRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minWidth: 280, maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
        .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Graph search")
        .accessibilityValue(accessibilitySummary)
    }

    private var queryRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(query.isEmpty ? "Search" : query)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundStyle(query.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            SearchMatchCountView(matchCount: matchCount, activeIndex: activeIndex)
        }
    }

    private var hintRow: some View {
        HStack(spacing: 10) {
            SearchKbdChip(symbol: "return", label: "focus")
            SearchKbdChip(symbol: "arrow.up.arrow.down", label: "cycle")
            SearchKbdChip(symbol: "escape", label: "clear")
            Spacer(minLength: 0)
        }
    }

    private var accessibilitySummary: String {
        if query.isEmpty { return "Type to search nodes." }
        let countPhrase = matchCount == 1 ? "1 match" : "\(matchCount) matches"
        return "Query \(query). \(countPhrase)."
    }
}
