import SwiftUI

/// The "Up Next" landing entry, immediately below
/// `RecentlyPlayedLandingRow` inside the Recently Played sidebar
/// section. Clicking it selects the sentinel
/// `MusicController.upNextLandingID`, which `PlaylistDetailView` reads
/// (via `controller.isShowingUpNextLanding`) to render `UpNextView` in
/// the detail pane.
///
/// Visual: a deliberate peer of `RecentlyPlayedLandingRow` — same 28×28
/// rounded-square icon disc, same label tier, same secondary
/// monospaced-digit count chip — so the two read as siblings inside one
/// section, distinguished only by glyph + hue + label. The glyph is
/// Apple Music's own "Up Next" symbol
/// (`text.line.first.and.arrowtriangle.forward`); the hue is teal — a
/// cool-side neighbour of the recently-played indigo (harmonious) that
/// still reads clearly distinct from purple (the macos-design call).
struct UpNextLandingRow: View {

  // MARK: Internal

  var body: some View {
    HStack(spacing: 10) {
      // Identical disc treatment to the recently-played peer: a white
      // glyph on a coloured gradient keeps the icon legible whether or
      // not the row is selected (a plain tinted glyph would disappear
      // into the blue accent fill of a List's selected sidebar row).
      ZStack {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(
            LinearGradient(
              colors: [.teal, .teal.opacity(0.75)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing,
            )
          )
        Image(systemName: "text.line.first.and.arrowtriangle.forward")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white)
      }
      .frame(width: 28, height: 28)
      Text("Up Next")
        .font(.body)
        .lineLimit(1)
      Spacer(minLength: 0)
      if upNextCount > 0 {
        Text("\(upNextCount)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
    .accessibilityLabel("Up Next")
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller

  /// Cheap O(1) read off the in-memory `UpNextService`. `@Observable`
  /// makes the row invalidate exactly when the queue mutates.
  private var upNextCount: Int {
    controller.upNext.count
  }
}
