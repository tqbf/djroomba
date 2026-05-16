import SwiftUI

struct PlaylistSidebarRow: View {
  let summary: PlaylistSummary
  let isFavorite: Bool

  var body: some View {
    HStack(spacing: 10) {
      ArtworkThumbnail(ref: summary.artworkRef, size: 28, cornerRadius: 4)
      VStack(alignment: .leading, spacing: 2) {
        Text(summary.name)
          .font(.body)
          .lineLimit(1)
        if let count = summary.trackCount {
          Text("^[\(count) track](inflect: true)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
      if isFavorite {
        Image(systemName: "star.fill")
          .font(.caption2)
          .foregroundStyle(.yellow)
          .accessibilityLabel("Favorite")
      }
    }
    .padding(.vertical, 2)
  }
}
