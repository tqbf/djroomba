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
        let isEmpty = favorites.isEmpty && recents.isEmpty && library.isEmpty

        Group {
            if isEmpty {
                ContentUnavailableView.search(text: filterText)
            } else {
                List(selection: $controller.selectedPlaylistID) {
                    if !favorites.isEmpty {
                        PlaylistSidebarSection(title: "Favorites", summaries: favorites)
                    }
                    if !recents.isEmpty {
                        PlaylistSidebarSection(title: "Recently Played", summaries: recents)
                    }
                    if !library.isEmpty {
                        PlaylistSidebarSection(title: "Library Playlists", summaries: library)
                    }
                }
                .listStyle(.sidebar)
                .focused($listFocused)
                .onKeyPress(.return) {
                    guard controller.selectedPlaylistID != nil else { return .ignored }
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
