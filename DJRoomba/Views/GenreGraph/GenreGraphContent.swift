import ForceGraph
import SwiftUI

/// The genre panel's body: the force-directed graph, or the loading / empty
/// state. Kept separate from the panel chrome so the panel only deals with
/// collapse/resize and this only with what's shown inside.
struct GenreGraphContent: View {

  // MARK: Internal

  var body: some View {
    Group {
      if !service.hasLoadedGraph, service.isLoadingGraph {
        ProgressView("Loading genre graph…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if service.displayNodes.isEmpty {
        emptyState
      } else {
        ForceGraphView(
          nodes: service.displayNodes,
          edges: service.displayEdges,
          selection: $selectedGenre,
          onFocusChange: { genre, neighbor in
            // Engine → app: a genre selected / neighbour previewed /
            // snapped back / committed / deselected. Drives the corner
            // card; the `.task(id:)` below reloads (and cancels the
            // prior load) whenever this changes.
            focus = GraphFocus(genre: genre, neighbor: neighbor)
          },
        )
        .overlay(alignment: .topTrailing) {
          if let genre = focus.genre, !associations.isEmpty {
            GenreAssociationsCard(
              genre: genre,
              neighbor: focus.neighbor,
              playlists: associations,
              onOpen: { controller.openAssociatedPlaylist(id: $0.playlistID) },
            )
            .padding(12)
            .transition(.opacity)
          }
        }
        .animation(.easeOut(duration: 0.15), value: associations)
        .task(id: focus) { await reloadAssociations() }
        // Drive the top pane off the COMMITTED selection only (click /
        // search-Return / neighbour-walk commit) — never the hover/
        // preview `focus`. `NodeID` is the genre string here.
        .onChange(of: selectedGenre) { _, newValue in
          if let genre = newValue { controller.showGenre(genre) }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: Private

  /// What the graph is focused on, for the associations card.
  /// `genre == nil` ⇒ nothing selected (card hidden). `neighbor != nil` ⇒
  /// a neighbour is being previewed in the arrow-walk, so the card narrows
  /// to that edge. `Hashable` so it can key `.task(id:)`.
  private struct GraphFocus: Hashable {
    var genre: String?
    var neighbor: String?
  }

  @Environment(MusicController.self) private var controller

  /// The graph's committed selection (search-Return / click / commit).
  /// Bound into `ForceGraphView`; app-local.
  @State private var selectedGenre: NodeID?

  /// Live focus (selection OR neighbour preview) reported by the engine —
  /// distinct from `selectedGenre` because a preview does NOT move the
  /// selection. Drives the card + its reload.
  @State private var focus = GraphFocus()
  @State private var associations = [PlaylistAssociation]()

  private var service: GenreGraphService {
    controller.genreGraphService
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No Genre Relationships Yet", systemImage: "point.3.connected.trianglepath.dotted")
    } description: {
      Text(
        "Genres whose tracks share a playlist appear here. Build it once your library has genre tags — or rebuild it any time."
      )
    } actions: {
      Button("Analyze", action: analyze)
        .disabled(service.isAnalyzing)
    }
  }

  /// (Re)load the corner card for the current focus. Driven by
  /// `.task(id: focus)` so a focus change cancels the in-flight load
  /// before starting the next — the rapid neighbour-walk previews and the
  /// snap-back can't race a stale list onto the card. No genre ⇒ clear.
  private func reloadAssociations() async {
    guard let genre = focus.genre else {
      associations = []
      return
    }
    let result = await service.associatedPlaylists(
      genre: genre,
      neighbor: focus.neighbor,
    )
    guard !Task.isCancelled else { return }
    associations = result
  }

  private func analyze() {
    Task { await controller.analyzeGenreGraph() }
  }
}
