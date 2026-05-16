import SwiftUI

/// The track table's per-selection context menu (Phase 4): Play (single
/// selection), an "Add to Playlist ▸" submenu of every user playlist (the
/// always-reachable equivalent of dragging a row onto a sidebar playlist),
/// and — only when the open playlist is user-owned — Remove from it.
///
/// Extracted into its own `View` (swiftui-pro: prefer a `View` struct over a
/// `@ViewBuilder` method splitting a body). It is built per
/// `contextMenu(forSelectionType:)` invocation with the resolved selection.
struct TrackContextMenu: View {

  // MARK: Internal

  /// The track rows the menu acts on (the resolved table selection).
  let rows: [TrackRow]
  /// The playlist currently on screen — drives the "Remove" affordance.
  let detail: PlaylistDetail

  var body: some View {
    if !rows.isEmpty {
      if rows.count == 1, let row = rows.first {
        Button("Play", systemImage: "play.fill") {
          Task { await controller.play(row) }
        }
      }
      Menu("Add to Playlist") {
        addToPlaylistContent
      }
      if detail.isAppOwned {
        Divider()
        Button(
          "Remove from Playlist",
          systemImage: "minus.circle",
          role: .destructive,
        ) {
          removeSelected()
        }
      }
    }
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller

  @ViewBuilder
  private var addToPlaylistContent: some View {
    let appPlaylists = controller.appPlaylists
    if appPlaylists.isEmpty {
      Button("New Playlist…", action: createPlaylistWithSelection)
    } else {
      ForEach(appPlaylists) { playlist in
        Button(playlist.name) {
          addSelected(to: playlist.id)
        }
      }
    }
  }

  private func addSelected(to playlistID: String) {
    let ids = rows.map(\.songID)
    Task { await controller.addSongs(ids, toAppPlaylist: playlistID) }
  }

  private func createPlaylistWithSelection() {
    let ids = rows.map(\.songID)
    Task {
      if let id = await controller.createAppPlaylist() {
        await controller.addSongs(ids, toAppPlaylist: id)
      }
    }
  }

  private func removeSelected() {
    let positions = rows.map(\.position)
    let playlistID = detail.id
    Task {
      await controller.removeTracks(at: positions, fromAppPlaylist: playlistID)
    }
  }
}
