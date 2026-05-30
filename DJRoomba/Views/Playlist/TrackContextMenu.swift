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
      // Queue is the transient / immediate destination; placed above
      // the longer-term "Add to Playlist" / "Add to Genre" submenus
      // (the macos-design call). A flat menu item — Up Next is an
      // append, not a pick-one-of-many surface like the playlist /
      // genre submenus below.
      Button("Add to Up Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
        addSelectedToUpNext()
      }
      Menu("Add to Playlist") {
        addToPlaylistContent
      }
      Menu("Add to Genre") {
        addToGenreContent
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

  /// Assign a genre to the selected songs. "New Genre…" opens the modal
  /// sheet (free text); the existing genres (from the library, alphabetical)
  /// assign on tap and **merge** naturally — same unbounded-but-fine shape
  /// as the "Add to Playlist" list (macOS menus scroll).
  @ViewBuilder
  private var addToGenreContent: some View {
    Button("New Genre…") {
      controller.beginAssignNewGenre(toSongs: rows.map(\.songID))
    }
    let genres = controller.allGenres
    if !genres.isEmpty {
      Divider()
      ForEach(genres, id: \.self) { genre in
        Button(genre) {
          let ids = rows.map(\.songID)
          Task { await controller.addGenre(genre, toSongs: ids) }
        }
      }
    }
  }

  private func addSelected(to playlistID: String) {
    let ids = rows.map(\.songID)
    Task { await controller.addSongs(ids, toAppPlaylist: playlistID) }
  }

  /// Fans the resolved selection out through the controller's batched
  /// `addToUpNext(songIDs:)` funnel — the same path the sidebar
  /// landing's drop target uses, so context-menu adds and drag-drop
  /// adds are observationally identical.
  private func addSelectedToUpNext() {
    let ids = rows.map(\.songID)
    Task { await controller.addToUpNext(songIDs: ids) }
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
