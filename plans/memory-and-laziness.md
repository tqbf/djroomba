# Memory & laziness — keep the UI spry on a tiny resident set

> Goal: SQLite is the fast source of truth, so the app should hold **almost
> nothing** resident and re-derive from the DB on demand — *without* the UI
> getting laggy or stale. This plan separates the two real problems (an
> **unbounded cache** and **per-render recomputation**) from a non-problem
> (one playlist's rows), and stages fixes lowest-risk first.

## TL;DR of the evaluation

The app does **not** load the whole library's tracks into memory today — it
loads one playlist's tracks at a time. The actual issues are narrower:

1. **Unbounded detail cache.** `PlaylistDetailService.cache`
   (`PlaylistDetailService.swift:79`) is a `[String: PlaylistDetail]` that
   keeps every playlist ever selected, evicted only by an all-or-nothing
   `invalidate()` (`:72`). Browse the whole library → the whole library's
   `TrackRow`s become resident. This is the one true "library in memory" leak.
2. **Per-render recomputation (the real "spry" tax).** `MusicController`
   exposes derived collections as **computed properties** rebuilt on every
   SwiftUI `body` evaluation of any view that reads them:
   - `allSummaries` (`:73`) allocates a fresh concatenation every access.
   - `recentPlaylists` (`:149`) is **O(recents × allSummaries)** (nested
     `compactMap`/`first`) + that concat, every body.
   - `favoritePlaylists` (`:143`), `appPlaylists` (`:134`),
     `selectedSummary` (`:122`), `sidebarState` (`:109`, reads `allSummaries`
     twice) — all O(n) + concat, every body.
   - `PlaylistSidebarList.body` (`PlaylistSidebarList.swift:13-21`) calls
     four of these and then `filtered(...)` over each → ~5 concatenations +
     several O(n·m) scans + 4 filter passes **per sidebar render**, and the
     sidebar re-renders on every filter keystroke and selection change.
   - `TrackTableView` filters **and** sorts the full `detail.tracks` array
     **inside `body`** (`TrackTableView.swift:130-141`) — swiftui-pro
     explicitly flags sort/filter in `body`.
3. **No reactive store.** Freshness is a manual `invalidate()` +
   `library.load()` + `reconcileSelectionAfterImport()` choreography
   (`MusicController.swift:417-436`, `563-568`). "Minimize residency" is only
   safe if re-reads are cheap *and* pushed; today they're hand-wired, which
   is why the cache exists as a crutch and why `invalidate()` is all-or-nothing.
4. **Latent footgun.** `LibraryStore.allSongs()` (`LibraryStore.swift:174`)
   materializes the entire `song` table into `[Song]`. **No app-code caller
   today** (only import/tests touch `.tracks`). It must never become the
   backing of an "All Songs"/catalog view as written.
5. **Minor unbounded growth.** `ArtworkProvider`'s process-wide cache +
   negative cache grow without a ceiling over a long browsing session
   (handles are small and MusicKit owns the bitmap LRU, so low severity).

Resident summaries (`LibraryReadService.summaries` ≈ 270 tiny structs,
`AppPlaylistService.summaries`, `favoriteIDs`, `recentIDs`) are **not** a
memory problem and a sidebar genuinely needs all rows to render — the cost
there is the *recomputation over them*, addressed by Phase A. Do not
"lazy-load" the sidebar; that would add complexity for no real saving and
hurt scroll/selection feel (macos-design).

Guiding principle (reconciles "ruthlessly minimize" with swiftui-pro's "do
not cache derived collections without explicit invalidation, and `body` is
hot"): **resident set = the visible working set, derived once on input
change, never in `body`.** Re-derivation reads from SQLite (fast) at a
single mutation chokepoint — *not* from an ever-growing in-process mirror,
and (decided after evaluation — see Phase C) *not* via `ValueObservation`:
single-writer-forever makes a synchronous chokepoint the cheaper, race-free
way to get the same "never stale" property.

## Phase A — Stop recomputing in `body` (pure spry win, no behavior change)

Lowest risk, biggest perceived-latency win, **no schema change, no store
change**. Convert the derived collections from per-`body` computed properties
into stored `@Observable` state recomputed **only when their inputs change**.

- In `MusicController`, replace the computed `allSummaries`, `appPlaylists`,
  `favoritePlaylists`, `recentPlaylists`, `selectedSummary`, and the
  summary-existence parts of `sidebarState` with stored properties plus a
  single private `rebuildDerivedSummaries()` invoked from the points that
  already mutate the inputs: after `library.load()`, after
  `appPlaylistService.load()`, in `reloadFavoritesAndRecents()`,
  `toggleFavorite` (optimistic path), `recordRecentlyPlayed`, and the
  `selectedPlaylistID` `didSet`.
- Maintain a `summariesByID: [String: PlaylistSummary]` index so
  `selectedSummary`, `handle(.playPlaylist/.playTrack)`,
  `reconcileSelectionAfterImport`, and `restoreSelection` become O(1) instead
  of O(n) scans over a freshly concatenated array.
- Build `recentPlaylists` from the index in O(recents), not
  O(recents × allSummaries).
- `TrackTableView`: move `filteredTracks`/`sortedFilteredTracks` out of
  `body`. Hold `displayedTracks` in `@State`, recomputed via
  `onChange(of: trackFilter)`, `onChange(of: sortOrder)`, and
  `onChange(of: detail.id)` (swiftui-pro: "assume `body` is called
  frequently; move sort/filter out"; "cache derived collections only with
  explicit invalidation" — these `onChange` hooks *are* the explicit
  invalidation). Behavior identical; the array is the same single playlist.
- swiftui-pro note: `@Observable` tracks per **stored** property, so a
  now-playing tick (`playback.snapshot`) must not invalidate sidebar
  observers. It doesn't today (the sidebar reads no `playback` property);
  keep it that way — do not fold play state into the summary structs.

Acceptance: sidebar render does zero array concatenation and zero O(n·m)
scans; `swift test` green; no visual/behavioral diff (a `body`-call counter
or signpost in `PlaylistSidebarList`/`TrackTableView` shows constant work per
keystroke instead of growing with library size).

## Phase B — Bound what stays resident

**No schema change, no store change.** Make residency O(visible), not
O(browsed).

- Replace `PlaylistDetailService.cache` with a small bounded LRU (capacity
  ~3: the on-screen playlist + the one or two you bounced off of). A single
  playlist re-read is sub-millisecond, so the cache exists only to kill the
  re-selection flash, not to hoard the library.
- Make invalidation **targeted**: `invalidate(playlistID:)` drops one entry;
  keep a full `invalidateAll()` only for a forced full reimport. Today
  `refreshSelectedDetailIfNeeded` and `runImport` blow away *every* cached
  detail (`MusicController.swift:432-436, 563-568`), so after any Refresh the
  visible playlist suffers a cold re-read — targeted invalidation fixes that
  *and* shrinks residency.
- Document the invariant in `PlaylistDetailService`: "at most LRU-capacity
  playlists' `TrackRow`s are ever resident; the library is never fully
  materialized." Add a test asserting the cache never exceeds capacity after
  selecting N > capacity playlists.
- `ArtworkProvider`: cap the positive cache (LRU) and the negative cache; a
  long scroll session shouldn't grow an unbounded id dictionary. Low
  severity, bundle here.
- `LibraryStore.allSongs()`: add a doc-comment warning it must not back a
  list view, or delete it if genuinely unused after a call-site audit. If an
  "All Songs"/catalog list is ever built it MUST be windowed (Phase D), never
  `allSongs()` → `[Song]`.

Acceptance: a test selecting 20 playlists leaves ≤ LRU-capacity details
resident; a Refresh of an unchanged library does **not** force a cold
re-read of the on-screen playlist.

## Phase C — Reactive store via GRDB `ValueObservation`: PROTOTYPED, then REJECTED

Built in full (scoped `ValueObservation` on `apple_playlist`/
`favorite_playlist`/`recent_playlist`, `@MainActor` consumer tasks,
push-based `LibraryReadService`, `StoreObservationTests`), verified green,
then **reverted** after re-evaluating against two facts the user confirmed:
**(1) multi-source sync will never happen** and **(2) lots of features will
be built on this baseline.**

Why it doesn't pay its freight here:

- `ValueObservation`'s *defining* benefit is propagating writes the app
  didn't initiate (other processes / background sync / raw SQL outside the
  API). With a **single writer forever**, that benefit is moot — the app
  always knows when it wrote. The only residual benefit is the structural
  "can't forget to refresh after a write" guarantee.
- That guarantee is real (this codebase already shipped four "forgot to
  refresh" bugs — the Phase-4 UI corrective), but it does **not** require
  GRDB observation. A single **mutation chokepoint** delivers the same
  guarantee *synchronously*, with none of observation's cost: no async
  iterator lifecycle/teardown, no scheduler subtleties, and no
  startup/`reconcileSelectionAfterImport`/create→select **sequencing
  races** (the prototype had to paper these over with kept-explicit reads —
  itself the evidence that pure observation fights the synchronous control
  flow).
- The shipped form was also a **hybrid** (3 tables observed, app-playlists
  + detail manual, plus redundant optimistic rebuilds) feeding **one
  `rebuildDerivedSummaries()` God-sink**. For "build lots on top" that is
  the worst resting place: every future feature must know which regime a
  table is in and whether its write races the sink.

Forward pattern adopted instead (the freight-payer for many features on a
single-writer local model):

- Keep A+B. Freshness is a **discipline at the `LibraryStore` mutation
  chokepoint**, not a framework concern: every input mutation re-derives
  synchronously (zero latency, single-writer-correct, race-free).
- As features grow, **decompose the one all-collections
  `rebuildDerivedSummaries()` into per-collection rebuilds invoked by the
  specific store mutation**, so a new surface never recomputes every other
  surface. The single God-rebuild — *not* observe-vs-manual — is the real
  scaling limit, and is the thing to evolve. (Recorded in the
  `rebuildDerivedSummaries()` doc-comment so a future agent sees it at the
  code.)
- Counter-case (when you'd revisit): if "lots of stuff" ends up built by
  many uncoordinated hands and routing discipline erodes, the framework-
  enforced version is full per-surface observation — but only if you go
  *all-in* (observe everything, delete the God-sink + optimistic
  duplicates, solve create→select with the standard optimistic-local
  pattern). Its sole unique benefit stays moot under single-writer; not
  recommended now.

## Phase D — SQL-side sort/filter + windowed Table (deferred; trigger-gated)

Only if a real need appears — a single playlist in the tens-of-thousands, or
a future flat "All Songs"/catalog browser. Not needed for the stated 270-
playlist / ~8.2k-track library because the resident unit is already *one
playlist*, bounded after Phases A–B.

- Push `ORDER BY` (active column) and `WHERE` (filter text) into
  `songsWithStats` (it already does the indexed `song_stat` LEFT JOIN; add
  parameters), debounced, with keyset/`LIMIT`+`OFFSET` paging behind a
  `LazyVStack` or a windowed `Table` source.
- Cost: Table column-header sort/selection/scroll-restoration get harder
  (macos-design: must not regress selection or scroll position). That
  complexity is why this is deferred until a measurement (a profiled large
  playlist, or the catalog feature) justifies it. Recorded here so a future
  agent doesn't reinvent the analysis.

## Implementation status — A+B shipped & kept; C reverted (2026-05-16)

`swift build` clean, **82 tests / 17 suites** green (+4 LRU; the +3 C
observation tests were removed with C), `swiftformat 0/78`, swiftlint
clean. Not committed (on `main`).

- **A — SHIPPED & KEPT.** `MusicController`'s derived collections
  (`allSummaries`, `appPlaylists`, `favoritePlaylists`, `recentPlaylists`)
  are stored, input-driven state rebuilt by `rebuildDerivedSummaries()`
  only on a real input change; `selectedSummary` + all `contains/first(id
  ==)` lookups go through an O(1) `summariesByID`. `TrackTableView`
  filter+sort moved out of `body` into `@State displayedTracks`,
  recomputed only via `onChange(of: detail.revision / trackFilter /
  sortOrder)` (new monotonic `PlaylistDetail.revision` so a same-id stats
  refresh still re-derives, but a now-playing tick does not).
- **B — SHIPPED & KEPT.** `PlaylistDetailCache` bounded LRU **capacity 5**
  replacing the unbounded dict (`peek` recency-neutral vs `value(forID:)`
  a use); targeted `invalidate(playlistID:)` / `invalidate(playlistIDs:)`,
  `invalidateAll()` only for forced reimport. `ImportService.
  changedPlaylistIDs` surfaces exactly the re-fetched/pruned playlists so
  an incremental Refresh that changed nothing leaves the on-screen
  multi-day playlist's cache warm. `ArtworkProvider` FIFO-capped (1024).
  `allSongs()` doc-flagged as a residency footgun.
- **C — PROTOTYPED, VERIFIED, then REVERTED** (see the Phase-C section
  above for the full rationale). Net result is the clean A+B baseline plus
  the **forward pattern** baked into the `rebuildDerivedSummaries()`
  doc-comment: single-writer ⇒ freshness is a mutation-chokepoint
  discipline; decompose the one God-rebuild into per-collection rebuilds
  as features are added. The Phase-4 "forgot to refresh" bug class is
  prevented by routing all mutation→re-derive through that chokepoint, not
  by GRDB observation.

## Sequencing, risk, and verification

| Phase | Risk | Schema | Independently shippable | Primary win |
|------|------|--------|--------------------------|-------------|
| A | low (view/derivation only) | none | SHIPPED & KEPT | latency / spry |
| B | low (cache policy) | none | SHIPPED & KEPT | bounded residency |
| C | medium (observation wiring) | none | REVERTED (no freight under single-writer) | — |
| D | high (Table windowing UX) | none | deferred | only if huge lists |

- A/B keep `swift test` green and are non-behavioral (they literally cannot
  change output). C was reverted, not merged.
- `swiftui-pro` consulted before & after the A/B design (CLAUDE.md);
  `macos-design` before any future Phase D Table change.
- No migration. The local-first schema/store API is untouched; A+B are a
  pure residency/derivation change above `LibraryStore`.

## Decisions (resolved 2026-05-16)

1. **LRU capacity for `PlaylistDetailService` (Phase B): 5.**
2. **Scope: A → B → C built; then C reverted.** Re-evaluated once the
   user confirmed (a) multi-source sync will *never* happen and (b) lots
   of features will be built on this baseline. Conclusion: under a
   permanent single writer, `ValueObservation`'s only benefit is moot and
   its cost (sequencing races, hybrid/God-sink) is the wrong foundation;
   the freight-payer is a synchronous mutation-chokepoint discipline,
   decomposed per-collection as features grow. **Final state = A+B.**
3. **Phase D stays deferred — but the trigger is now KNOWN, not
   hypothetical.** The user's real library contains a **huge multi-day
   playlist** (thousands of tracks). Implications already in scope for
   A–C: Phase A's "move sort/filter out of `body`" is load-bearing for
   that playlist (a per-keystroke full re-sort of thousands of rows in
   `body` is exactly the lag to kill), and Phase B's capacity-5 LRU can
   hold up to 5 large playlists' rows — still bounded and acceptable, but
   note it. Phase D (SQL-side `ORDER BY`/`WHERE` + windowed Table) is the
   real fix for that one playlist and is deliberately **not** tackled now;
   when it is, that multi-day playlist is the test case.
