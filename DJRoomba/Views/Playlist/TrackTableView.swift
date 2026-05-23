import SwiftUI

/// Deliberately boring, operational track table (native `Table`). Double-click
/// or Return on a row plays the playlist starting at that track. `.searchable`
/// filters the visible tracks (⌘F focuses it).
struct TrackTableView: View {

  // MARK: Internal

  let detail: PlaylistDetail

  var body: some View {
    let tracks = displayedTracks

    Group {
      if tracks.isEmpty {
        ContentUnavailableView.search(text: trackFilter)
      } else {
        Table(of: TrackRow.self, selection: $selection, sortOrder: $sortOrder) {
          TableColumn("#", value: \.position) { row in
            Text(row.position, format: .number)
              .font(.body.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .width(36)

          TableColumn("Title", value: \.title) { row in
            HStack(spacing: 6) {
              Text(row.title)
                .font(.body)
                .lineLimit(1)
              if row.isExplicit {
                Image(systemName: "e.square.fill")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .accessibilityLabel("Explicit")
              }
            }
            // NOTE: the drag source is the **row** (the `rows:` builder
            // below), NOT this cell. A per-cell `.draggable` installs a
            // drag gesture that competes with the table's row gesture, so
            // a plain click on the title never selected the row (the
            // computer-use finding) — selection only worked from other
            // columns. Row-level `.draggable` integrates with the table's
            // own gesture: a click selects, a press-drag drags, and the
            // drag carries the whole multi-selection.
          }

          TableColumn("Artist", value: \.artistName) { row in
            Text(row.artistName)
              .font(.body)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          TableColumn("Album", value: \.albumSortKey) { row in
            Text(row.albumTitle ?? "—")
              .font(.body)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          TableColumn("Time", value: \.durationSortKey) { row in
            Text(row.duration?.musicTimeText ?? "—")
              .font(.body.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .width(56)

          // Phase 4: play stats, sortable. "Plays" reuses the
          // numeric-column tier (monospaced + secondary, like #/Time);
          // "Last Played" reuses the secondary text tier (like
          // artist/album). No new type roles introduced.
          TableColumn("Plays", value: \.playCount) { row in
            Text(row.playCount, format: .number)
              .font(.body.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .width(52)

          TableColumn("Last Played", value: \.lastPlayedSortKey) { row in
            Text(Self.lastPlayedText(row.lastPlayedAt))
              .font(.body)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .width(100)
        } rows: {
          // Explicit `rows:` builder so the drag source is the ROW, not a
          // cell (see the Title column note). `.draggable` on `TableRow`
          // plays nicely with the table's selection gesture — click
          // selects, press-drag drags — and a drag of any selected row
          // carries a `SongDragItem` for EVERY selected row, so dragging
          // a multi-selection onto a "My Playlists" sidebar row adds them
          // all (the existing `.dropDestination(for: SongDragItem.self)`
          // already maps `[SongDragItem]`). The system uses the native
          // row snapshot as the drag image (more Finder/Music-like than
          // the old custom `music.note` label, which is intentionally
          // dropped). `tracks` is the already filtered+sorted
          // `@State` cache, so this `ForEach` adds no per-`body` work.
          ForEach(tracks) { row in
            TableRow(row)
              .draggable(SongDragItem(songID: row.songID))
          }
        }
        // Native macOS track-list treatment (Music.app / Finder):
        // flat full-width alternating row striping that fills the
        // empty space below the last track — NOT the default inset
        // style, whose rounded "pill" row shapes were being drawn
        // for every empty row below the content (the D2 defect).
        // `.bordered` is flat-edged; combined with the standard
        // alternating backgrounds the unused area reads as a clean
        // continuation of the table, the way Apple's apps do it.
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .tableColumnHeaders(.visible)
        .contextMenu(forSelectionType: TrackRow.ID.self) { ids in
          TrackContextMenu(
            rows: tracks.filter { ids.contains($0.id) },
            detail: detail,
          )
        } primaryAction: { ids in
          guard
            let id = ids.first,
            let row = tracks.first(where: { $0.id == id })
          else { return }
          Task { await controller.play(row) }
        }
      }
    }
    .searchable(text: $trackFilter, prompt: "Filter Tracks")
    // Recompute the filtered+sorted rows OUT of `body` (swiftui-pro:
    // assume `body` runs often; move sort/filter out). These three
    // `onChange`es ARE the explicit invalidation for the `@State`-cached
    // derived collection — it re-derives exactly on a content change
    // (`detail.revision`, incl. a same-id stats refresh), a filter
    // keystroke, or a column-header sort, and NOT on an unrelated
    // observable tick (e.g. the 0.5 s now-playing snapshot). `initial`
    // on the revision hook seeds the first render.
    .onChange(of: detail.revision, initial: true) { recomputeDisplayedTracks() }
    .onChange(of: trackFilter) { recomputeDisplayedTracks() }
    .onChange(of: sortOrder) { recomputeDisplayedTracks() }
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller
  /// A `Set` (not a single optional) so the native `Table` gives
  /// shift-click range + ⌘-click point multi-select for free — what the
  /// "Add to Genre ▸" / "Add to Playlist ▸" context actions operate on.
  @State private var selection = Set<TrackRow.ID>()
  @State private var trackFilter = ""
  /// Native column-header sorting. Defaults to playlist order (`position`),
  /// so an unsorted table looks exactly as before; clicking "Plays" /
  /// "Last Played" (or any column header) re-sorts in place.
  @State private var sortOrder = [KeyPathComparator(\TrackRow.position)]
  /// The rendered rows: `detail.tracks` filtered (⌘F) then sorted by the
  /// active column comparator. `@State`-cached and recomputed only by the
  /// `onChange` hooks above — never in `body`. Sorting in memory stays
  /// fine for normal playlists (rows are fetched once per selection, stats
  /// joined in that one query, so no SQLite re-hit to re-sort); a single
  /// genuinely huge playlist is the deferred Phase-D (SQL-side) case.
  @State private var displayedTracks = [TrackRow]()

  /// "Last Played" cell text. Relative ("2 days ago") for played songs,
  /// an em-dash for never-played — matching the table's "—" nil idiom.
  private static func lastPlayedText(_ date: Date?) -> String {
    guard let date else { return "—" }
    return date.formatted(.relative(presentation: .named))
  }

  private func recomputeDisplayedTracks() {
    let filtered: [TrackRow] =
      if trackFilter.isEmpty {
        detail.tracks
      } else {
        detail.tracks.filter {
          $0.title.localizedStandardContains(trackFilter)
            || $0.artistName.localizedStandardContains(trackFilter)
            || ($0.albumTitle?.localizedStandardContains(trackFilter) ?? false)
        }
      }
    displayedTracks = filtered.sorted(using: sortOrder)
  }

}
