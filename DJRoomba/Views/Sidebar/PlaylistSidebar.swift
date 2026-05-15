import SwiftUI

/// Routes the sidebar between loading / error / empty / populated. The
/// populated list (sections, filtering, focus) lives in `PlaylistSidebarList`.
struct PlaylistSidebar: View {
    @Environment(MusicController.self) private var controller

    var body: some View {
        Group {
            if controller.library.isLoading && controller.library.summaries.isEmpty {
                ProgressView("Loading playlists…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = controller.library.loadError,
                      controller.library.summaries.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Playlists", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") {
                        Task { await controller.refreshLibrary() }
                    }
                }
            } else if controller.library.summaries.isEmpty {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "music.note.list",
                    description: Text("No playlists were found in your Apple Music library.")
                )
            } else {
                PlaylistSidebarList()
            }
        }
        .navigationTitle("Playlists")
    }
}
