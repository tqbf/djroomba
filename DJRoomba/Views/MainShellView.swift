import SwiftUI

/// The authorized shell: sidebar + detail split, persistent now-playing bar
/// pinned to the bottom (never gated behind navigation state), refresh in the
/// unified toolbar. Extension inspector is reserved for Milestone 3.
struct MainShellView: View {
    @Environment(MusicController.self) private var controller

    /// Per-scene persisted sidebar collapse state. Kept in the view layer
    /// (scene storage must not live inside an `@Observable`). The window
    /// frame itself is restored by macOS automatic state restoration.
    @SceneStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PlaylistSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            PlaylistDetailView()
                .navigationSplitViewColumnWidth(min: 480, ideal: 720)
        }
        .onAppear {
            columnVisibility = sidebarCollapsed ? .detailOnly : .all
        }
        .onChange(of: columnVisibility) { _, newValue in
            sidebarCollapsed = (newValue == .detailOnly)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await controller.refreshLibrary() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh playlists (⌘R)")
                .disabled(controller.library.isLoading)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NowPlayingBar()
        }
    }
}
