import SwiftUI

/// A "My Playlists" sidebar row. Identical visual treatment to the imported
/// `PlaylistSidebarRow` (same artwork frame / `.body` name / `.caption`
/// secondary count / favorite star) so the two sections feel uniform.
///
/// Phase-4 D1: rename is no longer an inline `TextField` swapped into this
/// row. The inline editor's `@FocusState` competed with the enclosing
/// `List(selection:)`'s own first-responder/selection handling, so
/// commit-on-blur was inconsistent depending on how rename was entered. Rename
/// now goes through the modal `RenamePlaylistSheet` (a deterministic,
/// trigger-independent commit), so this row is a plain, non-editing row again.
struct AppPlaylistSidebarRow: View {
    let summary: PlaylistSummary
    let isFavorite: Bool

    var body: some View {
        HStack(spacing: 10) {
            ArtworkThumbnail(
                ref: summary.artworkRef,
                size: 28,
                cornerRadius: 4,
                placeholderSymbol: "music.note.list"
            )
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
