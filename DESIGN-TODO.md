# Design TODO — deferred cleanup phases

Backlog from the Thomas' Laws cleanup pass (2026-05-16). Phase A
(app-playlist mutation chokepoint — `MusicController.mutateAppPlaylist`)
**shipped**; the two phases below were proposed, accepted as worth
recording, and deferred. Each is independent and pickable à la carte. The
falsifiable freight claim and the veto condition are the contract: if a
phase can't land while keeping its freight claim true and its veto clause
respected, **don't do it** — reverting/declining is the correct outcome.

## Phase B — Extract the chunked multi-row INSERT ceremony in `LibraryStore`

- **What:** `replaceApplePlaylistSnapshot`, `addSongsToAppPlaylist`,
  `setAppPlaylistTracks`, and the private `renumberAppPlaylist` each
  hand-roll the identical "build `(?, ?, ?)` placeholders × chunk, flatten
  the args array, `db.execute`" block. Extract one narrowly-scoped private
  helper for the **plain** `INSERT … VALUES` sites only.
- **Law(s):** 11 / 12 (≈4 byte-similar copies of the same SQL glue).
- **Pays its freight (falsifiable):** 4 copies of the
  placeholder/argument-flatten ritual → 1 helper; checkable by call-site
  count and the deleted line count in `LibraryStore.swift`.
- **Veto condition (Law 0 / 13):** if the helper has to grow parameters to
  also absorb the `ON CONFLICT … DO UPDATE` upsert (`upsertSongs`) or the
  `CASE id WHEN … END` reorder, **stop** — that turns a focused helper
  into a general/specialized hybrid that adds more complexity than the
  duplication costs. Scope it to the four pure `INSERT … VALUES` sites or
  do not do it.
- **Risk:** low–medium. **Depends on:** none. **Effort:** M.
- **Verify:** the four methods lose their inline placeholder/args loops;
  `BatchImportTests`, `AppPlaylistCRUDTests`, `SnapshotReplaceTests` green;
  `swiftformat --lint` + `swiftlint` clean.

## Phase C — Hoist `PlaylistSidebarList` filtering out of `body`

- **What:** `PlaylistSidebarList.body` still runs 4 `filtered(...)` passes
  per render (the one residual the memory-and-laziness Phase A did not
  reach). Move the filtered results to `@State`, recomputed via `onChange`
  of the four source arrays + `filterText`.
- **Law(s):** swiftui-pro "no filter in `body`" / the memory-and-laziness
  Phase-A acceptance ("zero scans per sidebar render").
- **Pays its freight (falsifiable):** sidebar render does zero filter
  passes; checkable with a `body`-work counter/signpost showing constant
  work per keystroke instead of 4 O(n) passes.
- **Risk:** low–medium — the freight is **thin**: the source arrays are
  ≤~270 tiny structs, the filter is O(n) and only runs while the filter
  field is non-empty, and the `onChange` wiring (4 sources + text) adds
  real complexity. **Recommendation: do NOT do this** unless the sidebar
  measurably lags on the known huge multi-day library; otherwise it is
  churn that nets complexity for an imperceptible gain (Law 0).
- **Depends on:** none. **Effort:** S.
- **Verify:** body-work counter constant per keystroke; no visual diff;
  `swift test` green.

## Explicitly evaluated and decided AGAINST (do not re-propose without a new trigger)

- **Decompose `rebuildDerivedSummaries()` into per-collection rebuilds
  now.** It is the memory-and-laziness plan's stated *forward* pattern but
  is premature today: every current mutation legitimately touches multiple
  collections (a favorite toggle hits `favoritePlaylists`, the
  `isFavorite` overlay on `appPlaylists`, and `allSummaries`), so
  splitting now adds methods + "which rebuild do I call" routing for zero
  present benefit. The single rebuild is currently the *simpler* design.
  Trigger to revisit: a new feature whose write provably touches exactly
  one collection and is hot.
