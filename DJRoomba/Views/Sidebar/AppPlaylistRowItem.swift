import SwiftUI

/// One "My Playlists" list item: the row, its context menu (Play / Rename /
/// Favorite / Delete), and its song drop target. Extracted from the section
/// so the section body stays lean (swiftui-pro: prefer a `View` struct over
/// inline view-building). The rename request and the pending-delete request
/// are owned by the parent section (a single section-level rename sheet /
/// delete dialog) and surfaced via closures.
///
/// Phase-4 D1: the double-click-to-rename `.simultaneousGesture` was removed.
/// The enclosing `List` already treats double-click / Return as "play this
/// playlist" (an M2 feature), so the gesture both renamed AND played — a
/// collision. Rename is now context-menu-only: the discoverable, standard,
/// collision-free macOS trigger. Double-click on a My-Playlists row now does
/// exactly what it does for every other sidebar row (select / play), nothing
/// else.
struct AppPlaylistRowItem: View {
    let summary: PlaylistSummary
    /// Open the modal rename sheet for this playlist (owned by the parent
    /// section). Context-menu-only — no gesture trigger (the D1 collision).
    let beginRename: () -> Void
    let requestDelete: () -> Void
    @Environment(MusicController.self) private var controller

    var body: some View {
        AppPlaylistSidebarRow(
            summary: summary,
            isFavorite: controller.isFavorite(summary)
        )
        .tag(summary.id)
        .contextMenu {
            Button("Play", systemImage: "play.fill", action: play)
            Button("Rename", systemImage: "pencil", action: beginRename)
            Button(
                isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: isFavorite ? "star.slash" : "star",
                action: toggleFavorite
            )
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive, action: requestDelete)
        }
        // Songs dragged from the track table carry their songID; a drop here
        // appends them to this playlist (native macOS drag-into-playlist,
        // like Music.app's sidebar).
        .dropDestination(for: SongDragItem.self) { items, _ in
            let ids = items.map(\.songID)
            guard !ids.isEmpty else { return false }
            Task { await controller.addSongs(ids, toAppPlaylist: summary.id) }
            return true
        }
    }

    private var isFavorite: Bool { controller.isFavorite(summary) }

    private func play() {
        Task {
            controller.selectedPlaylistID = summary.id
            await controller.playSelectedPlaylist()
        }
    }

    private func toggleFavorite() {
        controller.toggleFavorite(summary)
    }
}
