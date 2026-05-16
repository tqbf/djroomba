import SwiftUI

/// One rich row in the "Recently Played" list: re-resolvable artwork, the
/// title (primary tier), an "artist • album" secondary line, and a trailing
/// relative last-played stamp ("2 days ago"). A dedicated view (not an
/// inline builder) so the `List`'s lazy reuse is efficient (swiftui-pro:
/// break views up rather than computed properties). Type roles are reused
/// verbatim from the codebase's existing semantic tiers — no new roles
/// (typography-designer): title `.body`, metadata `.body` + `.secondary`,
/// the relative stamp `.body` + `.secondary` exactly like the track table's
/// "Last Played" column.
struct RecentlyPlayedRow: View {

  // MARK: Internal

  let row: TrackRow

  var body: some View {
    HStack(spacing: 12) {
      ArtworkThumbnail(ref: row.artworkRef, size: 44, cornerRadius: 6)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(row.title)
            .font(.body)
            .lineLimit(1)
          if row.isExplicit {
            Image(systemName: "e.square.fill")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .accessibilityLabel("Explicit")
          }
        }
        Text(Self.subtitle(for: row))
          .font(.body)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 12)

      if let date = row.lastPlayedAt {
        Text(date.formatted(.relative(presentation: .named)))
          .font(.body)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 4)
    // The whole row is the hit target (double-click / tap selection),
    // not just the text — native list-row behaviour.
    .contentShape(.rect)
  }

  // MARK: Private

  /// "Artist • Album", collapsing to just the artist when there's no
  /// album, mirroring the track table's secondary-metadata tier. Built
  /// out of `body` (swiftui-pro: keep derivation out of `body`).
  private static func subtitle(for row: TrackRow) -> String {
    guard let album = row.albumTitle, !album.isEmpty else {
      return row.artistName
    }
    return "\(row.artistName) • \(album)"
  }
}