- **Inject `ArtworkProvider.shared` via `@Environment`.** It is a
  singleton reached directly from `ArtworkThumbnail` (Law 1), but its
  perf justification (one fetch per id per process, concurrent-dedupe)
  genuinely needs process-wide sharing; the actor is correct and now
  FIFO-bounded. Environment injection is more ceremony for no real win.
- **Reactive store / GRDB `ValueObservation`.** Already prototyped,
  rejected, and documented with rationale in
  `plans/memory-and-laziness.md` (Phase C). Settled — single-writer makes
  its only unique benefit moot.

## Phase D — Genre Metro Map: extract `GenreMapPanel` subviews to their own files

- **What:** `GenreMapPanel` is ~400 LOC with `header`/`footer`/`content`/
  `emptyState`/`mapBody`/`hullsCanvas`/`edgesCanvas`/`labelsLayer` all as
  computed `some View` properties. Extract each into its own `View`
  struct in its own file (project convention: one type per file; swiftui-
  pro: strongly prefer over computed-property splits).
- **Law(s):** 4 (head-juggling) + project convention.
- **Pays its freight (falsifiable):** longest file in
  `DJRoomba/Views/GenreMap/` drops from ~400 → ~150 LOC; future Phase
  2/3/5 edits touch one focused file per UI concern.
- **Risk:** medium — Canvas redraw scope is per-View, so extraction can
  shift perf either way; measure under drag before and after.
- **Veto condition:** if extraction visibly drops drag-frame perf or
  forces escaping-closure ceremony to pass `transform`/`model` around,
  STOP — the current shape is fine, this is preference not a bug.
- **Depends on:** none. **Effort:** M.
- **Verify:** screenshot diffing identical pre/post; drag at default
  zoom feels the same; new files compile with no `swiftui-pro` flags.

## Phase E — Genre Metro Map: consolidate the v6/v7 trigger funnel (Phase-6 work)

- **What:** Today `MusicController.reanalyzeGenreGraphIfEnabled()` fires
  both `rebuildGenreGraph` and `rebuildGenreMap` in sequence (the latter
  reads the former's `genre_edge`). Phase 6 of `plans/genre-metro-map.md`
  consolidates: one shared `runMapRebuildIfEnabled()` funnel, retiring
  the separate v6 `analyzeGenreGraph` keyboard shortcut + menu item once
  the metro view supersedes the genre-graph panel.
- **Law(s):** 10 (temporal coupling — 2 modules in concert per analyse).
- **Pays its freight (falsifiable):** trigger sites call ONE method;
  `MusicController.analyzeGenreGraph` + `analyzeGenreMap` collapse to
  one (or the v6 path is retired entirely).
- **Risk:** medium — touches every trigger point + the menu + the
  preference key.
- **Veto condition:** if Phase 5 hover-evidence still needs the v6
  panel as a standalone surface, hold.
- **Depends on:** Phase 6 of `plans/genre-metro-map.md` (the master
  plan), and ideally Phase 5 landed first.
- **Effort:** M.
- **Verify:** grep shows zero direct calls to `analyzeGenreGraph`
  outside the funnel; the v6 menu item is removed; existing test
  suite green.

## Phase F — Genre Metro Map: cache scroll-wheel + ⌘=/⌘-/⌘0 zoom shortcuts

- **What:** The current zoom surface is a footer stepper + pinch
  gesture. Native macOS map UX adds `⌘=` / `⌘-` / `⌘0` (Fit) keyboard
  shortcuts and scroll-wheel zoom-around-cursor. macos-design called
  these out at the Phase 1 gate.
- **Law(s):** macos-design idiom alignment (not a Thomas-Law cleanup).
- **Pays its freight (falsifiable):** three shortcuts wired; a
  scroll-wheel gesture on the map body zooms toward the cursor
  position; the existing pinch+stepper paths still work.
- **Risk:** low.
- **Depends on:** none.
- **Effort:** S.
- **Verify:** ⌘=/⌘-/⌘0 work in the panel; scroll-wheel zooms; no
  regression on pinch or stepper.
