import SwiftUI

/// The genre panel's slim, always-visible bar: collapse chevron, title +
/// live node/edge count, an in-flight spinner, and an Analyze (rebuild)
/// button. Stays visible when the panel is collapsed so the graph is always
/// re-discoverable.
///
/// Typography mirrors the established semantic scale (no new scale invented):
/// a `.subheadline` semibold title with a `.caption` secondary count — the
/// same "primary label + quiet metadata" hierarchy `PlaylistHeaderView`
/// uses, tuned one step down because this is a docked utility bar, not a
/// content header.
struct GenreGraphPanelHeader: View {

  // MARK: Internal

  @Binding var collapsed: Bool

  var body: some View {
    HStack(spacing: 8) {
      Button(action: toggleCollapsed) {
        Image(systemName: collapsed ? "chevron.up" : "chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 16, height: 16)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(collapsed ? "Show the genre graph" : "Hide the genre graph")

      Text("Genre Graph")
        .font(.subheadline.weight(.semibold))

      if service.hasLoadedGraph, !service.displayNodes.isEmpty {
        // Inline `LocalizedStringKey` literal (NOT a precomputed `String`)
        // so `^[…](inflect: true)` grammar agreement actually renders —
        // `Text(someString)` is verbatim and would print the markup. Same
        // idiom as `PlaylistHeaderView`'s track count.
        Text(
          "^[\(service.displayNodes.count) genre](inflect: true) · ^[\(service.displayEdges.count) link](inflect: true)"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }

      Spacer(minLength: 8)

      if service.isAnalyzing {
        ProgressView()
          .controlSize(.small)
      }

      Button(action: analyze) {
        Image(systemName: "arrow.triangle.2.circlepath")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Rebuild the genre graph (⌥⌘A)")
      .disabled(service.isAnalyzing)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .contentShape(Rectangle())
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller

  private var service: GenreGraphService {
    controller.genreGraphService
  }

  private func toggleCollapsed() {
    collapsed.toggle()
  }

  private func analyze() {
    Task { await controller.analyzeGenreGraph() }
  }
}
