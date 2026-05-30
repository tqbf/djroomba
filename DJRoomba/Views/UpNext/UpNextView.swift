import SwiftUI

/// The detail surface for the **Up Next** landing
/// (`plans/up-next-queue.md` Phase 2): a header (title + count subtitle
/// + Clear), a Divider, and a `Table(of: TrackRow.self)` populated from
/// the in-memory `UpNextService.entries`. Visually a sibling of
/// `RecentlyPlayedView` — same 20pt-padded header layout, same
/// `ContentUnavailableView` empty-state vocabulary, same boring
/// operational track table — so the user's mental model is "this is
/// another tracks view, the queue".
///
/// macos-design: header right-aligns the destructive Clear so the
/// pane-level action sits where the user expects it on a Mac, never
/// crowding the title. typography-designer: re-uses the app's existing
/// header tiers (`.largeTitle.weight(.bold)` + `.subheadline` secondary)
/// — no new type scales introduced.
///
/// swiftui-pro: the queue is small (~10 entries in the Phase-5 fill
/// model); mapping `entries → [TrackRow]` inline in `body` is cheaper
/// than maintaining an `@State` cache + invalidation hook, and
/// `@Observable` invalidates `body` only when the array actually
/// mutates. `selection` is the table's native `Set<TrackRow.ID>` so
/// shift/⌘ multi-select feed the multi-row context menu actions for
/// free.
struct UpNextView: View {

  // MARK: Internal

  var body: some View {
    let rows = queueRows
    VStack(spacing: 0) {
      header(count: rows.count)
      Divider()
      content(rows: rows)
    }
    // One confirmation dialog mounts at the surface root (not on the
    // Clear button itself) so a confirmation triggered from elsewhere
    // (Phase 3 may add a keyboard shortcut) lands here too.
    .confirmationDialog(
      "Clear Up Next?",
      isPresented: $showClearConfirm,
      titleVisibility: .visible,
    ) {
      Button("Clear", role: .destructive) {
        controller.clearUpNext()
      }
      Button("Cancel", role: .cancel) { }
    } message: {
      Text("This removes every track from the queue. The queue can't be undone.")
    }
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller
  @State private var selection = Set<TrackRow.ID>()
  @State private var showClearConfirm = false

  /// Map every queued entry to a 1-based `TrackRow` so the existing
  /// boring `Table(of: TrackRow.self)` renders it identically to a
  /// playlist track list. The `Song` snapshot stored on each entry is
  /// what we render against (denormalised at add-time on purpose —
  /// `plans/up-next-queue.md` "Denormalised on purpose"), so the queue
  /// table doesn't need any per-row store fetch. Per-row play-stats
  /// (`playCount` / `lastPlayedAt`) are deliberately omitted: the
  /// `Song`'s in-row stats aren't populated for queue entries (Phase
  /// 1's `UpNextService` stores the bare song), matching the empty
  /// "—" / 0 treatment a never-played song already gets in
  /// `RecentlyPlayedRow`'s mapping.
  private var queueRows: [TrackRow] {
    controller.upNext.entries.enumerated().map { offset, entry in
      TrackRow(song: entry.song, position: offset + 1)
    }
  }

  /// Title + count, mirroring `RecentlyPlayedView.header` so the two
  /// landings read as siblings (same 20pt inset, same type tiers, same
  /// trailing slot for actions). The destructive `Clear` lives trailing
  /// — pane-level actions belong on the right on a Mac — and is bordered
  /// (`role: .destructive` colours it red) rather than borderedProminent;
  /// we reserve prominent for play/commit elsewhere in the app.
  private func header(count: Int) -> some View {
    HStack(alignment: .bottom, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Up Next")
          .font(.largeTitle.weight(.bold))
          .lineLimit(1)
        Text(subtitle(count: count))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Button("Clear", role: .destructive) {
        showClearConfirm = true
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .disabled(count == 0)
    }
    .padding(20)
  }

  /// The header's secondary line. A `LocalizedStringKey` (NOT `String`)
  /// so `Text` applies automatic grammar agreement —
  /// `Text(someString)` is the verbatim initializer and would render
  /// the `^[…](inflect:)` markup literally.
  private func subtitle(count: Int) -> LocalizedStringKey {
    guard count > 0 else { return "Empty — add tracks via the assistant or right-click any song" }
    return "^[\(count) track](inflect: true)"
  }

  @ViewBuilder
  private func content(rows: [TrackRow]) -> some View {
    if rows.isEmpty {
      ContentUnavailableView(
        "No Up Next Tracks",
        systemImage: "text.line.first.and.arrowtriangle.forward",
        description: Text(
          "Right-click a track and choose Add to Up Next, "
            + "or ask DJ Roomba to queue something."
        ),
      )
    } else {
      table(rows: rows)
    }
  }

  private func table(rows: [TrackRow]) -> some View {
    // Unlike `TrackTableView`, the queue table is **inherently
    // ordered** by play position — re-sorting it by clicking a column
    // header would actively mislead about play order. No
    // `KeyPathComparator` / `sortOrder` binding therefore, and the
    // columns are content-only (no `value:`) so the headers render but
    // can't be clicked to re-sort.
    Table(of: TrackRow.self, selection: $selection) {
      TableColumn("#") { row in
        Text(row.position, format: .number)
          .font(.body.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .width(36)

      TableColumn("Title") { row in
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
      }

      TableColumn("Artist") { row in
        Text(row.artistName)
          .font(.body)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      TableColumn("Album") { row in
        Text(row.albumTitle ?? "—")
          .font(.body)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      TableColumn("Time") { row in
        Text(row.duration?.musicTimeText ?? "—")
          .font(.body.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .width(56)
    } rows: {
      // No `.draggable` here — drag-to-reorder is a Phase-3 polish
      // item per the plan ("Drag-to-reorder. v1 supports Move to Top +
      // Remove."). The context menu is the v1 reorder surface.
      ForEach(rows) { row in
        TableRow(row)
      }
    }
    .tableStyle(.bordered(alternatesRowBackgrounds: true))
    .tableColumnHeaders(.visible)
    .contextMenu(forSelectionType: TrackRow.ID.self) { ids in
      contextMenu(for: ids, in: rows)
    } primaryAction: { ids in
      // Double-click → play that row. Same dominance semantics as the
      // single-select "Play" menu item: everything above the picked
      // row is consumed.
      guard
        let id = ids.first,
        let row = rows.first(where: { $0.id == id })
      else { return }
      Task { await controller.playFromUpNext(position: row.position) }
    }
  }

  @ViewBuilder
  private func contextMenu(for ids: Set<TrackRow.ID>, in rows: [TrackRow]) -> some View {
    let picked = rows.filter { ids.contains($0.id) }
    if !picked.isEmpty {
      if picked.count == 1, let row = picked.first {
        Button("Play", systemImage: "play.fill") {
          Task { await controller.playFromUpNext(position: row.position) }
        }
      }
      Button("Move to Top", systemImage: "arrow.up.to.line") {
        controller.moveToTopOfUpNext(positions: picked.map(\.position))
        // Clear the selection because the row ids are
        // position-derived — after a move the picked ids no longer
        // match any visible row.
        selection.removeAll()
      }
      Divider()
      Button(
        "Remove from Up Next",
        systemImage: "minus.circle",
        role: .destructive,
      ) {
        controller.removeFromUpNext(positions: picked.map(\.position))
        selection.removeAll()
      }
    }
  }
}
