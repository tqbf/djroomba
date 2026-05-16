import SwiftUI

/// Routes the sidebar between loading / error / cause-specific empty /
/// populated. The *cause* of an empty state is inferred by the controller's
/// pure `sidebarState` (Phase 5 smarter empty states — "library not synced"
/// vs "subscription needed" vs "no playlists yet", not a blanket "empty").
/// The populated list (sections, filtering, focus) lives in
/// `PlaylistSidebarList`.
struct PlaylistSidebar: View {

  // MARK: Internal

  var body: some View {
    Group {
      switch controller.sidebarState {
      case .loading:
        ProgressView(controller.libraryLoadingMessage)
          .frame(maxWidth: .infinity, maxHeight: .infinity)

      case .populated:
        // Always the list when there's anything to show: even with no
        // imported library and no user playlists, "My Playlists" stays
        // reachable so the user can create one (the create affordance
        // is a destination).
        PlaylistSidebarList()

      case .error,
           .libraryNotSynced,
           .subscriptionNeeded,
           .noImportedPlaylists:
        SidebarUnavailableView(state: controller.sidebarState)
      }
    }
    .navigationTitle("Playlists")
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller

}
