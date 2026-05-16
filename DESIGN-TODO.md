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
