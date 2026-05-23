# Genre editing — rename/merge + assign to selected tracks

Two edits over the existing `song.genre_names` v4 JSON column. Local-first,
no MusicKit, **no schema change**, batch SQLite idioms, song-only one-way
isolation (playlists / app playlists / history / stats / favorites /
recents are never touched). Pure transform unit-tested; UI computer-use
verified.

## 1. Rename the browsed genre (merge on collision)

When a genre is shown in the top pane (`detail.isGenre`), the header gets
a **"Rename" button** beside Play (discoverable, native — same tier as the
existing playlist rename; a context-menu-only action on a header would be
hidden). It opens a modal `GenreNameSheet` (the proven `RenamePlaylistSheet`
shape: lone first responder, name pre-filled + select-all, ⏎ commits, ⎋
cancels — Finder/Music idiom).

**Merge is implicit and automatic.** Genres are literal tag matches
(`TRIM(je.value) = ?`), not entities. Renaming `A → B` rewrites every
song's `genre_names`: each element trimming-equal to `A` becomes `B`, then
the array is **de-duplicated preserving first-occurrence order**. A song
that had both `A` and `B` ends up with one `B`; the genre query for `B`
afterward returns the union of old-`A` and old-`B` songs — that *is* the
merge, with zero special-casing. Renaming to a brand-new name is just the
degenerate no-collision case of the same operation.

## 2. Multi-select tracks → assign a genre

The track `Table`'s selection becomes `Set<TrackRow.ID>` (was a single
`TrackRow.ID?`). Native macOS `Table` then gives shift-click range and
⌘-click point multi-select for free; `.contextMenu(forSelectionType:)`
already resolves the selected rows. A new **"Add to Genre ▸"** context
submenu (sibling of the existing "Add to Playlist ▸"):

- `New Genre…` → the same `GenreNameSheet` (empty seed) → assign the typed
  name to every selected song.
- `Divider()` then the existing genres (from `LibraryStore.distinctGenres`,
  alphabetical, `localizedStandardContains`-free plain list — same
  unbounded-but-fine shape as "Add to Playlist"'s app-playlist list; macOS
  menus scroll). Picking one assigns it.

Assign = append the genre to each selected song's `genre_names` **iff not
already present** (trim-compare); songs already carrying it are unchanged
(idempotent, no duplicates).

## Pure core — `GenreEdit` (no DB, unit-tested)

The codebase's established pure-decider pattern (`MetadataMatcher`,
`ImportActivity`, `DetailNavStack`):

- `renaming(_ names:[String], from:String, to:String) -> [String]?` —
  trim-compare match, replace with the trimmed `to`, dedupe preserving
  order, drop empties; returns `nil` when nothing changes (so only changed
  rows are written and the "N updated" count is honest).
- `adding(_ names:[String], _ genre:String) -> [String]?` — append trimmed
  `genre` unless a trimming-equal element already exists; `nil` if
  unchanged.

`DetailNavStack.replacingGenre(_ old:, with new:)` keeps the in-session
Back stack coherent after a rename (a `.genre(old)` entry becomes
`.genre(new)`), unit-tested with the rest of the pure stack.

## Store — `LibraryStore` (batch, song-only)

- `distinctGenres() -> [String]` — one read: `json_each` over
  `genre_names`, `json_valid`-guarded, `DISTINCT TRIM(value)`, non-empty,
  `ORDER BY … COLLATE NOCASE`. Same json idiom as `songsWithStats
  (matchingGenre:)` / `associatedPlaylists`.
- `renameGenre(from:to:) -> Int` — read the songs whose `genre_names`
  contains `from` (the `EXISTS(json_each …)` idiom), apply
  `GenreEdit.renaming` in Swift, write the changed rows.
- `addGenre(_:toSongIDs:) -> Int` — read those songs by id (`IN`-list,
  chunked), apply `GenreEdit.adding`, write the changed rows.
- Both funnel writes through one private chunked
  `WITH v(id, genre_names) AS (VALUES …) UPDATE song SET genre_names =
  v.genre_names FROM v WHERE song.id = v.id` (the column-named-CTE form —
  SQLite rejects `AS alias(cols)` on `(VALUES …)`; ≥3.33, fine on macOS
  14), `Song.encodeGenreNames` so JSON round-trips identically to import.
  ≤2 binds/row ⇒ ~499 rows/chunk. One write txn each; touches **only**
  `song`. A new `GenreEditIsolationTests` pins the one-way invariant
  exactly like the other store-isolation tests.

## Controller / UI wiring

- `MusicController.allGenres: [String]` — observable mirror, reloaded from
  `distinctGenres()` on session start and after any genre edit / import
  (mirrors the `appPlaylists` pattern; the context submenu reads it).
- `renameSelectedGenre(to:)` — guard `selectedGenre`, trim, no-op if
  unchanged; `store.renameGenre`; then **in-place** re-point the genre view
  to the new name (it's a rename, not a navigation: `suppressNavRecording`,
  rewrite the Back stack `old→new`), `reloadAfterGenreEdit()`.
- `addGenre(_:toSongs:)` — `store.addGenre`; `reloadAfterGenreEdit()`.
- `reloadAfterGenreEdit()` — `library.load()` (playlist header chips can
  change) + `detailService.invalidateAll()` + re-select current view +
  `rebuildDerivedSummaries()` + reload `allGenres` +
  `reanalyzeGenreGraphIfEnabled()` (the graph is rebuilt wholesale, so the
  merge collapses the nodes automatically — same trigger `runImport` uses).
- `GenreNameRequest` (`Identifiable`) on the controller drives a single
  `.sheet(item:)` hosted by `PlaylistDetailView` (always present for any
  detail; assign works from any playlist's track table, not only a genre
  view), bound via `@Bindable` (no `Binding(get:set:)`).

## Title-click-vs-drag fix (the tracked follow-up — DONE)

The track `Table` previously put `.draggable(SongDragItem)` on the
**Title cell**. A per-cell drag gesture competes with the table's row
gesture, so a plain click on the title never selected the row (selection
only worked from other columns) — found in the first computer-use pass,
and a real blunting of the new multi-select since the title is the
obvious click target.

**Fix:** moved the drag to the **row**. `TrackTableView` now uses the
`Table(of:selection:sortOrder:){ columns } rows: { ForEach(tracks) {
TableRow($0).draggable(SongDragItem(songID:)) } }` form. Row-level
`.draggable` integrates with the table's own gesture (click → select,
press-drag → drag) so the title click selects, and a drag of any
selected row carries a `SongDragItem` for **every** selected row — so
dragging a multi-selection onto a "My Playlists" row adds them all (the
existing `.dropDestination(for: SongDragItem.self)` already maps
`[SongDragItem]`; the drag contract is unchanged). The custom
`music.note` drag-preview label is intentionally dropped — the system
row snapshot is the more Finder/Music-native drag image. Column-header
sort, `.contextMenu(forSelectionType:)` and `primaryAction` are
unaffected (they attach to the `Table`). Computer-use verified: clicking
a track's Title selects it; dragging a track **by its Title** onto a
playlist still adds it (0 → 1 track).

## Out of scope

Genre delete (rename-to-empty is rejected; deleting a genre = a separate
ask). Per-occurrence genre order editing. Fuzzy/related merge (literal tag
match only — same semantics the graph already uses). Renaming a genre is
not undoable beyond the normal app flow (the snapshot-export/revert feature
on its own branch is the heavy-undo story; intentionally separate).
