import SwiftUI

/// Detail for the selected playlist. Header + boring track table, or an
/// inline state for no-selection / loading / error / empty.
struct PlaylistDetailView: View {

  // MARK: Internal

  var body: some View {
    // `@Bindable` over the `@Environment` controller so the genre-name
    // sheet binds to its request directly (swiftui-pro: `sheet(item:)`,
    // never `Binding(get:set:)`). Same instance, just made bindable.
    @Bindable var controller = controller

    return Group {
      if controller.selectedPlaylistID == nil, controller.selectedGenre == nil {
        // Neither a playlist nor a genre selected → the app's landing
        // surface is the user's Recently Played, not a dead "select
        // something" prompt. A selected genre falls through to the
        // loading/error/`detail` rendering below (the detail service
        // holds the synthetic genre detail).
        RecentlyPlayedView()
      } else if
        controller.detailService.isLoading,
        controller.detailService.detail == nil
      {
        ProgressView("Loading tracks…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if
        let error = controller.detailService.loadError,
        controller.detailService.detail == nil
      {
        ContentUnavailableView {
          Label("Couldn't Load Playlist", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error)
        } actions: {
          Button("Try Again", action: reloadSelectedPlaylist)
        }
      } else if let detail = controller.detailService.detail {
        VStack(spacing: 0) {
          PlaylistHeaderView(detail: detail)
          Divider()
          if detail.isEmpty {
            ContentUnavailableView(
              "Empty Playlist",
              systemImage: "music.note",
              description: Text("This playlist has no tracks."),
            )
          } else {
            TrackTableView(detail: detail)
          }
        }
      } else {
        // Unreachable safety net (selection set but no detail/loading/
        // error state). Stay coherent with the no-selection landing
        // surface rather than a different dead-end prompt.
        RecentlyPlayedView()
      }
    }
    // One modal genre-name sheet for both edits (rename a browsed genre /
    // assign a genre to selected tracks). Hosted here because the detail
    // pane is always present for any playlist *or* genre, and assignment
    // is triggered from its track table.
    .sheet(item: $controller.genreNameRequest) { request in
      GenreNameSheet(
        request: request,
        onCommit: { name in
          Task { await controller.commitGenreNameSheet(request, name: name) }
        },
        onCancel: { controller.cancelGenreNameSheet() },
      )
    }
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller

  private func reloadSelectedPlaylist() {
    if let genre = controller.selectedGenre {
      controller.detailService.selectGenre(genre)
      return
    }
    guard let summary = controller.selectedSummary else { return }
    controller.detailService.select(summary)
  }
}
