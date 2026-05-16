import SwiftUI

/// The populated playlist list: Favorites / Recently Played / Library
/// sections, `.searchable` filtering (⌘F focuses it automatically), Return to
/// play the selected playlist, and ⌘L/⌘1 focus via the controller's request.
struct PlaylistSidebarList: View {
    @Environment(MusicController.self) private var controller
    @State private var filterText = ""
    @FocusState private var listFocused: Bool

    var body: some View {
        @Bindable var controller = controller

        let favorites = filtered(controller.favoritePlaylists)
        let recents = filtered(controller.recentPlaylists)
        let library = filtered(controller.libraryPlaylists)
        let appPlaylists = filtered(controller.appPlaylists)
        // "My Playlists" always shows (even empty) so the create affordance
        // and an empty user library are reachable — it's a destination, not
        // just imported content.
        let isEmpty = favorites.isEmpty && recents.isEmpty
            && library.isEmpty && appPlaylists.isEmpty

        Group {
            if isEmpty && filterText.isEmpty {
                // No imported library AND no user playlists: keep the create
                // affordance reachable rather than a dead empty view.
                List(selection: $controller.selectedPlaylistID) {
                    AppPlaylistSidebarSection(summaries: appPlaylists)
                }
                .listStyle(.sidebar)
            } else if isEmpty {
                ContentUnavailableView.search(text: filterText)
            } else {
                List(selection: $controller.selectedPlaylistID) {
                    if !favorites.isEmpty {
                        PlaylistSidebarSection(title: "Favorites", summaries: favorites)
                    }
                    if !recents.isEmpty {
                        PlaylistSidebarSection(title: "Recently Played", summaries: recents)
                    }
                    // User-owned section: always present (even with zero
                    // playlists) so the inline "+" / ⌘N create is reachable.
                    AppPlaylistSidebarSection(summaries: appPlaylists)
                    if !library.isEmpty {
                        PlaylistSidebarSection(title: "Library Playlists", summaries: library)
                    }
                }
                .listStyle(.sidebar)
                .focused($listFocused)
                .onKeyPress(.return) {
                    // Only the *focused* sidebar list plays on Return. Without
                    // the `listFocused` gate this fired even while a modal
                    // (the rename sheet) or the search field held focus —
                    // hijacking Return from the sheet's default button and
                    // playing the playlist instead of committing the rename
                    // (the Phase-4 D1 collision). When a sheet/field is up the
                    // list isn't focused, so Return correctly falls through to
                    // it; normal keyboard navigation still has the list
                    // focused, so M2 Return-to-play is unchanged.
                    guard listFocused, controller.selectedPlaylistID != nil else {
                        return .ignored
                    }
                    Task { await controller.playSelectedPlaylist() }
                    return .handled
                }
            }
        }
        .searchable(text: $filterText, placement: .sidebar, prompt: "Filter Playlists")
        .onChange(of: controller.focusSidebarRequest) {
            listFocused = true
        }
    }

    private func filtered(_ summaries: [PlaylistSummary]) -> [PlaylistSummary] {
        guard !filterText.isEmpty else { return summaries }
        return summaries.filter { $0.name.localizedStandardContains(filterText) }
    }
}
