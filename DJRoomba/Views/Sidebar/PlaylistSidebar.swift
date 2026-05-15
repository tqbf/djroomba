import SwiftUI
import MusicKit

/// The app's primary navigation: the user's library playlists. Loading,
/// error, and empty states are inline (no modal alerts).
struct PlaylistSidebar: View {
    @Environment(MusicController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
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
                List(selection: $controller.selectedPlaylistID) {
                    Section("Library Playlists") {
                        ForEach(controller.library.summaries) { summary in
                            PlaylistSidebarRow(summary: summary)
                                .tag(summary.id)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle("Playlists")
    }
}
