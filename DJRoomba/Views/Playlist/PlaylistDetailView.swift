import SwiftUI

/// Detail for the selected playlist. Header + boring track table, or an
/// inline state for no-selection / loading / error / empty.
struct PlaylistDetailView: View {

  // MARK: Internal

  var body: some View {
    Group {
      if controller.selectedPlaylistID == nil {
        // No playlist selected → the app's landing surface is the
        // user's Recently Played, not a dead "select something" prompt.
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
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller

  private func reloadSelectedPlaylist() {
    guard let summary = controller.selectedSummary else { return }
    controller.detailService.select(summary)
  }
}
