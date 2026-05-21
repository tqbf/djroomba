import SwiftUI

/// The detail column's composition. After the Genre Tree shipped
/// (`plans/son-of-genre-map.md`) the genre visualization moved out
/// of a docked bottom-pane (the retired `GenreGraphPanel` ForceGraph)
/// and into the full-canvas sheet toggled by the toolbar's Genre
/// Tree button (⌥⇧⌘A). The detail column is now just the playlist
/// detail / Recently Played landing surface; the visualization
/// surfaces on demand instead of permanently occupying the player.
struct DetailPaneView: View {
  var body: some View {
    PlaylistDetailView()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
