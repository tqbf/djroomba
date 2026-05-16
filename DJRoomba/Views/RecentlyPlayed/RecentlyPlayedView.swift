import SwiftUI

/// The app's landing surface when no playlist is selected: a native macOS
/// "Recently Played" scroll — distinct songs, newest play first, lazily
/// keyset-paginated as the user scrolls. Double-click / Return plays from
/// that song, with the loaded list as the queue context (Next/Prev walk
/// it).
///
/// macos-design: a single-purpose browse surface — header + a full-width
/// `List` of rich rows, no sidebar/toolbar chrome of its own (it lives in
/// the detail column). Sub-states use `ProgressView` /
/// `ContentUnavailableView`, the same vocabulary as the playlist detail.
///
/// swiftui-pro: `rows` changes only on explicit load / scroll / seed /
/// reload (the service is `@Observable` but is NOT driven by the 0.5 s
/// now-playing tick), so this view is not coupled to playback state. The
/// lazy-load trigger and selection are the only local state; derivation is
/// kept out of `body`.
struct RecentlyPlayedView: View {

  // MARK: Internal

  var body: some View {
    // Read once per render; the service is `@Observable` so `body` re-runs
    // only when its `rows` / `isLoading` / `loadError` change (explicit
    // load / scroll / seed / reload) — never on the 0.5 s now-playing tick
    // (the service is independent of `playback`). No `@Bindable`: the only
    // binding here is `$selection` on local `@State`.
    let service = controller.recentlyPlayed

    VStack(spacing: 0) {
      header
      Divider()
      content(service)
    }
    // Load page 1 only when the long-lived service has nothing yet
    // (first appearance, or after the surface was emptied). Returning
    // from a playlist must NOT reset — an unconditional reload here
    // would discard the user's scroll position and every paged-in row
    // each time they bounce to a playlist and back. A genuine data
    // change re-shows from the top through its own explicit path:
    // `MusicController.seedSyntheticHistory` already calls
    // `recentlyPlayed.reload()`. `.task` (not `.onAppear`) so the load
    // is cancelled if the surface goes away mid-fetch.
    .task {
      if service.rows.isEmpty {
        service.loadFirstPage()
      }
    }
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller
  @State private var selection: TrackRow.ID?
  @FocusState private var listFocused: Bool

  /// Title + count, matching `PlaylistHeaderView`'s treatment (same type
  /// tiers, same 20pt inset) so the landing surface reads as a sibling of
  /// the playlist header, not a new visual language (typography-designer /
  /// macos-design).
  private var header: some View {
    HStack(alignment: .bottom, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Recently Played")
          .font(.largeTitle.weight(.bold))
          .lineLimit(1)
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(20)
  }

  /// The header's secondary line. A `LocalizedStringKey` (NOT `String`) so
  /// `Text` applies automatic grammar agreement — `Text(someString)` is the
  /// verbatim initializer and would render the `^[…](inflect:)` markup
  /// literally. Built out of `body` (swiftui-pro).
  private var subtitle: LocalizedStringKey {
    let count = controller.recentlyPlayed.rows.count
    guard count > 0 else { return "Songs you play show up here" }
    return "^[\(count) song](inflect: true)"
  }

  @ViewBuilder
  private func content(_ service: RecentlyPlayedService) -> some View {
    if service.isLoading, service.rows.isEmpty {
      ProgressView("Loading…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if service.loadError != nil, service.rows.isEmpty {
      ContentUnavailableView {
        Label("Couldn't Load Recently Played", systemImage: "exclamationmark.triangle")
      } description: {
        Text(service.loadError ?? "")
      } actions: {
        Button("Try Again") { service.loadFirstPage() }
      }
    } else if service.rows.isEmpty {
      ContentUnavailableView(
        "No Recently Played",
        systemImage: "clock.arrow.circlepath",
        description: Text("Songs you play will show up here."),
      )
    } else {
      list(service)
    }
  }

  private func list(_ service: RecentlyPlayedService) -> some View {
    List(service.rows, selection: $selection) { row in
      RecentlyPlayedRow(row: row)
        // Lazy keyset pagination: each appearing row asks the service
        // whether it's near the end; the service no-ops unless it is
        // (and unless there's more / nothing already loading).
        .onAppear { service.loadMoreIfNeeded(currentRowID: row.id) }
        .onTapGesture(count: 2) {
          selection = row.id
          Task { await controller.playRecentlyPlayed(startAt: row) }
        }
    }
    // Native macOS track-list treatment (Music.app / Finder): flat,
    // full-width, alternating row striping that fills the empty space
    // below the last row — the same idiom (and rationale) as the
    // playlist track table's `.bordered(alternatesRowBackgrounds:)`.
    .listStyle(.bordered(alternatesRowBackgrounds: true))
    .focused($listFocused)
    .onKeyPress(.return) {
      guard
        listFocused,
        let id = selection,
        let row = service.rows.first(where: { $0.id == id })
      else { return .ignored }
      Task { await controller.playRecentlyPlayed(startAt: row) }
      return .handled
    }
  }
}
