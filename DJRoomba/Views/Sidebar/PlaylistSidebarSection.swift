import SwiftUI

/// One titled sidebar section. Each row carries a favorite toggle in its
/// context menu (keeps the row itself uncluttered — progressive disclosure).
struct PlaylistSidebarSection: View {

  // MARK: Internal

  let title: LocalizedStringKey
  let summaries: [PlaylistSummary]

  var body: some View {
    Section(title) {
      ForEach(summaries) { summary in
        PlaylistSidebarRow(
          summary: summary,
          isFavorite: controller.isFavorite(summary),
        )
        .tag(summary.id)
        .contextMenu {
          let favorited = controller.isFavorite(summary)
          Button(
            favorited ? "Remove from Favorites" : "Add to Favorites",
            systemImage: favorited ? "star.slash" : "star",
          ) {
            controller.toggleFavorite(summary)
          }
        }
      }
    }
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller

}
