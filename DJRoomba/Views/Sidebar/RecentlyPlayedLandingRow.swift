import SwiftUI

/// The "All Recently Played Tracks" entry at the top of the Recently
/// Played sidebar section — clicking it selects the sentinel
/// `MusicController.recentlyPlayedLandingID`, which `PlaylistDetailView`
/// reads (via `controller.isShowingRecentlyPlayedLanding`) to render
/// the canonical `RecentlyPlayedView` in the detail pane.
///
/// Visual: a small clock glyph (matches the toolbar's recent-arrow
/// idiom), the label, and a count chip when the library has any
/// recently-played activity. Sized to match `PlaylistSidebarRow` so
/// the section reads as one consistent stack of rows.
struct RecentlyPlayedLandingRow: View {

  // MARK: Internal

  var body: some View {
    HStack(spacing: 10) {
      // Filled clock disc, white-on-coloured so the icon stays
      // legible whether or not the row is selected (a plain tinted
      // glyph would disappear into the blue accent fill of a List's
      // selected sidebar row). Indigo reads as "history /
      // chronology" without claiming the accent slot.
      ZStack {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(
            LinearGradient(
              colors: [.indigo, .indigo.opacity(0.75)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing,
            )
          )
        Image(systemName: "clock.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white)
      }
      .frame(width: 28, height: 28)
      Text("All Recently Played Tracks")
        .font(.body)
        .lineLimit(1)
      Spacer(minLength: 0)
      if recentTrackCount > 0 {
        Text("\(recentTrackCount)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
    .accessibilityLabel("All Recently Played Tracks")
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller

  /// Cheap O(1) read off the already-loaded RecentlyPlayedService
  /// rows. We don't trigger an extra load just for the badge — the
  /// service populates this lazily once the landing surface is
  /// visited or the sidebar first renders the section.
  private var recentTrackCount: Int {
    controller.recentlyPlayed.rows.count
  }
}
