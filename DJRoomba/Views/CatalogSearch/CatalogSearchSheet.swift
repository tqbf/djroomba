import MusicKit
import SwiftUI

/// The Apple Music **catalog** search surface (Phase 2 of
/// `plans/catalog-playlists.md`). Presented as a sheet, deliberately, on
/// the macos-design "appear when needed, get out of the way" axiom and
/// the plan's "subordinate" requirement: the app never *opens* into
/// catalog search (playlists stay first), and a sheet is the native idiom
/// for a focused secondary task with clear in/out semantics — it doesn't
/// permanently steal layout from the sidebar/detail/inspector triad the
/// way a fourth pane would. Rationale per macos-design's
/// `interaction-patterns.md`: search must be prominent **and**
/// dismissible; a sheet is the cleanest realization of that here for
/// a network search (this is **not** filtering visible content — Apple's
/// `.searchable` is the wrong tool — so we render the input ourselves).
///
/// Triggered exclusively from the **Search ▸ Search Apple Music…** menu
/// command (⇧⌘F). ⌘F is already bound by `.searchable` on both the
/// playlist sidebar filter and the track-table filter — using ⇧⌘F avoids
/// the collision (macos-design: standard shortcuts are sacred, derive a
/// shifted variant for a sibling action).
///
/// Debouncer: the pure `CatalogSearchDebouncer.decision(…)` decides
/// `.fire | .wait | .clear` from `(query, lastFired, elapsedMS)`. The
/// view re-asks the decider via `.task(id: query)` + `Task.sleep(for:)`,
/// which gives SwiftUI-native cancellation on each keystroke. No
/// `Combine`, no `Timer`, no `onChange` + stored handle.
///
/// **No inline play of a search result this phase** (Phase 3 owns the
/// playback flip; the dormant `PlaybackResolver` catalog branch is still
/// dormant). The user's action on a result is **Add to Playlist**.
/// Artwork is the placeholder thumbnail until Phase 4 plumbs catalog
/// artwork through `ArtworkProvider` — `ArtworkRef` today is library-only
/// by design (a catalog rendering attempt would fall through to the same
/// placeholder anyway), and showing it here would invite a Phase-4 leak.
struct CatalogSearchSheet: View {

  // MARK: Internal

  @Binding var isPresented: Bool

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        searchField
        Divider()
        resultsBody
      }
      .frame(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 540)
      .navigationTitle("Search Apple Music")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            isPresented = false
          }
          .keyboardShortcut(.cancelAction)
        }
      }
    }
    .task(id: query) {
      await runDebouncer()
    }
    .onDisappear {
      // The user closed the sheet — cancel anything we still owe them so
      // a stale page doesn't land in the service after dismissal.
      Task { await controller.catalogSearch.search("") }
    }
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller
  @FocusState private var searchFieldFocused: Bool

  /// The live text-field value. Distinct from `service.query`, which is the
  /// last *fired* (committed) query — the debouncer commits the gap.
  @State private var query = ""

  /// The last successfully-fired query, so the debouncer can suppress
  /// duplicate fires (rule 3). Mirrors `service.query`, but as @State so
  /// the decider stays a pure function over local inputs.
  @State private var lastFiredQuery: String?

  private var service: CatalogSearchService {
    controller.catalogSearch
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Search by song, artist, or album", text: $query)
        .textFieldStyle(.plain)
        .font(.title3)
        .focused($searchFieldFocused)
        .onSubmit {
          // Return commits the current query immediately, bypassing the
          // debounce — a power-user nicety, the native search-field
          // expectation.
          let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty, trimmed != lastFiredQuery else { return }
          lastFiredQuery = trimmed
          Task { await service.search(trimmed) }
        }
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Clear")
        .accessibilityLabel("Clear search")
      }
      if service.isSearching {
        ProgressView()
          .controlSize(.small)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .onAppear {
      // macos-design + swiftui-pro: a sheet's primary input should auto-
      // focus on first appearance so ⇧⌘F → type → results "just works"
      // with zero extra clicks.
      searchFieldFocused = true
    }
  }

  @ViewBuilder
  private var resultsBody: some View {
    if let error = service.lastError {
      errorRow(error)
    }
    if service.query.isEmpty, !service.isSearching {
      ContentUnavailableView.search
    } else if service.results.isEmpty, !service.isSearching, service.lastError == nil {
      ContentUnavailableView.search(text: query)
    } else {
      resultsList
    }
  }

  private var resultsList: some View {
    List(service.results, id: \.id) { song in
      CatalogSearchResultRow(song: song, isPresented: $isPresented)
    }
    .listStyle(.inset)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if service.hasMore {
        Button {
          Task { await service.loadMore() }
        } label: {
          if service.isSearching {
            ProgressView().controlSize(.small)
          } else {
            Text("Load more")
              .font(.callout)
          }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.bar)
      }
    }
  }

  private func errorRow(_ message: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      Spacer()
      Button("Dismiss", action: service.dismissError)
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.tint)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.regularMaterial)
  }

  /// Debounce window matched to the decider's default. Kept as a local
  /// constant so the view's sleep and the decider's `debounceMS` move
  /// together if either is tuned.
  private static let debounceMS = 250

  private func runDebouncer() async {
    // `.task(id: query)` re-runs (cancelling the prior) on every keystroke
    // — that IS the cancellation source for the sleep. If we make it out
    // of the sleep without cancellation, by construction the user has
    // paused typing for at least `debounceMS` — exactly the elapsed
    // condition the decider tests for. The decider stays a pure function
    // of `(query, lastFired, elapsedMS)`; we wire the timing here.
    do {
      try await Task.sleep(for: .milliseconds(Self.debounceMS))
    } catch {
      // Cancelled by a new keystroke — bail. The next `.task(id:)`
      // iteration owns the decision.
      return
    }
    let decision = CatalogSearchDebouncer.decision(
      for: query,
      lastFiredTerm: lastFiredQuery,
      elapsedSinceLastInputMS: Self.debounceMS,
      debounceMS: Self.debounceMS,
    )
    switch decision {
    case .clear:
      lastFiredQuery = nil
      await service.search("")
    case .wait:
      break
    case .fire(let term):
      lastFiredQuery = term
      await service.search(term)
    }
  }

}
