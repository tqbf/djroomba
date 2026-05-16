import SwiftUI

/// The sidebar's empty / error state, with the *cause* spelled out (Phase 5
/// smarter empty states). Native, non-modal `ContentUnavailableView` (macOS
/// 14) — honest and specific instead of an undifferentiated "No Playlists":
/// "library isn't synced to this Mac" vs "needs an Apple Music subscription"
/// vs "no playlists yet". Each carries the action that actually fixes it.
///
/// "My Playlists" is always reachable (the create affordance is a
/// destination), so even the not-synced / no-imports states offer "New
/// Playlist" — a user with no Apple library can still build their own.
struct SidebarUnavailableView: View {
    let state: LibrarySidebarState
    @Environment(MusicController.self) private var controller

    var body: some View {
        switch state {
        case .error(let message):
            ContentUnavailableView {
                Label("Couldn't Load Playlists", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", action: refresh)
            }

        case .libraryNotSynced:
            ContentUnavailableView {
                Label("Library Not Synced to This Mac", systemImage: "arrow.triangle.2.circlepath.icloud")
            } description: {
                Text("Turn on Sync Library in the Music app (Music ▸ Settings ▸ General ▸ Sync Library) so DJ Roomba can import your Apple Music playlists. You can still create your own playlists here.")
            } actions: {
                Button("Open Music", action: openMusicApp)
                Button("New Playlist", action: createPlaylist)
            }

        case .subscriptionNeeded:
            ContentUnavailableView {
                Label("Apple Music Subscription Needed", systemImage: "music.note")
            } description: {
                Text("An active Apple Music subscription is required to import and play your library. You can still create your own playlists here.")
            } actions: {
                Button("New Playlist", action: createPlaylist)
            }

        case .noImportedPlaylists:
            ContentUnavailableView {
                Label("No Playlists Yet", systemImage: "music.note.list")
            } description: {
                Text("No Apple Music playlists were found in your library. Create your own playlist to get started, or refresh to import again.")
            } actions: {
                Button("New Playlist", action: createPlaylist)
                Button("Refresh", action: refresh)
            }

        case .loading, .populated:
            // Not an unavailable state — the router handles these. An
            // exhaustive switch keeps this total without a silent default.
            EmptyView()
        }
    }

    private func refresh() {
        Task { await controller.refreshLibrary() }
    }

    private func createPlaylist() {
        Task { await controller.createAppPlaylist() }
    }

    private func openMusicApp() {
        guard let url = URL(string: "music://") else { return }
        NSWorkspace.shared.open(url)
    }
}
