import MusicKit
import SwiftUI

/// One catalog search result row. Lives inside the catalog-search sheet
/// (Phase 2 of `plans/catalog-playlists.md`) — never elsewhere in the app,
/// so the `MusicKit.Song` type stays scoped to the search surface.
///
/// **Action: Add to Playlist.** Two equivalent affordances, both routed
/// through the same `addToPlaylistContent` `ViewBuilder` (single source of
/// truth — no menu drift):
/// 1. A trailing **`plus.circle` button** (`Menu`) that drops the playlist
///    list directly. This is the discoverable surface — Phase-2 shipped
///    only the right-click context menu, which read as "inscrutable" since
///    a left-click did nothing visible. The `+` mirrors Apple Music's own
///    search-result "add" affordance.
/// 2. The original **right-click context menu** ("Add to Playlist ▸"),
///    preserved for power-user muscle memory and for keyboard navigation
///    (Tab → ⌘-click), and to mirror `TrackContextMenu`'s same affordance
///    on library rows.
///
/// The plumbing flows through
/// `MusicController.addCatalogResult(catalogID:toAppPlaylist:)` so the
/// controller stays MusicKit-free; the row carries only the catalog id
/// string (`song.id.rawValue`, globally stable per
/// `plans/catalog-playlists.md`) across the boundary, and the search
/// service does the ingest hop inside its own layer.
///
/// **No inline play.** Phase 3 owns the playback flip (the dormant
/// `PlaybackResolver` catalog branch). A "Play" affordance here would
/// promise something the resolver can't fulfil today.
///
/// **Artwork: real cover art (Phase 4).** The catalog branch of
/// `ArtworkProvider` (`plans/catalog-playlists.md` Phase 4) re-resolves the
/// catalog song's `MusicKit.Artwork` by id and `ArtworkThumbnail` renders
/// it via `ArtworkImage` — same component, same actor cache, same cross-
/// fade as library rows everywhere else in the app. While the catalog
/// request is in flight (or on any miss / network failure) the shared
/// `.quaternary` placeholder shows, matching every other thumbnail surface.
struct CatalogSearchResultRow: View {

  // MARK: Internal

  let song: MusicKit.Song
  @Binding var isPresented: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      ArtworkThumbnail(
        ref: .song(song.id.rawValue, namespace: .catalog),
        size: 40,
      )
      VStack(alignment: .leading, spacing: 2) {
        Text(song.title)
          .font(.body)
          .lineLimit(1)
        Text(metadataLine)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if let duration = song.duration {
        Text(duration.musicTimeText)
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      // The discoverable add affordance — Phase-2 corrective. A `Menu`
      // renders the same dropdown the right-click context menu does, but
      // triggered by a *visible*, left-clickable button. macos-design:
      // mirrors Apple Music's search-result `+`. `.borderless` + secondary
      // foreground keeps the visual weight subordinate to title/artist;
      // the tooltip carries the verb so the icon stays terse.
      Menu {
        addToPlaylistContent
      } label: {
        Label("Add to Playlist", systemImage: "plus.circle")
          .labelStyle(.iconOnly)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Add to Playlist")
      .accessibilityLabel("Add to playlist")
    }
    .padding(.vertical, 4)
    .contentShape(.rect)
    .contextMenu {
      Menu("Add to Playlist") {
        addToPlaylistContent
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("\(song.title), \(song.artistName)"))
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller

  private var metadataLine: String {
    if let album = song.albumTitle, !album.isEmpty {
      "\(song.artistName) — \(album)"
    } else {
      song.artistName
    }
  }

  @ViewBuilder
  private var addToPlaylistContent: some View {
    let appPlaylists = controller.appPlaylists
    if appPlaylists.isEmpty {
      Button("New Playlist with This Song…") {
        createPlaylistAndAdd()
      }
    } else {
      ForEach(appPlaylists) { playlist in
        Button(playlist.name) {
          add(to: playlist.id)
        }
      }
    }
  }

  private func add(to playlistID: String) {
    let catalogID = song.id.rawValue
    Task {
      await controller.addCatalogResult(
        catalogID: catalogID,
        toAppPlaylist: playlistID,
      )
    }
  }

  private func createPlaylistAndAdd() {
    let catalogID = song.id.rawValue
    Task {
      if let id = await controller.createAppPlaylist() {
        await controller.addCatalogResult(
          catalogID: catalogID,
          toAppPlaylist: id,
        )
      }
    }
  }
}
