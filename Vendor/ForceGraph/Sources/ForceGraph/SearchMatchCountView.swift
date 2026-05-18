import SwiftUI

/// The live match count — the HUD's secondary signal (13pt monospaced
/// semibold). When matches are being cycled it shows `i / n`; otherwise the
/// plain count. Tinted by state: zero matches reads muted, hits read accent.
struct SearchMatchCountView: View {
    let matchCount: Int
    let activeIndex: Int?

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(matchCount == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.15), value: matchCount)
            .accessibilityHidden(true)
    }

    private var text: String {
        guard matchCount > 0 else { return "no matches" }
        if let activeIndex, matchCount > 1 {
            return "\(activeIndex + 1) / \(matchCount)"
        }
        return matchCount == 1 ? "1 match" : "\(matchCount) matches"
    }
}
