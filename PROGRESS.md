# Progress

> Resume protocol: read `PLAN.md` (decisions + milestone index) then this
> file. `plans/roadmap.md` is the forward plan; `plans/risks-and-challenges.md`
> is the live risk register. Newest status on top.
> Open-issue index: `PROBLEMS.md`.

## 2026-05-19 — 🟡 Genre rename/merge + assign-to-selected-tracks (code-complete)

Branch `feature/genre-rename-merge-assign` (independent of the unmerged
`.djroomba` snapshot PR). Two edits over the v4 `song.genre_names` JSON
column — no schema change, batched, song-only one-way isolated.

- **Rename the browsed genre** — `PlaylistHeaderView` gains a "Rename"
  button when `detail.isGenre`; opens `GenreNameSheet` (the proven
  `RenamePlaylistSheet` focused/select-all shape). **Merge is implicit**:
  genres are literal tag matches, so `renameGenre(A→B)` rewrites each
  song's array (A→B, then dedupe preserving order); a song with both ends
  with one B and the `B` query returns the union. Renaming to a new name
  is the no-collision case of the same op.
- **Multi-select + assign** — the track `Table` selection is now
  `Set<TrackRow.ID>` (was single), so native shift-range / ⌘-point
  multi-select works; new "Add to Genre ▸" context submenu (sibling of
  "Add to Playlist ▸"): "New Genre…" (→ same sheet) + the existing genres
  from `distinctGenres()`. Assign appends the genre iff absent (idempotent).
- **Pure core** `GenreEdit.renaming/.adding` (nil when unchanged so only
  changed rows write); `DetailNavStack.replacingGenre` keeps Back coherent
  after a rename. **Store**: `distinctGenres`, `renameGenre`,
  `addGenre(_:toSongIDs:)` — both writes funnel through one chunked
  column-named-CTE `UPDATE song SET genre_names …` (≤2 binds/row), one txn,
  only `song`. Controller `allGenres` mirror + `reloadAfterGenreEdit`
  (reloads library/detail/summaries/genres + reanalyzes the graph — the
  wholesale rebuild collapses merged nodes automatically).
- **Verify.** `swift build` clean (Swift 6 strict concurrency);
  **208 tests / 33 suites** green (+`GenreEditTests` 9, `GenreEditStoreTests`
  4 incl. merge + one-way-isolation + chunk-boundary, +`DetailNavStack`
  `replacingGenre`); `swiftformat --lint` 0 (auto-organized) + `swiftlint`
  0 on all touched files. swiftui-pro + macos-design consulted before &
  after (CLAUDE.md). **Computer-use, real 8229-song library** (signed
  installed build): browsed a genre → header **Rename** button → modal
  pre-filled/select-all sheet → renamed **"Electronica" (4) → "Electronic"
  (212)** ⇒ **"Electronic" 216 tracks** (exact union — merge), view
  re-pointed in place, Genre Graph auto-reanalyzed **88→87 genres /
  731→727 links** (merged node gone). Then native `Table` multi-select
  (click + shift-range + ⌘-point = 5 rows) → right-click → **"Add to
  Genre ▸ New Genre…"** → typed "2 Tone" ⇒ assigned to exactly those 5;
  header chip strip + Genre Graph updated (**87→88 / 727→733**). Found +
  noted (not a regression from this change): clicking the **Title** cell
  doesn't select a row because its pre-existing `.draggable` swallows the
  click — selection works via any other column. Not committed/merged.
  **Real-library edits made during the live test (sensible, kept):**
  merged "Electronica"→"Electronic"; added "2 Tone" to 5 Specials/Selecter
  tracks ('08 monkey man', A Message to You Rudy, Do the Dog, Ghost Town
  (Extended Version), Too Much Pressure (B-Side Version)). Both reversible
  via the same Rename feature if unwanted.

## 2026-05-17 — ✅ Always-visible import progress + error surfacing

Field report (a 2nd machine, same library): "Reimport Everything" gave
**no indication anything was happening**, and **no genres** on playlists.

- **Root cause of "no indication" (confirmed defect, machine-independent).**
  Import progress was only ever rendered by the sidebar's *empty/loading*
  state (`PlaylistSidebar`), so a reimport over an **already-populated**
  library (90–120 s playlists + the genre album-pass) showed nothing. The
  `GenreImportService` pass had **zero** UI. And `genreImportService
  .lastError` wasn't even in `libraryProblem`, which itself only renders in
  the empty sidebar — so a swallowed genre-pass failure was completely
  invisible.
- **Fix.** New pure, unit-tested `ImportActivity.text(…)` (precedence:
  playlists → genres → nil; wording byte-identical to the existing
  `libraryLoadingMessage` for the playlist case). `MusicController`:
  `isLibraryBusy` now also covers `genreImportService.isImporting`; new
  `importActivity`; `libraryProblem` now includes
  `genreImportService.lastError`. `MainShellView`: one always-visible
  `ToolbarItem(placement: .status)` — small `ProgressView` + the activity
  text while importing (any phase, any sidebar state), else a tappable
  orange warning whose `.popover` shows the full import/genre error, else
  nothing. Existing first-launch sidebar progress + Refresh-disabled
  behaviour untouched.
- **Verify.** `make check` clean, **181 tests / 29 suites** (+7/+1
  `ImportActivityTests`), `swiftformat`/`swiftlint` 0, no schema change.
  **Live signed build:** Reimport Everything over the fully-populated
  sidebar now shows the centred toolbar spinner + "Importing 100 of 270
  playlists…", then clears cleanly when idle. Not committed.
- **"No genres" on the 2nd machine — separate, likely environmental
  (open).** The album-genre pass runs on `force` and writes only when
  `MusicLibraryRequest<Album>.genreNames` is non-empty (genre lives on the
  library *Album*, ~77% coverage on the dev machine). A different Mac's
  Music library can lack album-level genre metadata, or a dev-signed
  (non-notarized, machine-scoped) build can have degraded MusicKit/
  iTunesLibrary access — both yield empty genres. The error-surfacing
  above now makes a *failed* pass visible; a pass that simply finds **0
  album genres** is honest emptiness, not a bug. Pending user info
  (install/sign method, auth/subscription on that Mac, whether Music.app
  there shows album Genres, whether the genre graph populates).

## 2026-05-17 — ✅ Playlist header shows its associated genres

Follow-on to genre browsing (`plans/genre-browsing.md`). A selected
playlist's header now shows its distinct genres as a quiet, tappable
capsule strip between the "N tracks" subtitle and the Play button.

- **Derived, zero new query.** `PlaylistDetail.genreTally(_ songs:)` —
  pure, unit-tested: per song, trim each `genreNames` entry, drop empty,
  dedupe within a song, sort by **count desc then localized
  case-insensitive name**. Computed in `PlaylistDetailService.load` from
  the already-fetched `withStats.map(\.song)` (no extra `dbQueue.read`,
  no schema change); `refreshStats` carries the prior value (membership
  unchanged); a genre detail (`isGenre`) gets `[]` (no self-chips).
  Surfaced as `PlaylistDetail.genres` (defaulted ⇒ non-breaking).
- **UI.** `PlaylistHeaderView.genreStrip`: a single hidden-indicator
  horizontal `ScrollView` of `.caption`/`.secondary` `.quaternary`-capsule
  `.plain` buttons (consistent with `GenreAssociationsCard`; no new type
  styles; header never grows vertically — shows *all* genres compactly).
  Each chip → `controller.showGenre(genre)`, so it reuses the
  Back-stack-integrated genre nav.
- **Verify:** `make check` clean, **174 tests / 28 suites** (+8/+1:
  `PlaylistGenresTests`), `swiftformat`/`swiftlint` 0. **Live signed
  build:** sidebar "2-Tone" → header strip "Pop · Rock · New Wave ·
  Alternative · Alt/Punk · Reggae"; tap "Reggae" → Reggae genre view
  (35 tracks); Back → 2-Tone with chips intact. Not committed.

## 2026-05-17 — ✅ Genre browsing + top-pane Back/nav stack

New navigation feature (full design: `plans/genre-browsing.md`):

- **Genre → tracks.** Selecting/centering a genre node loads that genre's
  songs into the top pane. New `LibraryStore.songsWithStats(matchingGenre:)`
  (one `dbQueue.read`, `json_each(genre_names)`+`TRIM`+`EXISTS`,
  `song_stat` LEFT JOIN, ordered title→artist; **no schema change** — the
  v4 `genre_names` column). `PlaylistDetailService.selectGenre` builds a
  synthetic `"genre:<name>"` `PlaylistDetail` (`isGenre = true`,
  app-owned source ⇒ per-song playback path; not LRU-cached, not
  favoritable/editable, never recorded into recents). Driven off the
  ForceGraph **committed** selection (`.onChange(of: selectedGenre)`),
  never hover/preview.
- **Card → playlist.** Associated-playlists card rows are now plain-style
  `Button`s (full-row hit target, VoiceOver-focusable) →
  `MusicController.openAssociatedPlaylist(id:)` navigates the top pane to
  that playlist (routes through the normal `selectedPlaylistID` path, so
  sidebar highlight + persistence are correct).
- **Back/nav stack.** Pure unit-tested `DetailNavStack`
  (`DetailDestination` = `.playlist`/`.genre`, LIFO, cap 50, nil/dup
  guarded). Integrated via the existing `selectedPlaylistID.didSet` as the
  single choke point + a `suppressNavRecording` guard so Back/launch-
  restore replay records no phantom history. Back control = leading
  `.navigation` toolbar `chevron.backward` + ⌘[, disabled when empty.
  In-session only (never persisted); restore/persistence/play flows
  unchanged (genre `recordRecentlyPlayed` gated by `!isGenre`).
- **Verify:** `make check` clean, **166 tests / 25→27 suites** (+11/+2:
  `GenreSongsQueryTests` ×5, `DetailNavStackTests` ×6),
  `swiftformat`/`swiftlint` 0. **Live signed-build computer-use:**
  Funk node → "Funk · 9 tracks" (Parliament/Sly & Family Stone…,
  title-ordered); card "Tarantino" → 69-track Tarantino playlist; Back ←
  Funk ← Acceptable Air Tracks (LIFO), button disables at empty;
  sidebar select + launch restore unregressed; graph interaction still
  beachball-free (PATCH 5 holds). Not committed.

## 2026-05-17 — ✅ ForceGraph hub-cell beachball fixed (DJROOMBA PATCH 5)

Field report after the folder blitz: the app beachballed when interacting
with the genre graph while a high-degree node ("Alt/Laptop") was selected.
Profiler-driven root cause (NOT the folder fix — that data is correct and
safe; the blitz only made the graph denser, which exposed a latent bug):
`CrossingIndex`'s uniform-grid crossing detector degenerates to **O(E²)
for a hub star** — the layout centres on the selected hub so all its
incident edges fall in one grid cell, and that super-cell's all-pairs
loop pegs the **main thread** on every drag-induced settle
(`tick → refreshCrossings → CrossingIndex.recompute`, ~67% of the main
thread, amplified by cross-module Swift generic-metadata instantiation in
the pair loop).

- **Fix:** `// DJROOMBA PATCH (5)` in `Vendor/ForceGraph/.../Interaction/
  CrossingIndex.swift` — a `maxCellMembers` (96) cap that skips the pair
  test for a degenerate hub super-cell (an illegible knot the 600-glyph
  budget discards anyway; its pairs mostly share the hub endpoint so
  aren't crossings). Only crossings *interior to a hub core* are omitted
  ⇒ HUD `count` a lower bound there, consistent with the detector's
  documented representative-not-exhaustive contract. Normal graphs
  unaffected (cells far below the cap). Documented in
  `plans/genre-graph.md` (patch list, now 1–5).
- **Profiler-verified on the signed build, identical drag repro:**
  `CrossingIndex.recompute` **11 978 → 10** main-thread samples;
  `refreshCrossings` **12 376 → 12**; main thread **~99.9% idle in the
  run loop** during aggressive node dragging (was a multi-second
  beachball). App stays fully responsive; graph still renders correctly.
- **Verify:** `make check` clean, **155 tests / 25 suites** green,
  `swiftformat`/`swiftlint` 0 (Vendor excluded by convention). Signed
  `build/DJRoomba.app` rebuilt. Mitigation note: collapsing the Genre
  Graph panel was the interim workaround; no longer needed. Not committed.

## 2026-05-17 — ✅ Playlist folders: signed blitz EXECUTED & PASSED

The Phase-3 blitz was **run on the signed sandboxed build against the real
library** (not left user-gated). End-to-end verified:

- **A1 (id mapping) — proven on real data.** Throwaway non-sandboxed
  `iTunesLibrary` probe (reverted; finding kept, the `GenreProbe`
  precedent): `ITLibrary` sees **5 folders** via `kind == .folder`,
  incl. "AAA ME"; `Int64(bitPattern: persistentID.uint64Value)` decimal
  reproduces the stored MusicKit id **exactly** (`AAA ME` →
  `2807883042140459807`, matched; the negative high-bit case also
  correct). `PlaylistFolderClassifier` logic confirmed against the real
  library.
- **A2 (sandbox) — NOT a hard blocker; proven.** The signed sandboxed
  build with the `com.apple.security.assets.music.read-only` entitlement
  (verified embedded via `codesign -d --entitlements`) reads `ITLibrary`
  and converges: `apple_playlist` **270 → 265**, all 5 folders gone
  (`… WHERE name LIKE 'AAA%'` → **empty**). One cold-first-import miss
  was observed and caused **zero regression** (import completed
  normally) — exactly what the graceful-degradation design guarantees;
  the next run converged cleanly.
- **Downstream sane.** Full *Reimport Everything* (⇧⌘R) + auto-reanalyze:
  `song.genre_names` repopulated **6362/8229** (the documented album-pass
  figure), `genre_edge` rebuilt **1462 edges**, top weight
  Alternative~Rock 145→143 — the folder's spurious union no longer
  inflates cross-genre co-occurrence; the "AAA ME 57" domination symptom
  is gone.
- **One-way isolation held across multiple reimport/converge cycles:**
  `song` 8229 intact, `song_stat`(plays>0) 500, `play_history` 502
  preserved, **0** orphan `apple_playlist_track` rows (FK cascade clean).

Diagnostic temp-log used to establish the A2 finding was reverted; clean
state re-verified: `make check` clean, **155 tests / 25 suites** green,
`swiftformat`/`swiftlint` 0; signed `build/DJRoomba.app` rebuilt clean.
Not committed.

## 2026-05-17 — ✅ Playlist folders: Phases 1–4 (Option A, exclude-only)

Followed the Phase-0 probe with the full phased fix from
`plans/playlist-folders.md`. **Decision (orchestrator-delegated, user said
"don't intervene"): Option A — `iTunesLibrary.framework`, exclude-only.**
Both "Open decisions" resolved: A over B (A1 id-mapping encoded +
unit-tested; A2 has no correctness cliff — the
`com.apple.security.assets.music.read-only` entitlement plus
graceful-degrade-to-`[]` mean nothing forces B, which stays the recorded
fallback, **never coded**); exclude-only (Phase 5 hierarchy SKIPPED —
optional, not requested).

- **Phase 2 (prevent at import):**
  `com.apple.security.assets.music.read-only` added to
  `DJRoomba.entitlements`; pure `nonisolated PlaylistFolderClassifier`
  (id mapping `String(Int64(bitPattern: persistentID))` + `isFolder(_:in:)`,
  **8 unit tests**); `PlaylistFolderSource.libraryFolderIDs()` (off-main
  `Task.detached`, graceful-degrades to `[]` if iTunesLibrary
  unavailable — no exclusion, zero regression); `ImportService.runImport`
  builds the folder-id set once and skips folder ids **before**
  `fetchTracks` (dodges the probe's MainActor-hang corollary).
- **Phase 3 (converge the DB):** `LibraryStore.deleteApplePlaylists(ids:)`
  (chunked, single-write, FK-cascade, one-way isolation, empty-set no-op)
  wired into `runImport` to actively delete already-stored folder
  snapshots. `PlaylistFolderConvergeTests` pins isolation + "converged
  folder no longer contributes genre edges".
- **Phase 4 (this pass):** added
  `PlaylistFolderConvergeTests."converged folder no longer appears in
  associated playlists"` — seeds Rock/Jazz/Pop, an "AAA ME"-shaped folder
  (union of children) + a real playlist, `deleteApplePlaylists` +
  `rebuildGenreGraph`, asserts `associatedPlaylists` (verified signature
  `(genre:neighbor:limit:) async throws -> [PlaylistAssociation]`) returns
  **empty for the folder-only genre (Jazz)** and **only the real playlist
  for Rock** (single-genre *and* `Rock↔Pop` edge). Added a terse
  defense-in-depth note on `rebuildGenreGraph`'s `maxPlaylistTracks` doc:
  the oversized-playlist threshold is documented defense-in-depth, **NOT**
  the folder fix (a small folder still needs the classifier; a big *real*
  playlist must not be excluded) — no threshold/behavior change. Docs
  (`playlist-folders.md`, `data-and-import.md`, `musickit-notes.md`,
  `PLAN.md`, this file) updated.
- The Option-B "union/superset detection + curated-superset negative"
  Phase-4 bullet is **N/A** — B was never implemented; that bullet is
  satisfied by documentation, not code.
- **Status:** `make check` clean; `swift test` **155 tests / 25 suites**
  green (was **143/23** pre-Phase-2; +12 across Phases 2–4: 8 classifier +
  3 converge + this 1 associated-playlists); `swiftformat --lint` 0/103,
  `swiftlint` 0. No schema change. **Not committed.**
- **Remaining (USER-gated signed blitz)** — same "signed gate pending
  (user)" pattern as every prior milestone: ⇧⌘R *Reimport Everything* →
  ⌥⌘A *Analyze*, then
  `sqlite3 ~/Library/Containers/org.sockpuppet.djroomba/Data/Library/Application\ Support/DJRoomba/library.sqlite "SELECT id,name FROM apple_playlist WHERE name LIKE 'AAA%';"`
  → expect **empty**; `genre_edge` no longer folder-dominated; the
  previously-folder-skewed associations card looks sane.

## 2026-05-17 — 🔬 Probe: playlist folders are imported as playlists

Bug report: "AAA ME" was imported as a playlist but is a Music.app
**folder** (hierarchical container). Phase-0 throwaway signed
`PlaylistFolderProbe` (reverted — `GenreProbe` precedent; only the
finding kept, see `plans/musickit-notes.md`).

- **Root cause:** `ImportService` writes *every*
  `MusicLibraryRequest<Playlist>` item as an `apple_playlist`; there is
  zero folder filtering. The probe proved **MusicKit exposes no folder
  discriminator at all** — across all 270 playlists `kind`/`curatorName`/
  `lastModifiedDate` are nil and the only `Mirror` children are `id` +
  an opaque `propertyProvider`; the folder is byte-identical to a real
  playlist. So a folder (the flattened union of its child playlists) was
  imported as one huge genre-spanning "playlist", which dominated the
  genre graph / associations (the "AAA ME 57" symptom). Pre-existing
  Phase-3 gap; the genre work only surfaced it.
- **Consequences for the plan:** MusicKit-native detection is
  **impossible** (no field to filter on). Detection must come from
  iTunesLibrary.framework (`ITLibPlaylist.kind == .folder`/`parentID`),
  ScriptingBridge, or a content heuristic. A folder's
  `.with([.entries])` also *hangs the MainActor* in the probe ⇒ folders
  must be excluded *before* the per-playlist fetch. Revised phased plan
  delivered to the user (not yet implemented).
- Side finding: `lastModifiedDate` nil for all 270 → incremental import
  always degrades to full re-import on this library (confirms the
  `data-and-import.md` caveat; not a regression).
- Tree restored: probe fully reverted; `swift build` clean, **143
  tests / 23 suites** green.

## 2026-05-17 — ✅ Neighbor-walk + associated-playlists card

Two fast-follow FDG interactions (vendored, "DJROOMBA PATCH 3 & 4").

**Neighbor-walk (PATCH 3).** When a genre is the centred selection and
search is inactive, the arrow keys cycle its **linked** genres
(strongest edge first, weighted from `graph.edges`): each press previews
a neighbour — centre + readable zoom + hover ring, no selection move, no
snapshot rebuild; `Return` commits it as the new centred genre and the
walk continues from there; if no `Return` lands within 2 s the view snaps
back to the original genre (a cancellable MainActor `Task`, no GCD, reset
each step). `KeyCaptureView` now dispatches ↑↓←→/Return/Esc
unconditionally and the engine decides (consumes for search-cycle when
the HUD is up, else for the walk when a genre is selected, else returns
false so the key passes through to the app unchanged). `selection`'s
didSet resets the walk so a new/cleared selection starts clean. User-
confirmed working ("looking good"); the computer-use env can't reliably
drive standalone synthetic arrows (recurring Accessibility gate), so the
keyboard path is code-reviewed + user-verified, not screenshot-verified.

**Associated-playlists card (PATCH 4).** Selecting a genre shows a pretty
corner card (top-trailing of the FDG view) of the playlists tied to it —
`.regularMaterial` rounded panel, hairline border + soft shadow, source
icon + name + right-aligned strength, **sorted by strength desc, capped
at 8**. During neighbour-walk the card **narrows to the previewed edge**
(playlists where *both* genres co-occur, strength = `min` pair
co-strength); it resets to the anchor genre's full list on snap-back and
to the new genre on commit, and clears on deselect. Wiring: a new engine
`onFocusChange(genre, edgeOther)` callback (fired from select / preview /
snap-back / commit / deselect — the same transitions PATCH 3 owns),
surfaced as an optional `ForceGraphView` init param (defaulted, existing
call site unaffected). `GenreGraphContent` keeps `focus`/`associations`
`@State`, reloads via `.task(id: focus)` (auto-cancels the prior load so
rapid previews can't race a stale list). New store read
`LibraryStore.associatedPlaylists(genre:neighbor:limit:)` (two CTE
shapes, single-genre vs edge; derived live from `genre_names` +
membership — association isn't persisted; no eligibility filter — the
honest "all playlists this genre is in"). `PlaylistAssociation` DTO;
`GenreGraphService.associatedPlaylists` thin wrapper (cap 8). Computer-use
**verified the card** end-to-end: select "Alt/Laptop" → card lists 8
playlists, strength-sorted (57…5), capped, pretty.

- **Skills:** macos-design / swiftui-pro / typography applied (material
  HUD-style overlay, `.topTrailing`, semantic type, `Text`-from-
  `LocalizedStringKey` so `^[…]` inflects, `.task(id:)` not manual Task
  juggling, subviews/types in own files, no `Binding(get:set:)`).
- **Verify:** `swift build` clean; **143 tests / 23 suites** green (+2
  `GenreGraphTests`: associated playlists by strength; edge narrowing
  incl. the both-genres-required filter; the SwiftUI card / FDG patches
  are layout/dep-internal, not unit-tested per precedent);
  `swiftformat`/`swiftlint` 0. Not committed.

## 2026-05-17 — ✅ Genre search: vendored fdg + 2 patches (flicker, zoom)

Field report on the search HUD: (1) typing/cycling genres flickered the
mouse cursor (a tight unnecessary redraw loop); (2) cycled matches stayed
tiny dots instead of being centred big enough to read. Both root-caused
into `fdg`'s `GraphEngine`, with **no public API hook** to fix from our
side.

- **Vendored the dependency.** `tqbf/fdg` was a remote SPM tag; you can't
  patch a pinned remote. Copied the exact v1.0.0 commit `0a8a43e` into
  `Vendor/ForceGraph` (trimmed to the library target — Lab/tests/corpus
  dropped), switched `Package.swift` to `.package(path:)`
  (product `package:` `fdg` → `ForceGraph`), `Package.resolved` drops the
  remote. Both fixes carry `// DJROOMBA PATCH` markers for upstreaming.
- **Patch (1) — flicker / tight loop.** `tick()` kept
  `wantsContinuousRedraw` pinned the whole time the search HUD was up
  (`pulseWantsRedraw = searchHUDState.isVisible && !reduceMotion`) just to
  breathe the match pulse → the opaque `Canvas` redrew the entire graph at
  display refresh on a *settled* graph the whole time, and the OS reset
  the cursor over the continuously-invalidating view every frame.
  `pulseWantsRedraw = false`: a settled search now idles like any static
  graph (the existing Reduce-Motion no-pulse path, made universal).
  Matches still light/dim (snapshot-driven); the recenter animation still
  runs via the finite `keepLiveUntil` tail.
- **Patch (2) — center+zoom on cycle.** `onSearchCycle`/narrow used
  `viewport.center(on:)` (pan only, preserves zoom) → matches stayed
  tiny when zoomed out. Added `Viewport.focus(on:minScale:)` (centre AND
  raise zoom to a readable floor, never zoom out) + a
  `recenterViewportForSearch` used by cycle and query-narrowing; the
  layout-bloom follow and selection pin keep the pan-only path
  (their zoom is intentionally preserved).
- **Verify:** `swift build` clean (vendored ForceGraph compiles with both
  patches); **141 tests / 23 suites** green (our suite unaffected — the
  patches are dep-internal; `swiftformat`/`swiftlint` run on
  `DJRoomba`/`Tests` only, never `Vendor`). Computer-use on the signed
  build: typed "laptop" → 1/3 matches; ↓ cycled 1/3→2/3→3/3, each
  ("Alt/Laptop/Bristol", "Alt/Laptop/NYC", …) **centred and zoomed
  readable** with its neighbourhood legible (was tiny dots), and the
  graph **settled to rest between cycles** (loop paused — no 60 Hz
  churn). Not committed.

## 2026-05-17 — ✅ Genre analysis: source-level thresholds + Advanced pane

The real fix for "why is the graph so dense": shape it at **analysis
time** (principled, persisted, user-tunable) instead of re-pruning at
display time. Two thresholds added to `LibraryStore.rebuildGenreGraph`:

- **(a) Exclude oversized playlists.** A playlist clique-connects all its
  genres (quadratic), so a few giant lists ("every track WLIR played for
  8 years") alone push the graph near-complete. New `eligible` CTE drops
  any playlist whose `COUNT(*)` membership exceeds `maxPlaylistTracks`
  (default 500); everything downstream joins through it.
- **(b) Cap edges per playlist.** Each eligible playlist contributes only
  its **top-`maxPairsPerPlaylist`** (default 30) genre pairs by
  intra-playlist co-strength `min(distinct tracks of A, distinct tracks
  of B)` — high only when *both* genres are substantially present, so a
  stray track / a single dominant genre can't mint a strong pair. Done
  with a `ROW_NUMBER() OVER (PARTITION BY playlist ORDER BY strength
  DESC, …)` window CTE (`ranked`/`kept`); the rest of the CTE chain is
  unchanged. Two `?` binds (maxPlaylistTracks, maxPairsPerPlaylist).
- **Advanced Settings pane.** New native `Settings` scene (⌘,, SwiftUI
  auto-wires the menu item) → `SettingsView` (TabView, one "Advanced"
  tab, fixed 520×320) → `GenreAnalysisAdvancedPane` (grouped `Form`,
  two bounded `Stepper`s + a `.caption` explainer each + a footer noting
  changes apply on next analysis). Bound via `@AppStorage` — correct
  here (a plain view, NOT inside an `@Observable`) on the SAME
  `UserDefaults` keys `UserPreferencesStore` exposes
  (`genreAnalysisMaxPlaylistTracks` / `…MaxPairsPerPlaylist`, clamped
  ≥ 1), so it needs no `controller` wiring. `MusicController` reads the
  prefs and passes them through the single `runGenreAnalysis()` funnel
  (both ⌥⌘A and the auto-reanalyze hook).
- **Sparsification re-evaluated & simplified.** The display-time greedy
  strongest-neighbour backbone was **removed** — re-pruning a graph
  already curated at source only obscured it. `buildDisplayGraph` is now
  a faithful projection: canonical `a<b` fold, **every analyzed genre is
  a node** (low-degree genres stay searchable/centerable), weight
  normalised over kept, and a single documented **perf backstop**
  (`displayEdgeMax = 1200`, strongest-by-weight) that is expected to
  rarely bind now. `sparsify` + the per-node-degree knob deleted.
- **Skills:** macos-design / swiftui-pro / typography-designer consulted
  for the Settings pane; result conforms (native tabbed-Settings chrome,
  grouped Form, `@AppStorage`-in-plain-view, `LabeledContent` + Stepper,
  semantic type, no `Binding(get:set:)`, types in own files).
- **Verify:** `swift build` clean; **141 tests / 23 suites** green (+2
  `GenreGraphTests`: oversized-playlist exclusion, per-playlist top-N by
  strength; `GenreGraphDisplayTests` reworked off the removed sparsify
  to the backstop + all-genres-stay-nodes); `swiftformat`/`swiftlint` 0.
  Computer-use on the signed real-library build: **Re-analyze with the
  new defaults took 5,719 → 731 links / 88 genres** (well under the
  1,200 backstop ⇒ the true analysis-curated graph, far more legible),
  and the ⌘, Advanced pane renders correctly (both steppers at
  500 tracks / 30 links, captions, footer). Genre graph blown away &
  rebuilt (user-sanctioned). Not committed.

## 2026-05-17 — ✅ Genre-graph visualizer: reveal affordance + snappiness

Field feedback on the visualizer: (1) collapsing it left no discoverable
way to bring it back; (2) typing "americana" to centre it was REALLY slow.
Both fixed and computer-use-verified on the signed real-library build.

- **Reveal affordance — toolbar toggle.** Added a `MainShellView`
  toolbar button (the `point.3.connected.trianglepath.dotted` glyph,
  between Refresh and the Inspector toggle) bound to the **same**
  `@SceneStorage("genreGraphPanelCollapsed")` key as `GenreGraphPanel`,
  so the toolbar control and the panel's header chevron stay in sync
  within the scene (no state-lifting/prop-drilling). This is the
  native idiom (mirrors the app's own inspector toggle); a collapsed
  panel is now always re-openable from the toolbar. Verified: clicking
  it reveals/hides the panel.
- **Snappiness — sparsify before handing to `ForceGraphView`.** Root
  cause: a real genre co-occurrence graph is **near-complete** (measured
  library: 114 genres, **5,719** edges ≈ 89 % of a complete graph).
  `ForceGraph` is explicitly built for *sparse* graphs — its spring sim,
  edge-crossing detection and per-frame Canvas redraw all scale with
  edge count, so a hairball is slow *and* illegible. This is our
  integration's responsibility, not the dep's. `buildDisplayGraph` now
  reduces to a **greedy degree-bounded strongest-neighbour backbone**:
  per-genre top-`maxNeighbors` (8) by weight via a deterministic
  strongest-first walk, then a global `maxEdges` (600) cap;
  weights renormalise over survivors. Result on the real library:
  **5,719 → 600 links** (~9.5× fewer) — search/centre is now snappy and
  the graph is legible.
- **…but every genre stays findable.** First cut also derived *nodes*
  from kept edges, which pruned "Americana" out entirely ("no matches" —
  the exact reported case). Fixed: **node set = every genre that
  co-occurs with anything** (full pre-sparsify set); only *edges* are
  sparsified. A genre whose weak links were pruned still appears (floats
  free of springs — honest "no strong ties") and stays
  searchable/centerable. Node count was never the cost; edges were.
  `ForceGraph` explicitly supports partly-disconnected graphs.
  Verified: "americana" → **1 match**, highlight, `Return` centres &
  pins it, fast.
- **Verify:** `swift build` clean; **139 tests / 23 suites** green (+4
  net `GenreGraphDisplayTests`: backbone keeps strong/drops weak tail,
  global cap, sparse-graph untouched, **pruned genre still a searchable
  node**); `swiftformat`/`swiftlint` 0. Computer-use on the signed
  build confirmed toolbar reveal + the americana centre + 600-edge
  snappiness. Not committed.

## 2026-05-17 — ✅ Genre-graph visualizer (collapsible/resizable detail panel)

Pulled in **`tqbf/fdg`** (`ForceGraph` SPM library product — one public
`ForceGraphView`, no third-party deps, macOS 14; pinned `from: "1.0.0"`,
identity `fdg`, resolved at v1.0.0 / `0a8a43e`) and rendered the v6 genre
graph in the main pane. Full design: `plans/genre-graph.md` → "The
visualizer".

- **Placement:** `DetailPaneView` now composes the detail column as
  `PlaylistDetailView` (takes the space) + a bottom-docked
  `GenreGraphPanel` — the native debug-area idiom. Library-wide, so it's
  independent of the selected playlist (stays put while the user changes
  playlists above it). `MainShellView`'s `detail:` swapped to
  `DetailPaneView()`.
- **Collapsible:** header chevron toggles `collapsed`; the slim bar stays
  when collapsed (always re-discoverable), value-animated.
- **Resizable:** top-edge `GenreGraphResizeHandle` (drag, clamped 180–680,
  macOS resize cursor, VoiceOver-adjustable). `collapsed` + height are
  `@SceneStorage` (scene state in the view layer, never in an
  `@Observable`); default **expanded** at 300 pt (visible on first run,
  doesn't crowd the track list).
- **`GenreGraphService` extended:** publishes `displayNodes`/`displayEdges`
  /`isLoadingGraph`/`hasLoadedGraph`. `loadGraph()` (panel `.task`, no
  rebuild) shows a prior/auto-built graph immediately; `analyze()`
  refreshes it in the same call so the panel tracks both the ⌥⌘A action
  and the auto-reanalyze with no extra trigger. Pure `nonisolated static
  buildDisplayGraph(from:)`: canonical `a<b` half only, sorted node set,
  weight `raw/maxRaw` floored 0.12 (single edge ⇒ 1).
- **View files** (swiftui-pro "extract subviews", codebase granularity):
  `DetailPaneView`, `GenreGraphPanel`, `GenreGraphResizeHandle`,
  `GenreGraphPanelHeader`, `GenreGraphContent` (loading / Analyze
  empty-state / `ForceGraphView`). Type reuses the existing semantic
  scale (`.subheadline` semibold + `.caption` secondary — one tier below
  `PlaylistHeaderView`); no new scale.
- **Skills:** swiftui-pro (`views.md`/`data.md`) + macos-design
  (`layout-and-composition.md`) consulted before; result conforms —
  subviews extracted to own files, button actions in methods,
  value-driven animation, scene state out of `@Observable`,
  content-area-as-star secondary panel, progressive collapse.
- **Verify:** `swift build` clean; **135 tests / 23 suites** green (new
  `GenreGraphDisplayTests` ×4: canonical-half dedupe + sorted nodes,
  max+0.12-floor normalisation, empty input, lone canonical half);
  `swiftformat`/`swiftlint` 0. Not committed.
- **Computer-use sanity check (signed `make` build, real ~8200-song
  library):** panel renders correctly docked at the detail-pane bottom
  (chevron + title + count + Analyze button + drag-handle + empty-state
  CTA). Clicking **Analyze** built the graph end-to-end and
  `ForceGraphView` rendered a clean colourful force layout — **114
  genres · 5,719 links** with readable hierarchical-tag node labels
  (Prog-Rock/Art Rock, Alt/Goth/Industrial, Hip-Hop/Rap, …). Found +
  fixed one real bug: the header count printed the literal
  `^[…](inflect: true)` markup because it went through a precomputed
  `String`; switched to an inline `Text(LocalizedStringKey)` literal
  (the `PlaylistHeaderView` idiom) — re-verified on a fresh build: now
  reads "114 genres · 5,719 links" correctly inflected/grouped.
  Collapse + resize could **not** be exercised: the macOS Accessibility
  (`universalAccessAuthWarn`) prompt gated synthetic input after the
  first event (environment, not an app defect — can't grant that
  permission programmatically). Those paths are simple and were
  code-reviewed instead; `ForceGraph`'s interaction layer was confirmed
  to monitor only `.keyDown`/`.scrollWheel` and **never consume mouse
  events**, so it can't be starving the chevron/handle. A signed manual
  pass of collapse/resize is the one remaining unautomated check.

## 2026-05-17 — ✅ v6: genre graph + the "Analyze" action

Build a graph of genres by relating tracks of different genres that
**share a playlist**. Full design: `plans/genre-graph.md`.

- **Schema `v6.genreGraph`**: `genre_edge(genre_a, genre_b, weight,
  PRIMARY KEY(genre_a, genre_b))` — a pure **adjacency-list** edge table.
  No FK (genre is denormalized free text in `song.genre_names`, not an
  entity — the favorites/recents no-FK rationale); no extra index (the
  composite PK *is* the adjacency index). Purely additive — v1–v4 frozen,
  non-destructive. **No `v5.*` migration** on purpose (the documented v5
  album-genre import was data-only / reused the v4 column; the migration
  id skips to v6 — it's just an ordered label).
- **`LibraryStore.rebuildGenreGraph()`**: ONE `DELETE` + ONE CTE-driven
  `INSERT … SELECT … UNION ALL` in a single transaction. CTEs keep the
  graph SQL un-messy: `membership` (both libraries, source-prefixed
  composite playlist key, `UNION ALL`) → `playlist_genre` (`json_each`
  explode, `DISTINCT`, NULL/`json_valid`/blank guards) → `pair`
  (self-join on `a.genre < b.genre` — drops self-pairs *and* the mirror)
  → `edge` (`COUNT(DISTINCT playlist_key)` = weight). Both directed
  half-edges materialized so a neighbour read is a trivial indexed
  `genre_a` lookup. Wholesale ⇒ consistent by construction, idempotent,
  one-way isolated (only `genre_edge`). Reads:
  `relatedGenres(to:limit:)`, `genreGraphEdges()`; read-only `GenreEdge`.
- **`GenreGraphService`** (`@MainActor @Observable`, mirrors
  `GenreImportService`): `analyze()` / `isAnalyzing` (re-entrancy guard)
  / `lastError` / `edgeCount`. **No MusicKit** — pure SQLite over data
  already imported; offline-safe, no signing gate.
- **On-demand:** Playback ▸ **Analyze Genre Graph** (⌥⌘A), beside
  Reimport Everything. **Auto-reanalyze (default ON):** Playback ▸
  **Reanalyze Automatically** — a native checkmark `Toggle` bound via
  `Bindable` (modern Observation binding, not `Binding(get:set:)`),
  persisted in `UserPreferencesStore.autoReanalyzeGenreGraph`
  (UserDefaults; absent ⇒ true, no migration), mirrored on
  `MusicController` (no `@AppStorage` in an `@Observable`).
  `reanalyzeGenreGraphIfEnabled()` fires fire-and-forget after
  import / app-playlist add·remove·setTracks·delete; deliberately NOT on
  rename / sidebar-reorder / empty-create (those can't change a
  genre↔playlist relationship — guaranteed wasted work). The
  `isAnalyzing` guard + wholesale rebuild coalesce a burst into one
  in-flight pass with nothing missed.
- **Skills:** swiftui-pro (`data.md`) + macos-design consulted before and
  the result conforms — `@MainActor @Observable`, `Bindable` binding, no
  `@AppStorage`-in-`@Observable`, fire-and-forget consistent with the
  existing `recordRecentlyPlayed`/`detectAndRecordAdvance` patterns;
  menu placement/idiom/shortcut native (checkmark Toggle, ⌥⌘A,
  setting-has-no-shortcut).
- **Verify:** `swift build` clean; **131 tests / 22 suites** green (new
  `GenreGraphTests` ×10: symmetric two-direction edges, distinct-playlist
  weighting incl. duplicate-row collapse + Apple&app both feeding it,
  multi-genre-song self-link, no-shared-playlist→no-edge,
  NULL/blank/invalid genre ignored without abort, adjacency
  ordering+limit, idempotence, one-way isolation; `MigrationTests` v6
  ordering/idempotence + `genre_edge` table/PK + `expectedTables`);
  `swiftformat`/`swiftlint` 0. Not committed.
- A visual genre-graph view / sidebar "related genres" is the trivial
  follow-on (the edge table + reads are in place) — out of scope.

## 2026-05-17 — ✅ v5: album genres imported onto song.genre_names

Acted on the probe finding. Genre lives on the library `Album`; the user
wants it stored **on the track rows** (`song.genre_names`, the v4 column
— **no album entity, no migration**).

- **`GenreImportService`** (mirrors `ImportService`'s serial-loop /
  cap / tolerate-per-item-failure shape): pages
  `MusicLibraryRequest<Album>`, **skips empty-`genreNames` albums before
  the per-album `album.with([.tracks])` fetch** (≈halves the work),
  unwraps each track via the **shared** `ImportService.underlyingItemID(
  of:)` (extracted; the id-rule now lives once — used by both playlist
  import and this) which == our `song.music_item_id`, builds
  `[musicItemID: genreNames]` (last-album-wins, documented).
- **`LibraryStore.applyAlbumGenres`**: one-transaction chunked
  `UPDATE … SET genre_names = CASE music_item_id WHEN ? THEN ? … END
  WHERE music_item_id IN (…) AND id_namespace='library'` — the
  `reorderAppPlaylists` batch idiom; library-namespace-only; touches
  only `genre_names`; returns rows-updated.
- **Trigger:** `runImport(force:firstImport:)` runs the genre pass iff
  `force || firstImport` — Reimport Everything (⇧⌘R) / first import
  only; the fast incremental Refresh stays genre-free (documented).
- **The album→track id-join sidesteps the empty-`album.title` wrinkle**
  the probe found — we never needed the title; the underlying library
  Song id is the reliable key.
- **Cleanup gate (R6):** correctness review confirmed the `song(from:)`
  refactor is provably behavior-preserving (no library-wide-corruption
  vector) and the batch CASE/IN/namespace bind alignment is exact with
  non-vacuous tests. Fixed two low-sev hygiene items: an orphaned
  duplicate doc block (stale `song(from:)` doc above `underlyingItemID`)
  and a chunk-math off-by-one vs the file's own 999-var budget
  (`(limit-1)/3` → worst case 997 ≤ 999, restores the invariant /
  matches `reorderAppPlaylists` discipline).
- **Verify:** `swift build` clean; **122 tests / 21 suites** green (new
  `AlbumGenreApplyTests`: multi-id, 700-row unordered chunk boundary,
  library-only, untouched-ids, idempotent, full one-way isolation, JSON
  round-trip); `swiftformat`/`swiftlint` 0.
- **Signed verification on the real 8229-song library:** Reimport
  Everything → `genre_names` **0 → 6362/8229 (77.3 %)**, correctly
  attributed (Pearl Jam→Alternative, The Cars→Rock, Underworld→
  Electronic), user hierarchical tags preserved ("Alt/Indie",
  "Alt/Punk/Pixies-Related"); top genres Rock 1667 / Alternative 1625 /
  Pop 780 … The ~23 % blank are untagged-album tracks (singles /
  podcasts / loose), exactly as the probe predicted.
- Surfacing genre as a track-table column / sidebar grouping is the
  trivial follow-on (existing sortable-column pattern) — out of scope.

## 2026-05-17 — 🔬 Genre probe: genre is on the library Album, not Song

Throwaway signed diagnostic (Debug-menu `GenreProbe`, **reverted after**
— not in the repo; only this finding committed) to answer "where does
genre live in MusicKit's macOS library graph, since Get Info shows it
but our `Song.genreNames` is empty."

- `Song.genreNames`: **0/40**. A library `Song` has no `.genres`
  relationship to even request (`song.with([.genres])` does not compile).
- `Artist.genreNames`: **0/40**.
- **`Album.genreNames`: 17/40** — real, the user's own hierarchical
  tags: `["Alt/Goth/Industrial"]`, `["Alt/Indie"]`,
  `["Pop/Rock/60s-70s/Classic"]`. **Hypothesis confirmed: genre rides
  on the Album.**
- ~58% of sampled albums had no genre (singles / podcasts / comedy /
  untagged) — album-genre is partial, album-granular (a compilation =
  one genre across its tracks), exactly as Apple models it / the album
  view shows.
- **Path to get genres (free, no rate limit):** bulk
  `MusicLibraryRequest<Album>` (paged, no per-item, no catalog
  entitlement — a *new request type*, not an option on the existing
  playlist fetch) → attribute album genre to its tracks. **NOT yet
  built.**
- **Open wrinkle the probe surfaced:** in the bulk Album request
  `album.title`/`artistName` came back EMPTY, so album→song attribution
  can't naively join on the stored `album_title`; it needs a real
  album↔track key (the `Album.id`/`.tracks` relationship, or requesting
  more Album properties). That's the design question for the
  implementation — flagged, not hand-waved. Spec recorded in
  `plans/data-and-import.md`.

## 2026-05-16 — ✅ Schema v4: free track metadata + EMPIRICAL signed verification

Added migration `v4.songMetadata` (9 nullable `song` columns) and made
`ImportService.song(from:)` read the direct properties already on the
`.song(let s)` payload `playlist.with([.tracks])` ALREADY returns —
**Bucket 1 only: zero extra Apple calls, no per-item/catalog fan-out,
no rate-limit exposure.** Code-complete & cleanup-gated (correctness
review confirmed the genre dual-decode is one GRDB `FetchableRecord`
decoder, the 19-col `upsertSongs` SQL is exact-aligned, frozen-migration
rules intact). `swift build` clean, **114 tests / 20 suites** green,
`swiftformat`/`swiftlint` 0.

**Signed-DB verification (the empirical answer to "is this data free?").**
v4 migrated the real **8229-song** container DB non-destructively
(v3→v4, existing rows NULL); a signed `make` build + **Reimport
Everything** repopulated via `song(from:)`; `sqlite3` on the live
container DB after completion:

| column | populated / 8229 | verdict |
|---|---|---|
| `release_date` | 8191 (99.5%) | **FREE** — real dates |
| `disc_number` | 7708 (93.7%) | **FREE** |
| `track_number` | 7646 (92.9%) | **FREE** |
| `has_lyrics` | 8229 non-null (all `false`) | present-but-always-false (lyrics availability is catalog-side; the Bool is non-optional so stored, honestly, as false) |
| `work_name` / `movement_name` | 11 (0.13%) | **FREE**, sparse by nature — classical only (verified real, e.g. "Suite bergamasque, L. 75" / "Clair de lune") |
| `genre_names` | **0** | **NOT free** — empty on a macOS *library* `Song` |
| `composer_name` | **0** | **NOT free** — ditto |
| `isrc` | **0** | **NOT free** — ditto |

Conclusion (definitive, measured — not doc-guessed): the write path
provably works (release/track/disc/lyrics/work all carry real values;
`has_lyrics` 100 % non-null proves the `.song` unwrap + v4 write fires
for every song). **`genre_names`, `composer_name`, `isrc` are uniformly
empty across all 8229 tracks** → MusicKit's *library-scoped* `Song`
simply does not carry them on macOS; they are catalog-side and would
require per-item `MusicCatalogResourceRequest` (the rate-limited Bucket 3
we deliberately don't do and lack the entitlement for). So we now pull
everything genuinely free; the three that aren't free are confirmed
catalog-only, not a code defect. Columns are kept (harmless NULLs;
they'd populate if a catalog path is ever added). Surfacing any of the
populated fields in the track table is a trivial follow-on (the existing
sortable-column pattern) — out of scope here (schema+import only).
`plans/data-and-import.md` / `PLAN.md` updated; committed `4cf68bd`.

## 2026-05-16 — ✅ Recently Played landing surface (code-complete; live test next)

New user request: opening the app with no playlist selected should show a
lazily-scrolled list of recently-played songs (built on the Phase-1–4
`play_history`), plus a debug seeder. Full design in
`plans/recently-played.md`.

- **Store:** `recentlyPlayedPage(beforeSeq:limit:)` — distinct songs,
  newest-play-first, **keyset** paginated on the `play_history`
  AUTOINCREMENT PK (`GROUP BY song_local_id`, `HAVING MAX(seq) <
  :cursor`). `seedRandomPlayHistory(count:)` — one-txn debug seeder,
  picks playlist-member songs, faithful to `recordPlay` (no `song_stat`
  drift), returns `min(count, available)`.
- **View:** `RecentlyPlayedService` (`@MainActor @Observable`, on
  `MusicController`; not coupled to the 0.5 s tick) + `RecentlyPlayedView`
  /`RecentlyPlayedRow` (native `List`, reuses existing type tiers — zero
  new roles). Replaces the "Select a Playlist" empty state. Lazy via
  per-row `.onAppear`.
- **Playback:** `playRecentlyPlayed` reuses the app-playlist resolution
  path through a new shared `startResolvedQueue` helper —
  `resolveAndPlay` refactored onto it rather than duplicating the
  **load-bearing ordering invariant**; the refactor was independently
  reviewed and the invariant **verified to still hold** (no `await`
  between the atomic `ActivePlayContext` set+seed and the synchronous
  `player.queue` swap). Plays from this surface record stats (dogfoods
  Phases 1–4). No Apple id as a key.
- **Debug menu:** `CommandMenu("Debug")` → "Seed 500 Random Plays".
- **Cleanup gate (R6 + swiftui-pro/macos-design/typography):** 2-agent
  pass. The risky `resolveAndPlay` refactor verified correct. Fixed
  three real defects: a `loadTask` teardown race (cancel-and-replace
  could spawn a concurrent page → duplicated rows) → **monotonic
  `loadGeneration` token** (mirrors `PlaylistDetailService.revisionCounter`);
  an **O(n²) scroll scan** (`firstIndex` over all rows per `onAppear`) →
  bounded `rows.suffix(prefetchDistance)` check; a `.task`
  reload-on-reappear that **discarded scroll position** every time the
  user returned from a playlist → load page 1 only when empty (explicit
  `reload()` from the seed path handles data changes). Pagination
  doc-comment corrected to be honest about the replay-mid-scroll
  eventual-consistency nuance (by design, not a gap). Change-narrating
  comment trimmed.
- **Verify:** `swift build` clean; **107 tests / 19 suites** green (new
  `RecentlyPlayedTests`: distinct/newest-first, cross-boundary keyset
  no-overlap/terminate, re-float, empty, seeder member-only/min-count/
  zero/accumulate+cap); `swiftformat` 0, `swiftlint` 0.
- **Live computer-use validation — PASSED (dev-signed build, real
  imported library).** Seeded 500 via the Debug menu; the surface
  replaces "Select a Playlist"; native rows (artwork / title /
  artist • album / relative time), distinct & newest-first; scrolling
  **lazy-loads** (subtitle count 50 → 100 as keyset pages append,
  smooth); double-click **plays real audio** (now-playing bar advances)
  via `playRecentlyPlayed` — which itself recorded the manual start +
  an auto-advance, and on relaunch those two real plays correctly
  floated to the top ("2 minutes ago") above the synthetic seed
  ("28 minutes ago"): **Phases 1–4 dogfooded end-to-end on a signed
  run.** Relaunch with no persisted selection opened **straight to
  Recently Played** (the original ask). One UI bug found & fixed: the
  header subtitle rendered the literal `^[N song](inflect: true)` markup
  — `subtitle` was a `String` passed to `Text` (verbatim init);
  changed to `LocalizedStringKey` so SwiftUI applies grammar agreement
  (now "50 songs"). Rebuilt/re-verified; `swift build` clean, 107/19
  green, lint 0. This signed run also incidentally exercised the
  Phase 2–4 playback/auto-advance gate via the Recently Played queue
  (worked); the dedicated Phase 2–4 signed-gate checklist still stands
  for the playlist paths.
- **Note (minor, not fixed):** the debug seeder staggers synthetic
  `last_played_at` by `index*3s` while `seq` is insertion-order, so
  synthetic rows' relative-time labels run slightly opposite to seq
  order (cosmetic, synthetic-data only; real plays are correct — see
  the dogfood result above).

## 2026-05-16 — ✅ Play statistics Phase 4 + FEATURE CODE-COMPLETE

`plans/play-statistics.md` **Phase 4** (Decision R1 — "last N *played*"
must reflect listening, not just clicks). With this the whole
play-statistics feature is **code-complete**; all 4 phases were
implemented by sequential subagents, each through its own multi-agent
cleanup gate (R6).

- **Phase 4 design.** Pure `PlaybackResolver.advanceToRecord(
  lastRecordedIndex:currentIndex:) -> Int?` (`nonisolated static`,
  exhaustively unit-tested): nil current / current == watermark → nil
  (paused/steady tick **or** a back-replay restarting the same index —
  this is how **R4** holds for free, no append); else → the new index.
  Hung off the existing 0.5 s monitor via a new `@ObservationIgnored`
  `PlaybackService.onSnapshotRefresh` closure (no second timer), invoked
  after `snapshot` is committed. `detectAndRecordAdvance` advances the
  watermark **unconditionally** on a transition (an unattributable
  `nil`-hole position still moves it, so it isn't retried and the next
  real transition is still seen) and fire-and-forget `recordPlay`s only
  attributable positions. **Song-1 double-count prevented** by seeding
  the watermark to the structural start index in the SAME atomic
  `ActivePlayContext` assignment `recordPlayStart` keys off (the
  `ActivePlayContext` value type extended with `lastRecordedQueueIndex`
  so context+seed can't drift — the Phase-2 atomicity decision carried
  forward).
- **Cleanup gate (R6):** reuse/quality/correctness + swiftui-pro/
  efficiency 3-agent pass. swiftui-pro/efficiency: **clean** (closure
  `@ObservationIgnored` + `[weak self]`, no body/tick coupling, O(1)
  per-tick, early-return before any `Task` on the common no-transition
  tick, off-main write). Correctness pass raised a "blocking" P1
  (re-play-while-playing double-count) — **investigated and determined
  a false positive**: it assumed a monitor tick can observe (new
  context, old queue), but on the single-threaded MainActor there is no
  `await` suspension between the context assignment and the synchronous
  `player.queue` swap (`recordRecentlyPlayed` is sync; `await
  playback.play` runs synchronously until *after* `player.queue` is
  set), so that mixed state is unobservable; the reviewer's proposed
  fix would have *lost* legitimate plays of the prior queue the user
  still hears while the next resolves. Instead **hardened the subtle
  ordering as a documented load-bearing invariant** at the seed
  assignment (a future `await` inserted there would reintroduce the
  window). Applied **P2** (real, low-severity): `detectAndRecordAdvance`
  now swallows `RecordPlayError.unknownSong` specifically (a benign
  Phase-2 re-resolve race) so a transient misalignment can't spam
  `storeError` on the 2 Hz monitor; any other store error still
  surfaces.
- **Verify:** `swift build` clean; **100 tests / 18 suites** green
  (pure `advanceToRecord` boundaries + seeded `[0,1,1,2,2,2,1]→[1,2,1]`
  sequence; end-to-end vs real `LibraryStore`: N advances ⇒ N+1 history
  rows incl. the start; back-replay adds zero; song 1 not duplicated;
  R4 counter-vs-history isolation); `swiftformat` 0, `swiftlint` 0.

### Play statistics — remaining work (the ONLY thing left: a signed run)

Phase 1 is fully shipped (pure SQLite, unit-tested). **Phases 2–4 are
code-complete and unit-tested but carry a SIGNED RUNTIME GATE that only
the user can run** (no live MusicKit / signed build in unit tests —
same gating every prior milestone in this codebase had). Under a signed
build (`make`/`make run` with the Apple Development identity), confirm:

1. **Phase 2:** `currentStoredSongID` tracks the right stored `song.id`
   across a natural auto-advance and a manual skip (i.e.
   `snapshot.queueIndex` = the structural ordinal stays aligned with
   our `playContext`). Fallback if not: count `currentEntry` transitions
   off the 0.5 s monitor (still principle-clean — no Apple-id key).
2. **Phase 3:** the pre-skip capture (`currentStoredSongID` +
   `livePlayhead()`, taken before `await playback.skip…`) actually
   beats MusicKit mutating `currentEntry`, and live `elapsed` is
   accurate enough at the `duration/2` boundary; skip counts in
   `1 s < elapsed < dur/2`, replay in `elapsed > dur/2`.
3. **Phase 4:** auto-advance appends `play_history` for the song
   actually played; a back-replay of the current track appends nothing
   (R4); song 1 isn't double-counted live; pause/interrupt/loop don't
   spuriously record.

No `PROBLEMS.md` change (no signed gate run by the agent → no defect to
log). If a signed run finds a defect, log it there per the plan.

## 2026-05-16 — ✅ Play statistics Phase 3 (skip/replay counting; code-complete)

`plans/play-statistics.md` **Phase 3** (asks #2 & #3). Count a **skip**
("next" before halfway, past the intent dead-zone) and a **replay**
("back" after halfway), attributed to the song that *was* playing,
captured **before** the transport mutates the queue. Counters only —
**R4: a replay never adds a `play_history` row** (Phase-1 `recordReplay`
already guarantees this). No UI; recording-only.

- **Pure decision core** `PlaybackResolver.skipKind(elapsed:duration:
  button:) -> {skip,replay,none}` (`nonisolated static`, MusicKit-free).
  Rules exactly: nil/`<=0` duration → none; `next` → skip iff
  `1 < elapsed < duration/2` (strict both ends — R2 dead-zone inclusive
  at 1.0, half-rule strict); `previous` → replay iff
  `elapsed > duration/2` (strict); exactly 50% → none; ultra-short
  (`duration/2 <= 1`) → empty skip window falls out with no special case.
  `TransportButton`/`SkipKind` enums alongside the existing pure-core
  precedent.
- **`PlaybackService.livePlayhead()`** — synchronous `(elapsed,
  duration)` read straight off the live player (NOT the ≤0.5 s-stale
  snapshot: the `duration/2` boundary needs the playhead as it is *now*,
  or a press near half misclassifies). Same `@MainActor`/
  `nonisolated(unsafe) player` access as `refreshSnapshot`.
- **`MusicController.recordTransportStat(button:)`** called first thing
  in `skipNext()`/`skipPrevious()`, fully synchronous, **before** `await
  playback.skip…`: capture `currentStoredSongID` (Phase-2 structural
  attribution — our `song.id`, no Apple id), `livePlayhead()`,
  `skipKind`; then fire-and-forget `store.recordSkip/recordReplay`
  (mirrors `recordRecentlyPlayed`'s `Task{}`/`storeError` shape; never
  blocks or delays the transport, which runs regardless of the decision).
- **Cleanup gate (R6):** reuse/quality + swiftui-pro/efficiency 3-agent
  pass — **no real defects**. Every R2 boundary walked and verified
  exact (no `<=`/`<` slip); capture-before-delegate ordering confirmed
  sound; R4 confirmed structural (`bumpStatCounter` never touches
  `play_history`). swiftui-pro: zero new Observation surface (only the
  existing `storeError`), O(1) at human cadence off every tick/`body`.
  Applied one proactive DRY win: extracted the duplicated `entry.item →
  duration` 4-arm switch into one `PlaybackService.itemDuration(of:)`
  used by both `livePlayhead` and `refreshSnapshot` (prevents Phase-4
  drift; `refreshSnapshot` keeps its own `nowPlayingItemID` UI extract).
- **Verify:** `swift build` clean; **96 tests / 18 suites** green
  (exhaustive `skipKind` boundary test + structural capture/R4 guard in
  `PlayStatisticsTests`); `swiftformat` 0, `swiftlint` 0.
- **Signed gate PENDING (user):** only a real signed run confirms the
  pre-skip live capture actually beats MusicKit's `currentEntry`
  mutation and that real `elapsed` is accurate to the half-boundary.
  The decision itself is pure & fully unit-tested; this capture-vs-
  mutation race is the sole unverified bit (documented at the code).

## 2026-05-16 — ✅ Play statistics Phase 2 (canonical play context; code-complete)

`plans/play-statistics.md` **Phase 2** — THE enabler. Carry *our*
`song.id`s forward from the SQLite read that built the queue and
attribute "which stored song is playing now" by the player's
**structural queue position**, never by translating an Apple id back
(the load-bearing architecture principle). Recording-only — no
playback/UI behavior change.

- **`PlaybackResolver.Resolution.playContext: [String?]`** — stored
  `song.id` per queue position, **parallel to `songs` by construction**
  (every `songs` append has one paired `playContext` append). Built in
  `reassemble` (app playlists; all non-nil) and `resolvePlaylist`
  (imported Apple; `nil` for a live track beyond the stored snapshot —
  it still plays but records no stats rather than being misattributed).
- **Pure helpers** (`nonisolated static`, MusicKit-free, unit-tested):
  `startIndex(in:startSongID:)`, `storedSongID(in:at:)`.
- **`PlaybackService`** sets `snapshot.queueIndex` = the ordinal of
  `currentEntry` within `queue.entries`, matched by the queue **Entry**'s
  own id (the queue's structural handle MusicKit mints — *not* the song's
  `MusicItemID`; no Apple content id is ever a key).
- **`MusicController`** holds the active queue's context atomically in one
  `@ObservationIgnored` value type (`ActivePlayContext{ songIDs,
  startSongID }`) set/cleared in a single assignment so the two parts
  can't drift; `currentStoredSongID` = `storedSongID(at: queueIndex ??
  startIndex-seed)`. `@ObservationIgnored` is load-bearing (the 0.5 s
  monitor must not invalidate `body` — the swiftui-pro / memory-laziness
  "no now-playing tick coupling" rule); nothing reads it from a view.
- **Cleanup gate (R6):** reuse/quality/efficiency + swiftui-pro 3-agent
  pass. Caught & fixed a **CRITICAL** desync (`songs` grew but
  `playContext` didn't when the live Apple playlist exceeds the stored
  snapshot → every later position misattributed) — fixed via `[String?]`
  parallel-by-construction (no playback change, vs the reviewer's
  drop-from-both which would have dropped playable songs); collapsed two
  drift-prone fields into one value type; deleted a brittle
  source-substring test (the behavioral pure-function proof already
  covers the no-Apple-id-key guarantee); trimmed change-narrating
  comments. swiftui-pro/efficiency review: `@ObservationIgnored` correct
  & sufficient; `queueIndex` adds zero new body churn (snapshot already
  wholesale-replaced each tick); per-tick `entries.firstIndex` is
  bounded — Phase 4's transition detector supersedes it.
- **Refines the plan:** spec said `playContext: [String]`; the
  stale-snapshot edge (live > stored) makes `[String?]` the faithful
  realization of "attribute only what our SQLite read canonically gives"
  — recorded here as an intentional deviation.
- **Verify:** `swift build` clean; **94 tests / 18 suites** green
  (Phase-2 pure helpers, parallelism, nil-hole bounds; −1 vs prior count
  = the removed brittle source-grep test); `swiftformat` 0, `swiftlint`
  0.
- **Signed gate PENDING (user):** structural-position fidelity under
  real auto-advance / manual skip / `startingAt:` can't be unit-verified
  (no live MusicKit in tests). Documented fallback if it proves
  unreliable: count `currentEntry` transitions off the 0.5 s monitor to
  advance the index — still principle-clean (no Apple-id translation).
  Phases 3–4 depend on this.

## 2026-05-16 — ✅ Play statistics Phase 1 (v3 schema + store API)

Executed `plans/play-statistics.md` **Phase 1** (the durable spine; no
playback behavior change — recording-only foundation for Phases 2–4).

- **Migration `v3.playStatistics`** (appended below v2; v1/v2 frozen,
  `eraseDatabaseOnSchemaChange` still false; idempotent). Four
  coordinated changes: (a) `song.local_id` added nullable →
  backfilled dense 1-based in `(imported_at, id)` order → `UNIQUE`
  index; (b) `play_history` (`seq INTEGER PK AUTOINCREMENT`,
  `song_local_id` FK→`song(local_id)` `ON DELETE RESTRICT`) — the
  user's bounded numeric "vector"; (c) `song_stat.skip_count` /
  `replay_count` (`NOT NULL DEFAULT 0`); (d) **`play_event` DROPped**
  (verified consumer-less; last unbounded table gone). Cleanup pass
  added a **partial index** `idx_song_unassigned_local_id … WHERE
  local_id IS NULL` so the new-row allocator is skipped at O(1) on a
  no-op incremental re-import (the path commit `11bcaf4` optimizes).
- **Records:** `Song.localID` (read-authoritative, write-ignored —
  contract is comment-enforced, documented as such); `SongStat`
  skip/replay counters; new `PlayHistoryEntry`; `PlayEvent.swift`
  deleted.
- **`LibraryStore`:** `playHistoryCap = 50_000` (R9, one tunable);
  `upsertSongs` assigns `local_id` for new rows only inside the existing
  upsert txn (existing rows keep theirs — same non-destructive
  re-import guarantee as the stable `id`); `recordPlay` rewritten (one
  txn: resolve `local_id` → typed `RecordPlayError.unknownSong` aborts
  ghost plays leaving `song_stat` unchanged → roll `song_stat` → append
  `play_history` → keyset prune `WHERE seq <= MAX(seq) - cap`);
  `recordSkip`/`recordReplay` are thin wrappers over one private
  `bumpStatCounter` key-path helper (R4: never touch `play_history`);
  `recentlyPlayedSongLocalIDs`/`…SongIDs` (newest-first, dupes kept);
  `playEventCount` removed.
- **Canonical-key discipline (architecture principle):** Phase 1 keys
  only on `song.id` / `song.local_id`; no Apple id anywhere on this path.
- **Cleanup gate (R6):** `simplify` three-agent pass (reuse/quality/
  efficiency — covers the Thomas'-Laws surface) found and fixed: the
  duplicated skip/replay block (→ shared helper), a doc-comment that
  misstated the ghost-song error mechanism (now accurate: counter paths
  FK-trip a raw `DatabaseError`, only `recordPlay` raises the typed
  error), the unconditional allocator scan (→ partial index + EXISTS
  early-out), over-long comments trimmed. `recentlyPlayed*` default left
  at `playHistoryCap` (decision-locked R3/R9, bounded, no callers yet —
  not a defect). swiftui-pro: no SwiftUI/Observation touched (N/A).
- **Verify:** `swift build` clean; **90 tests / 18 suites** green
  (baseline 82/17 + new `PlayStatisticsTests` incl. v3 non-destructive
  backfill on a real v2 DB via `migrate(…, upTo: "v2…")`, exact-cap
  prune, counter isolation, `local_id` stability across re-import;
  3 tests migrated off `playEventCount`); `swiftformat` 0/80,
  `swiftlint` 0 violations.
- **Known precision note (carried):** the `MAX(local_id)+1` allocator
  is over *live* rows, so a never-referenced number *could* recur if its
  song were deleted before being observed; songs are never deleted in
  the app and any played/listed song is FK-RESTRICTed, so an observable
  `local_id` can't recur. `Song.localID` doc states this exactly (the
  unqualified "never recycled" was tightened).
- **Not signed-gated** (pure SQLite, unit-tested — plan: Phase 1 no
  gate). Phases 2–4 follow.

## 2026-05-16 — ✅ App icon (native macOS treatment)

`djroomba.png` (1254² pixel-art DJ-Roomba on an off-white field) turned
into a native-feeling `AppIcon.icns` and wired into the no-Xcode bundle.

- **Treatment (macos-design consulted):** Apple Big Sur+ icon grid — 1024
  canvas, 824² rounded tile (100px margin), continuous-ish corner radius
  ~185, one restrained soft shadow inside the margin (not a single heavy
  drop). The source's off-white field becomes the tile color; character
  keeps its breathing room. Verified by eye on light **and** dark
  backdrops — reads as a real Mac app icon, not a full-bleed square.
- **Reproducible:** `scripts/make-appicon.sh` (ImageMagick + `iconutil`)
  builds all 10 iconset sizes from one styled 1024 master → `iconutil`
  packs `DJRoomba/AppIcon.icns`. `djroomba.png` is the checked-in source.
- **Wiring:** no asset catalog (consistent with the no-Xcode build).
  `build.sh` copies `AppIcon.icns` → `Contents/Resources/`; `Info.plist`
  gains `CFBundleIconFile`/`CFBundleIconName` = `AppIcon`. `build.sh`
  hard-fails if the icns is missing. `./build.sh debug` verified: builds,
  signs clean, bundle carries the icon. `plans/build-system.md` updated
  (the "no bundled resources" claim was now false).

## 2026-05-16 — ✅ Cleanup pass (Thomas' Laws): Phase A shipped; B/C logged

Applied the `toms-laws` rubric to the post-residency code. Verdict: the
codebase is in good shape — only three genuine findings, one worth doing
now.

- **Phase A — SHIPPED.** Collapsed the duplicated app-playlist mutation
  ritual into one private chokepoint, `MusicController.mutateAppPlaylist(_:_:)`.
  `renameAppPlaylist` / `addSongs` / `removeTracks` / `setAppPlaylistTracks`
  each were `await service.X(); rebuildDerivedSummaries();
  refreshSelectedDetailIfNeeded(id)` — 4 copies of the same 3-statement
  ritual where forgetting the rebuild is exactly the Phase-4 "forgot to
  refresh" bug class. Now each is one `await mutateAppPlaylist(id) { … }`
  call; the rebuild+refresh is structural for these paths, not a
  per-method discipline. `create`/`delete`/`reorder` keep their own
  bespoke post-mutation bookkeeping (genuinely different shapes — forcing
  them through the funnel would be a Law-13 hybrid). Laws 5/10/11/12.
  Pure intra-class refactor, behavior identical. **`swift build` clean,
  82 tests / 17 suites green** (incl. `UIRefreshCorrectionTests`,
  `AppPlaylistCRUDTests`), `swiftformat --lint` 0/1, `swiftlint` 0
  violations.
- **Phases B & C — logged, deferred.** B (extract `LibraryStore`'s
  chunked multi-row `INSERT` ceremony) and C (hoist `PlaylistSidebarList`
  filtering out of `body`) recorded in `DESIGN-TODO.md` with their
  falsifiable freight claims and veto conditions. C is recommended
  **against** unless the sidebar measurably lags. Three options were
  explicitly evaluated and decided **against** (per-collection rebuild
  decomposition now; Environment-injecting `ArtworkProvider.shared`;
  reopening reactive-store) — rationale in `DESIGN-TODO.md` so they aren't
  re-proposed without a new trigger.

## 2026-05-16 — ✅ Residency: A+B shipped; C (GRDB observation) reverted

Final state of the `plans/memory-and-laziness.md` work. **A and B are
kept** (they fully deliver the goal: ruthless residency + spry UI at
near-zero risk). **Phase C — the GRDB `ValueObservation` reactive store —
was built, verified green, then reverted** after the user confirmed two
facts that change the calculus: **multi-source sync will never happen**,
and **lots of features will be built on this baseline**.

- **Why C was reverted (the freight evaluation).** `ValueObservation`'s
  defining benefit is propagating writes the app didn't initiate; under a
  permanent **single writer** that is moot. Its only residual value — the
  structural "can't forget to refresh" guarantee — is delivered *more
  cheaply and synchronously* by a **mutation chokepoint**, without
  observation's async-iterator lifecycle or the startup /
  `reconcileSelectionAfterImport` / create→select **sequencing races**
  (the prototype had to paper those over with kept-explicit reads — the
  tell that pure observation fights the synchronous control flow). The
  shipped form was also a hybrid (3 tables observed; app-playlists +
  detail manual; redundant optimistic rebuilds) feeding one
  `rebuildDerivedSummaries()` God-sink — the worst base for "build lots on
  top". Net: C carried observation's cost without a benefit that exists
  here.
- **Forward pattern (recorded in code + plan).** Single-writer ⇒ freshness
  is a discipline at the `LibraryStore` mutation chokepoint, not a
  framework concern: every input mutation re-derives synchronously
  (zero-latency, race-free). The Phase-4 "forgot to refresh" bug class is
  prevented by routing all mutation→re-derive through that chokepoint. As
  features grow, decompose the single all-collections
  `rebuildDerivedSummaries()` into **per-collection** rebuilds invoked by
  the specific mutation (the one God-rebuild — not observe-vs-manual — is
  the real scaling limit). This note lives in the
  `rebuildDerivedSummaries()` doc-comment so a future agent meets it at
  the code.
- **Revert mechanics.** `LibraryReadService` restored to its exact
  pre-change original (store-backed `load()`); `LibraryStore` `observe*`
  factories removed (Phase-B `allSongs()` doc kept);
  `MusicController` observation tasks / `deinit` / `startObservations` /
  `loadImportedPlaylistsInitial` removed and `startAuthorizedSession` /
  `runImport` restored to the A/B form; `StoreObservationTests` deleted.
  Grep confirms no `ValueObservation`/`observe*`/`observationTasks`
  remnants except the intentional decision note in the doc-comment.
- **Verification (final A+B baseline):** `swift build` clean; **82 tests
  / 17 suites** green (78 original + 4 `PlaylistDetailCacheTests`);
  `swiftformat 0/78`, swiftlint clean. Not committed (on `main`).
- **Still true from A+B:** Phase A (stored input-driven derived
  collections + O(1) `summariesByID`; `TrackTableView` sort/filter out of
  `body` via `PlaylistDetail.revision`) and Phase B (LRU **5**,
  targeted invalidation via `ImportService.changedPlaylistIDs`,
  `ArtworkProvider` FIFO 1024, `allSongs()` flagged). Phase D (SQL-side
  sort/filter + windowed `Table`) still deferred; the huge multi-day
  playlist is its test case.

## 2026-05-16 — ✅ Residency/laziness Phases A-B-C implemented (C since reverted — see top)

Executed `plans/memory-and-laziness.md` (user picked LRU **5**, scope
**A→B→C**, Phase D deferred — but the real library's **huge multi-day
playlist** is now the concrete D trigger, recorded in the plan).

- **A — kill per-`body` recompute (no behavior/schema change).**
  `MusicController` derived collections (`allSummaries`/`appPlaylists`/
  `favoritePlaylists`/`recentPlaylists`) are stored, input-driven state
  via `rebuildDerivedSummaries()` (called only on real input changes, never
  in `body`); `selectedSummary` + all id lookups go through an O(1)
  `summariesByID`. `recentPlaylists` is no longer O(recents×allSummaries).
  `TrackTableView` filter+sort moved out of `body` into `@State
  displayedTracks`, recomputed only via `onChange(of: detail.revision /
  trackFilter / sortOrder)`. New monotonic `PlaylistDetail.revision`
  (minted per produced value in `PlaylistDetailService`) so a same-id
  stats refresh still re-derives but an unrelated observable tick doesn't.
- **B — bound residency (no schema change).** New `PlaylistDetailCache`
  bounded **LRU capacity 5** replaces the unbounded `[String:
  PlaylistDetail]`; `peek` (recency-neutral, for stats merge) vs
  `value(forID:)` (a use). Targeted `invalidate(playlistID:)` /
  `invalidate(playlistIDs:)`; `invalidateAll()` only for forced reimport.
  `ImportService.changedPlaylistIDs` exposes exactly the re-fetched +
  pruned playlists so `runImport` invalidates only those — an incremental
  Refresh that changed nothing keeps the on-screen (multi-day) playlist's
  cache warm (no cold SQLite re-read). `ArtworkProvider` cache FIFO-capped
  (1024, positives+negatives). `LibraryStore.allSongs()` doc-flagged as a
  residency footgun (no caller; must never back a list view).
- **C — reactive store (no schema change).** Scoped GRDB
  `ValueObservation` on `apple_playlist` / `favorite_playlist` /
  `recent_playlist` (each tracks only the table its fetch reads) consumed
  by `@MainActor` controller tasks (structured concurrency, cancelled in
  `deinit`); `rebuildDerivedSummaries()` is the sink. `LibraryReadService`
  is now push-based (`apply(applePlaylists:)`/`fail`, no store dep).
  Removed the steady-state manual reload choreography; external/background
  DB changes now propagate with **no explicit reload**.
  - **Two deliberate scoping boundaries (documented in the plan, not
    omissions):** app playlists stay on the explicit zero-latency path
    (create→select→inline-rename needs the new row in `summariesByID`
    synchronously — observation latency would race it; app playlists are
    tiny/single-writer so ~no residency gain); per-playlist detail stays
    lazy + Phase-B-bounded + D4-discrete-refreshed (a detail observation
    needs risky per-selection re-keying for no residency/correctness
    gain). Sequencing-critical explicit reads kept on purpose: startup
    population (so `restoreSelection()` sees summaries) and post-import
    `loadImportedPlaylistsInitial()` (so the synchronous reconcile sees
    fresh data); the observation then re-emits idempotently.
- **Verification:** `swift build` clean; **85 tests / 18 suites** green
  (+`PlaylistDetailCacheTests` ×4 = LRU bound/eviction/peek-neutral/
  targeted-invalidate; +`StoreObservationTests` ×3 = external write
  propagates with no reload, deterministic via stepped async iterator —
  no sleeps); swiftformat `0/79 require formatting`, swiftlint clean.
  swiftui-pro consulted (data.md/performance.md): `body` no longer
  sorts/filters; derived collections are stored/`@State` with **explicit**
  invalidation; `@Observable @MainActor` preserved; structured concurrency
  only. **Not committed** (on `main`; no instruction to commit).
- **Honest read:** A+B fully deliver the user's stated goal (ruthless
  residency + spry) at near-zero risk. C is the architectural end-state;
  with a single in-process writer its concrete benefit today is the live
  projection / external-change propagation / deleted manual-reload churn —
  modest now, valuable when multi-source sync (schema-doc future) lands.
  Phase D (SQL-side sort/filter + windowed `Table`) remains deferred; the
  multi-day playlist is its test case.

## 2026-05-16 — 📋 Residency/laziness plan written (then implemented — see above)

Evaluated the whole codebase against the "SQLite is the fast source of
truth → keep almost nothing resident, lazy-load, stay spry" goal. Wrote
`plans/memory-and-laziness.md` (PLAN.md index updated). Findings:

- The app does **not** load the whole library's tracks today — one
  playlist at a time. The real issues are narrower than "library in
  memory": (1) `PlaylistDetailService.cache` is **unbounded** with
  all-or-nothing `invalidate()` — browsing the library accumulates every
  playlist's `TrackRow`s; (2) `MusicController`'s derived collections
  (`allSummaries`/`favoritePlaylists`/`recentPlaylists`/`appPlaylists`/
  `selectedSummary`/`sidebarState`) are **computed properties rebuilt
  every SwiftUI `body`** — `recentPlaylists` is O(recents×allSummaries),
  the sidebar does ~5 concats + O(n·m) scans + 4 filters per render;
  (3) `TrackTableView` sorts/filters the full track array **in `body`**;
  (4) no `ValueObservation` (manual reload+republish, why the cache is a
  crutch); (5) latent footgun `LibraryStore.allSongs()` (no app caller).
- Plan stages it lowest-risk-first: **A** convert per-`body` recompute to
  input-driven stored `@Observable` state + O(1) id index, move
  Table sort/filter out of `body` (pure spry win, no behavior/schema
  change); **B** bounded LRU detail cache + targeted invalidation +
  `ArtworkProvider` ceiling (bounded residency); **C** scoped GRDB
  `ValueObservation` replacing the manual reload choreography (freshness
  without a resident mirror); **D** SQL-side sort/filter + windowed Table
  — **deferred**, trigger-gated (no >10k-track list / catalog browser).
- No migration in A–D; all above `LibraryStore`. swiftui-pro consulted
  (data.md/performance.md): the design respects "`body` is hot" and
  "cache derived collections only with explicit invalidation".
- **Open decisions surfaced to the user** (LRU capacity; do C now vs.
  stop after B; confirm D stays deferred). Awaiting direction before
  implementing. Nothing built/committed yet.

## 2026-05-16 — ✅ Incremental import implemented (the only real lever)

Acted on the profiling finding: don't re-fetch tracks for playlists that
didn't change.

- **Migration `v2.applePlaylistChangeToken`** (append-only, nullable
  `apple_playlist.change_token` INTEGER; v1 untouched per the discipline).
  Stored as `Int(Playlist.lastModifiedDate.timeIntervalSince1970)` —
  integer seconds, exact `==` despite GRDB ms date round-trip.
- **Pure decision** `ImportService.importDecision(...)` — conservative:
  `.skipUnchanged` only on a confident snapshot+token match; every
  uncertainty → `.fetch`. Never a stale skip (worst case: redundant
  fetch). `runImport(force:)` skips via `touchApplePlaylistImportDate`
  (no MusicKit track fetch) and `pruneApplePlaylists(keeping:)` drops
  vanished snapshots (FK-cascade only — one-way isolation preserved).
- **Escape hatch** ⇧⌘R "Reimport Everything" →
  `MusicController.reimportEverything()` → `runImport(force: true)`;
  recovery for smart/auto playlists that change server-side without
  bumping `lastModifiedDate`. ⌘R stays incremental.
- **Tests:** new `IncrementalImportTests` (10) — pure decision matrix +
  store plumbing + the prune one-way-isolation invariant; `MigrationTests`
  updated for v2 (list + new change_token-column check). Unsigned, no
  MusicKit. **Gate: 78 tests / 16 suites green** (`ImportPerfBench`
  still `.enabled(if:)`-skipped). `swift build` clean,
  swiftformat/swiftlint clean.
- **Honest caveat (in plans/data-and-import.md + profiling.md):** the
  mechanism is correct/safe regardless; the *speedup* depends on macOS
  MusicKit populating `lastModifiedDate` (often nil per musickit-notes) —
  verifiable only on a signed Refresh. When nil it degrades to today's
  full import: **no regression, worst case unchanged.** Not committed.

## 2026-05-16 — ✅ Import perf ANSWERED: ~99% is MusicKit, not our code

`ImportPerfBench` (env-gated test, unsigned, no MusicKit) runs the exact
`ImportService.writePlaylist` app-side path over a real-scale synthetic
library (270 playlists / ~18.8k slots / ~7.9k songs, file-backed SQLite):
**total app-side write path ~1.08 s** (snapshot-replace 50%, upsert 34%,
lookup 13%, mapping 1%) vs the **~90–120 s** real import. ⇒ **≈99% of
import time is MusicKit's `playlist.with([.tracks])` fetch; there is no
reducible app-side hotspot.** Confirms the long-standing H1 with a real
isolated measurement (prior finding was only coarse wall-clock A/B);
refutes H2/H3. **Only lever = incremental import** (skip MusicKit re-fetch
for playlists unchanged since `lastImportedAt`) — a structural change, not
a hotspot fix; app-side parallelism stays ruled out. Detail + table in
`plans/profiling.md` findings log. No signed run needed for this
conclusion (a signed profile would only show MusicKit's *internal*
breakdown, which isn't our code). Normal `swift test` gate unchanged (67
real tests green; the benchmark is `.enabled(if:)`-skipped — runtime
still ~0.1 s). swiftformat/swiftlint clean. Not committed.

## 2026-05-16 — 🔬 Profiling wired in (import perf investigation set up)

Wired [apple/swift-profile-recorder](https://github.com/apple/swift-profile-recorder)
into the app to profile the known ~90–120 s full-re-import cost; created the
global `swift-profiling` skill (speedscope + computer-use +
`scripts/hotspots.sh`).

- **Package.swift:** added `swift-profile-recorder` (`.upToNextMinor(from:
  "0.3.0")`, resolved 0.3.16) + `swift-log` (`Logging`, for the required
  `Logger`; already transitive). GRDB pin untouched. `swift build` resolves
  and links clean.
- **`PlaylistPlayerApp.init()`:** starts `ProfileRecorderServer` via
  `Task.detached` (structured concurrency, not GCD) behind
  `#if DEBUG || PROFILE_RECORDER`. **Inert** unless
  `PROFILE_RECORDER_SERVER_URL_PATTERN` is set (no env var ⇒ `.default`,
  server never binds); `runIgnoringFailures` swallows sandbox bind errors;
  the normal release/`make dist` build defines neither symbol so it's
  never compiled in. Verified the real v0.3.16 API
  (`parseFromEnvironment()` is `async throws`; blog snippet was stale).
- **No new "reimport" feature needed:** ⌘R "Refresh Playlists" →
  `refreshLibrary()` → `runImport()` is already a full, non-incremental
  re-import — repeatable for profile/iterate. Documented rather than adding
  redundant UI.
- **`plans/profiling.md`** added (PLAN.md index updated): the signed-build
  + sandbox-container-socket runbook, the ⌘R/curl/`hotspots.sh`/speedscope
  loop, and the **self-time hypotheses** to test — notably that the prior
  "it's all MusicKit, not reducible" finding came from coarse wall-clock
  A/B, not a self-time profile, so the profile may still surface app-side
  self-time (`song(from:)`/write-path/ARC) or point at incremental import.
- Verification: `swift build` clean, `swift test` **67/67 / 14 suites**,
  `swiftformat --lint` clean, `swiftlint` 0 on changed files. Behavior
  unchanged when the env var is unset (i.e. always, in normal use).
- **Open:** the actual capture needs a *signed* run against a real Apple
  Music library (MusicKit + sandbox) — that's a USER step (runbook in
  `plans/profiling.md`); I can drive `hotspots.sh`/speedscope analysis once
  a `.perf` exists. Not committed (no instruction to; on `main`).

## 2026-05-15 — ✅ Airbnb Swift style pass (formatter + linter wired up)

Applied the Swift skills (`airbnb-swift-style`, `swiftui-pro`) across the
whole codebase. Tooling adopted (Homebrew): **SwiftFormat 0.61.1 +
SwiftLint 0.63.2**; Airbnb's canonical configs vendored as `.swiftformat`
and `.swiftlint.yml` (one toolchain adaptation: `--type-blank-lines
preserve` since 0.61.1 lacks `consistent`; `--language-mode 6` since the
package compiles in Swift 6 mode).

- **`[AUTO]` layer:** `swiftformat` reformatted **all 75 files**
  (+5,788 / −5,330) — sorted imports, `// MARK:` organization +
  visibility/type declaration ordering, redundant `self`/`return`/`init`/
  parens/`Void` removed, trailing commas, raw-identifier swift-testing
  case names, brace/space normalization. Non-behavioral (Airbnb tenet) and
  proven so: build clean, **67/67 tests / 14 suites still green**.
- **Lint layer:** `swiftlint` with the Airbnb `only_rules` set →
  **0 violations / 74 files** (independently confirms no IUOs, force-
  unwraps, stray `print`, `@unchecked Sendable`, legacy constructors,
  `#file`). Earlier phases were already disciplined.
- **`[JUDGMENT]` manual pass** (3 parallel skill-checklist reviewers +
  swiftui-pro + a deprecated-API/forbidden-state grep cross-check): the
  app code is clean — **0** deprecated SwiftUI API, **0** forbidden state
  patterns (`ObservableObject`/`@Published`/`@AppStorage`-in-`@Observable`
  — only a *comment* documenting the rule), structured concurrency only.
  One genuine fix applied: `LegacyMigrationTests` force-unwrapped
  `UserDefaults(suiteName:)!` → `try #require(...)` with a `throws`
  helper (Airbnb "avoid force-unwrap in tests").
- **Rejected (documented):** a sub-reviewer flagged two `MusicController`
  fire-and-forget `Task {}` as "retain cycles" → verified false (tasks
  not stored; consistent with the 28-site fire-and-forget vs 3-site
  stored-`[weak self]` pattern). Changing 2 of 28 identical sites would be
  the nitpick the skills forbid; left as-is.
- Verification: `swift build` clean, `swift test` **67/67 green**,
  `swiftformat --lint` **0/75**, `swiftlint` **0**. Behavior unchanged.
  Not committed (no instruction to); a global `airbnb-swift-style` skill
  now exists at `~/.claude/skills/`.

## 2026-05-15 — ✅ ALL PHASES COMPLETE — committed to a branch

Phases 2–5 are implemented and **runtime-verified on a signed build**
(Phase 1 was pre-passed). Final state:

- **Phase 2** GRDB SQLite store (frozen-migration discipline, off-main
  `Sendable`), **Phase 3** one-way import + UI-on-SQLite + playlist-
  granularity playback + artwork + UserDefaults→SQLite migration,
  **Phase 4** app playlists + per-id app-playlist playback + play-count
  tracking + sortable stats + native CRUD/rename/delete, **Phase 5**
  smarter empty states + auto-start polish + native `.inspector()`
  extension boundary + edge hardening.
- Each phase passed an end-of-phase gate (swiftui-pro + macos-design +
  typography-designer + signed-build computer-use). The gates caught and
  drove fixes for real defects every phase — the 🔴 id round trip (twice,
  Phase 3, found via a temporary diagnostic probe), 4 UI defects (Phase 4),
  3 defects incl. a false perf estimate (Phase 5). All corrected and
  re-verified live (real audio plays for imported AND app playlists;
  play_count persists; rename/CRUD native; inspector clean & unclipped;
  title correct).
- `make check` green; `swift test` **67 tests / 14 suites green**; signed
  `make` build valid (`Apple Development: Thomas Ptacek (7F2QE7P59D)`).
- **Committed to branch `phases-2-5-local-first-sqlite`** (off `main` @
  `112e1b3`). NOT merged to `main`, NOT pushed (CLAUDE.md: agent never
  merges to main; no PR unless asked).
- **`PROBLEMS.md` added** — the consolidated, actionable index of every
  outstanding issue (USER distribution steps; agent-unverifiable runtime
  branches; accepted MusicKit-bound import cost; minor/polish; coverage
  gaps). `plans/risks-and-challenges.md` keeps the full narrative; PLAN.md
  index updated to point at PROBLEMS.md.
- No outstanding *regressions* or broken verified features. Remaining work
  is the USER's distribution run + the inherently-agent-unverifiable paths,
  all enumerated in `PROBLEMS.md`.

## 2026-05-15 — Phase 5 CORRECTIVE (3 defects from the signed gate) — code-complete, runtime-unverified, not committed

The orchestrator's signed-build computer-use run confirmed the GOOD Phase-5
items (auto-start polish; the native `.inspector()` boundary; smarter
empty-state logic + tests; import correctness) and caught **3 defects**. All
three are corrected here. `make check` green; `swift test` → **67 tests / 14
suites passed** (count unchanged — see D3). Signed `make` build produced.
**Not committed.** The agent CANNOT run the app; the orchestrator re-verifies
live (title = "DJ Roomba"; inspector fully readable; re-measured import
wall-clock).

**D1 — toolbar/window title regressed to "Inspector". FIXED.**
Root cause: Phase 5 added `.navigationTitle("Inspector")` to
`ExtensionInspectorView`. That view is presented via `.inspector()` *inside*
the `NavigationSplitView`, so its `.navigationTitle` propagated up and
clobbered the window title — and persisted with the inspector collapsed
because the modifier stays applied to the view tree. Pre-Phase-5 the detail
column had **no** `.navigationTitle`, so macOS fell back to `CFBundleName`
= **"DJ Roomba"** (the correct, conventional macOS window title — verified
against `git show HEAD:DJRoomba/Views/MainShellView.swift`, which had no
title modifier at all). Fix: **deleted `.navigationTitle("Inspector")`**;
the title now falls back to "DJ Roomba" exactly as before. The inspector's
own label ("Extension Inspector", `.headline`) was moved **inside** the
panel as the first `Form` `Section` — the native macOS inspector idiom
(Xcode/Numbers carry the inspector's identity in its content, never as the
window title). macos-design confirmed: a `.inspector()` panel must not set a
`.navigationTitle`; that is a window-level concern.

**D2 — inspector content clipped at BOTH window edges. FIXED (deeper root
cause — earlier inspector-content fix was only half of it).**

*First pass (kept, still correct):* `LabeledContent("Playlist", value:)`
value text defaulted to a single unconstrained line that the layout pushed
wider than the panel; the footer caption had no wrap affordance. Fixes
(swiftui-pro + macos-design): value text routed through an
`inspectorRow(_:_:)` helper — `.lineLimit(1)` + `.truncationMode(.tail)` +
`.textSelection(.enabled)` (ellipsize *within* the panel, truncated value
still recoverable — the Xcode/Numbers idiom); footer explainer gets
`.fixedSize(horizontal: false, vertical: true)` to wrap to as many lines as
needed. `LabeledContent` kept as the Form row idiom (swiftui-pro
`design.md`).

*Deeper root cause (THIS corrective):* the live signed build still clipped
on **both** edges with the inspector open — sidebar leading text cut
("ilter Playlists", "y Playlists") AND inspector trailing content cut
("91X Top 273 of 1992-" missing "1994", "Status St…", footer right edge).
The real defect was **scene-level, not inspector-content**:
`PlaylistPlayerApp` put a hard `.frame(minWidth: 1040, minHeight: 600)` on
`RootView()` *inside* the `WindowGroup`, wrapping a `NavigationSplitView` +
`.inspector()`. A clamping outer frame around a split view is an
anti-pattern (swiftui-pro: don't wrap a split view in a fixed frame it
can't fit neatly inside): the split view owns its own column layout; when
macOS **state restoration** pinned a frame narrower than 1040, the
`.frame(minWidth:1040)` forced the *content* to 1040 *inside the smaller
window*, so the split view overflowed and clipped **symmetrically on both
edges** instead of the window being widened. `.windowResizability(
.contentMinSize)` did not reliably floor the window because the binding
min was the arbitrary outer-frame clamp, not the split view's own reported
content minimum, and a stale saved frame could still defeat it.

*Idiomatic fix (swiftui-pro + macos-design):*
- **Removed the hard `.frame(minWidth:1040, minHeight:600)` on
  `RootView`.** The `NavigationSplitView` column minimums + the inspector
  column minimum now drive layout — no outer clamp fighting the split view.
- **`.windowResizability(.contentSize)`** (was `.contentMinSize`): ties the
  window's resizable minimum *directly* to the split view's reported
  content minimum = sidebar(min 220) + detail(min 480) + inspector open
  (min 300) ≈ **1000pt**. macOS clamps a restored window frame **up** to
  that content-derived minimum, so a stale narrow saved frame can no longer
  defeat the fix and the window is never allowed narrower than all three
  columns combined (handles state restoration correctly).
- Inspector column min raised **280 → 300** (native inspectors sit
  ~270–360pt) so the grouped `Form`'s label+value rows lay out cleanly at
  the narrowest; detail ideal trimmed **720 → 660** so the default opens
  with all three columns above their ideals.
- `.defaultSize(width: 1240, height: 760)` retained — comfortably above
  sidebar ideal 260 + detail ~660 + inspector ideal 320 with the inspector
  open.
- `ExtensionInspectorView` Form gets `.padding(.trailing, 4)` — a small
  trailing inset so the value text / wrapping footer never touch or clip at
  the panel's trailing edge even at the inspector's min width (symmetric
  with the grouped Form's leading inset).

Net: with the inspector open and a long-named playlist selected, the
window can no longer be narrower than sidebarMin+detailMin+inspectorMin, so
the sidebar leading text, the detail, and the full inspector content all
render inside the frame with no clipping at either edge — at default size
and after window-state restoration. **Code-complete; runtime-unverified**
(agent cannot run the app — orchestrator re-verifies live: inspector open
on "91X Top 273 of 1992-1994", nothing clipped either edge, at default
size and after relaunch). typography unaffected (no new type roles —
no type scale touched). swiftui-pro applied before & after (no fixed frame
on the split-view-bearing WindowGroup root; modern `.windowResizability`/
`.defaultSize`/`.inspectorColumnWidth`; no `GeometryReader`; no
force-unwrap); macos-design applied (native 3-pane + inspector,
content-driven window minimum, no outer clamp).

**D3 — the import "performance" change was ineffective and shipped with a
FALSE estimate. DIAGNOSED → REVERTED + DOCS CORRECTED (honest finding).**
Measured reality on the signed build: **~119 s, NO improvement over the
prior ~88 s (slightly worse)**, with a ~67 s stretch pegged at ~100% **one-
core CPU**, the DB not growing, stuck at "15 playlists / 947 songs", then a
burst to completion (and added instability — CPU spiked to ~147 % and a
transient inconsistent read mid-import).
- **Diagnosis (from the code + the profile):** the SQLite write path is
  fully batched and clean — `writePlaylist` builds a `[SongKey: Song]` dict +
  an `orderedKeys` array (all O(n)), then `upsertSongs` /
  `songIDsByKey` / `replaceApplePlaylistSnapshot` are chunked batch
  statements (pinned by `BatchImportTests`/`SnapshotReplaceTests`).
  `song(from:)` is O(1)/track. **There is NO app-side quadratic and NO
  per-row DB loop** anywhere in our import code. The 67 s @ 100% *one-core*
  CPU with **no DB growth**, stalled right after the sliding window reaches
  the library's one giant ~5075-track "AAA ME" playlist, is the signature of
  a **single CPU-bound, internally-serialized MusicKit operation**:
  `playlist.with([.tracks])` + `nextBatch()` materializing thousands of
  `MusicItemCollection<Track>` entries on macOS. A 5075-track playlist is
  one indivisible task that parallelism cannot split; concurrent
  `with([.tracks])` calls **contend on MusicKit's internal machinery** (the
  ~147 % spike + transient inconsistent read) instead of overlapping — which
  is *why* the `TaskGroup` made it worse, not better.
- **Decision: path (3) — the cost is irreducibly MusicKit-bound, so the
  ineffective bounded-parallel `TaskGroup` (window of 6) was REVERTED to the
  simple proven serial `for` loop.** No app-side quadratic exists to fix
  (path 2 N/A). Kept: the harmless **"Importing N of M playlists…"**
  progress affordance (counts still advance as each playlist is written).
  The SQLite write path is byte-for-byte unchanged, so the verified one-way
  isolation (`AppPlaylistCRUDTests`/`SnapshotReplaceTests`/`BatchImportTests`)
  stays green — confirmed (67/14, unchanged). No new test: D3 is a revert,
  not a quadratic fix; the existing batch/isolation tests already pin the
  unchanged write path.
- **Honest perf finding (replaces the false "20–35 s"):** a full re-import
  of a ~270-playlist / ~8200-track library is **~90–120 s**, dominated by
  MusicKit's per-playlist track resolution on macOS — **not** SQLite, **not**
  fixable by app-side parallelism. Accepted as the v1 cost; it is a one-time
  / Refresh-only operation, mitigated only by the progress affordance. The
  prior **"~88 s → ~20–35 s (estimated)"** claim was unmeasured and is
  **wrong** — it is struck from every doc and **not** restated with any new
  unmeasured number. The re-measured wall-clock is the orchestrator's to
  confirm; this code makes no perf claim beyond "the parallelism didn't
  help, so it's gone".

**Files changed (corrective):** `DJRoomba/App/PlaylistPlayerApp.swift`
(D2 deeper: removed the hard `.frame(minWidth:1040,minHeight:600)` outer
clamp on `RootView`; `.windowResizability` `.contentMinSize` →
`.contentSize` so the window minimum is the split view's content minimum
and state restoration can't pin it narrower; `.defaultSize` retained),
`DJRoomba/Views/ExtensionInspectorView.swift` (D1 title removed + label
moved inside as a Section; D2 `inspectorRow` helper with
truncation/selection + wrapping footer; D2 deeper: `Form`
`.padding(.trailing, 4)` trailing inset),
`DJRoomba/Views/MainShellView.swift` (D2 `inspectorColumnWidth`
280→300/320/420; detail ideal 720→660), `DJRoomba/Music/ImportService.swift`
(D3 `TaskGroup` → serial loop; progress UX kept; honest perf finding in the
doc comments).
Schema, the SQLite write path, playback recording, empty-state logic,
auto-start, and signing identities: **untouched** (verified-good Phase-5
items not regressed). Docs corrected: this entry, `PLAN.md` (Phase 5
summary), `PROGRESS.md` Phase-5 entry (false estimate struck in place),
`plans/architecture.md`, `plans/risks-and-challenges.md`,
`plans/roadmap.md`. swiftui-pro applied before & after (Form/LabeledContent
idiom, structured concurrency serial loop, no GCD/`Task.detached`, switch-
expression, no force-unwrap); macos-design applied to D1+D2 (inspector
identity inside the panel, native panel width, truncate-not-clip);
typography unaffected (no new type roles — reused `.headline` for the
in-panel inspector label and the existing `.caption`/`.secondary` tier).

## 2026-05-15 — Phase 5 (POLISH, EXTENSION READINESS, HARDENING) — code-complete, runtime-unverified, not committed

The final phase. Polish, the extension boundary surface, edge hardening, an
import perf pass, broader tests, the final skill review, and distribution
readiness (docs/analysis only — **nothing notarized**). `make check` green;
`swift test` → **67 tests / 14 suites passed** (51/11 → 67/14: +9
`LibrarySidebarStateTests`, +4 `MusicContextBoundaryTests`, +3
`EdgeHardeningTests`). Signed `make` build produced: `build/DJRoomba.app`,
codesigned `Apple Development: Thomas Ptacek (7F2QE7P59D)`, team `KK7E9G89GW`,
bundle `org.sockpuppet.djroomba`, valid on disk, satisfies its Designated
Requirement. **Not committed.** The agent CANNOT run the app — the
orchestrator runs the final signed gate (see "Runtime-unverified" below).

**What was built (per Phase-5 scope):**

1. **Smarter empty / error states (cause inferred).** New pure, unit-tested
   `LibrarySidebarState.resolve(...)` cross-checks `MusicSubscription`
   (`hasCloudLibraryEnabled` — the key signal, confirmed present on the macOS
   26.4 SDK) + authorization + import/store problem + summaries to decide the
   *cause*: `.libraryNotSynced` (Sync Library off → MusicKit genuinely has no
   on-device library — distinct from empty), `.subscriptionNeeded`,
   `.noImportedPlaylists`, `.error`, `.loading`, `.populated`. New
   `SidebarUnavailableView` renders the matching native, non-modal
   `ContentUnavailableView` with the action that actually fixes it
   ("Open Music" deep-link for not-synced; "New Playlist" stays reachable in
   every empty case — the create affordance is a destination). `PlaylistSidebar`
   routes on `controller.sidebarState`; the decision is out of the view body
   (swiftui-pro). Retires the risk register's "Empty/failure modes are silent".

2. **Now-playing auto-start polish (carried Phase-3/4 follow-up).**
   `PlaybackService.setQueueAndPlay`: after `player.play()` + the existing
   bounded `confirmPlaybackStarted()`, if not yet `.playing` it **re-issues
   `play()` once** (bounded, idempotent, structured concurrency) — on macOS the
   queue can still be loading when `play()` resolves and the engine settles to
   `.paused` (the "showed ▶ at 0:05 until the transport was pressed"
   symptom). `confirmPlaybackStarted()` now calls `refreshSnapshot()` the
   **instant** it sees `.playing` so the now-playing bar flips to playing
   immediately (no waiting for the next 0.5 s poll, no manual transport
   nudge). The verified `play_event`/`song_stat` recording is unchanged — it
   still fires only on the confirmed start (`didStart`), so play-tracking is
   NOT regressed.

3. **Extension surface — the collapsible `.inspector()`.** `MainShellView`
   gains a native macOS-14 `.inspector(isPresented:)`, **collapsed by
   default** (`@SceneStorage "inspectorPresented" = false`), toggled from a
   trailing toolbar button (`sidebar.trailing` — the standard inspector-toggle
   placement/idiom). New `ExtensionInspectorView` is a `Form`/`Section`/
   `LabeledContent` panel that **observes the read-only `MusicContext`** and
   acts **only** by submitting `MusicCommand`s to `controller.handle(_:)` —
   it never imports/touches `ApplicationMusicPlayer`, the MusicKit services,
   or the store (the exact contract a future extension must honor, proven by
   construction). `MusicContext` enriched with display fields
   (`selectedPlaylistName`/`nowPlayingTitle`/`nowPlayingArtist`, an
   `isPlaying` convenience) — still plain `Sendable`/`Equatable` `String`s +
   the local `Status` enum, **no MusicKit identity types cross the boundary**
   (`PlayerStateSnapshot.Status` made `Equatable`). This is the M3 boundary,
   finally realized as a real surface.

4. **Edge / error hardening + tests.** Audited the spec checklist:
   disappeared-playlist (controller already clears selection silently after
   re-import — verified path), unplayable/region-removed track (resolver
   tolerates + reports via `playbackProblem` — verified), rapid playlist
   switching (`PlaylistDetailService.select` cancels the in-flight load —
   now pinned by a test that three back-to-back selects land on the *last*),
   clear-drops-in-flight-load (tested), network-down during import/resolve
   (caught → inline `lastError`/`playbackProblem`). New `EdgeHardeningTests`
   (3) cover the deterministic parts; network-down / huge-library remain
   signed-run / load behaviors.

5. **Performance pass for large libraries (bounded-parallel import).**
   > ⚠️ **SUPERSEDED — see the "Phase 5 CORRECTIVE" entry at the top.** The
   > bounded-parallel `TaskGroup` described below was **measured ineffective**
   > on the signed build (~119 s — no improvement over the prior ~88 s,
   > slightly worse, plus instability) because the dominant cost is
   > MusicKit's own per-playlist track resolution on macOS, which is CPU-
   > bound and internally serialized (a single huge library playlist alone
   > is an indivisible long task; concurrent `with([.tracks])` calls contend
   > rather than overlap). It was **reverted to the simple serial loop**,
   > keeping only the "Importing N of M" progress affordance. **The
   > "~88 s → ~20–35 s (estimated)" claim below is WRONG and was never
   > measured.** Honest finding: a full re-import of a ~270-playlist /
   > ~8200-track library is **~90–120 s**, MusicKit-bound, accepted as the
   > v1 cost (one-time / Refresh-only). The original text is retained
   > verbatim below only as audit history; do not act on it.

   _(Audit history — superseded by the corrective above.)_ The
   ~88 s first import was dominated by the **MusicKit** per-playlist
   `playlist.with([.tracks])` paging issued strictly one-at-a-time across
   ~270 playlists (NOT SQLite — batch idioms already correct & tested). The
   slow part is network/IO-bound, so the track fetch is now **bounded-parallel**
   via a sliding `TaskGroup` window of **6** (`Playlist`/`Track` are
   `Sendable`, verified on the SDK; structured concurrency, no GCD, doesn't
   flood MusicKit — same philosophy as the Phase-4 resolver). The SQLite
   write path (`writePlaylist` = the unchanged batched UPSERT + transactional
   snapshot replace) stays **strictly serial** so the proven **one-way
   isolation is not regressed at all** — only *when* the slow fetches happen
   changed (the existing `AppPlaylistCRUDTests` isolation invariant + the
   `BatchImportTests` still pass unchanged). Progress affordance: the sidebar
   loading state now shows **"Importing N of M playlists…"**
   (`controller.libraryLoadingMessage` from `ImportService`'s existing
   counts, which now advance as each playlist is *written*). ~~**Estimated
   effect:** with the dominant cost being ~270 sequential network round-trips,
   a window of 6 should cut wall-clock by roughly the parallelism factor
   (order-of-magnitude: ~88 s → ~20–35 s, throttling-dependent) — *estimated,
   not measured*~~ **[STRUCK: false, never measured — see corrective]**
   (the orchestrator's signed
   run is the measurement). **Incremental import: investigated, DELIBERATELY
   DEFERRED** — `Playlist.lastModifiedDate` exists on the SDK, but on the
   macOS-14 *library* it is in the same frequently-nil category as
   `trackCount`/`isEditable`/`description` (risk register), and skipping a
   re-import on a mis-read/nil date would silently ship a **stale snapshot**
   — a correctness regression of the verified one-way import, which the scope
   forbids. The safe high-confidence win (parallel fetch, zero correctness
   risk, no schema change) was shipped; faking an unreliable signal was not
   (scope: "if not cleanly available, don't fake it"; "prefer a solid
   finish"). No schema change anywhere in Phase 5 (`eraseDatabaseOnSchemaChange`
   stays false; v1 frozen).

6. **Broadened tests + final skill pass.** +16 tests (see counts above). Skill
   gates applied **before & after**: swiftui-pro (drove: pure
   `LibrarySidebarState.resolve` out of the view body; `sheet`/state idioms;
   `@SceneStorage` for inspector collapse not inside `@Observable`; structured
   concurrency for the auto-start re-issue + bounded import `TaskGroup`;
   `Sendable` `MusicContext` boundary; *after*: extracted inspector button
   actions into methods — `togglePlayPause`/`playSelected` — no logic in
   `body`/closures, one type per file, `action:` shorthand, no force-unwrap,
   no deprecated API), macos-design (native `.inspector()` Form/Section/
   LabeledContent collapsed-by-default with the standard trailing toolbar
   toggle; cause-specific non-modal `ContentUnavailableView`s with the
   fixing action; minimal not a feature dump), typography-designer (**no new
   type roles** — `ContentUnavailableView` keeps its native type; the
   inspector uses default macOS `Form`/`LabeledContent`/`Section` styling +
   the existing `.caption`/`.secondary` notice tier for the one explainer
   line; confirmed consistent with the established scale).

7. **Distribution readiness (analysis + docs only — NOTHING notarized).**
   Reviewed `make dist`/`build.sh`/`Makefile`/entitlements/Info.plist for
   internal consistency: the pipeline (`check-version → clean → release →
   sign → zip-notary → notarize → staple → zip-release → checksum →
   verify-release`) is internally consistent; the two-zip dance is correct
   for offline Gatekeeper; `notary-setup` is correctly blocked from
   non-interactive shells; entitlements (`app-sandbox` + `network.client`) +
   `NSAppleMusicUsageDescription` are distribution-correct for the
   library-only MusicKit path; the dev build signs cleanly with no embedded
   profile (Phase-1 fact, re-confirmed). **Did NOT run `make
   dist`/`notarize`/`notary-setup`** (cannot — they need the user's
   interactive setup + a `vX.Y.Z` tag + Apple credentials; the Makefile
   intentionally blocks `notary-setup` from non-interactive shells, respected).
   Signing identities unchanged. Analysis of the open question + the exact
   remaining USER steps are in `plans/risks-and-challenges.md` (Distribution)
   and the "Remaining user steps to ship" section below.

8. **Catalog search:** DEFERRED (documented, not half-implemented) — the
   entire shipping path is library-namespace by provenance; the catalog
   request branch stays dormant; adding catalog search would activate the
   open catalog/MusicKit-App-Service/distribution risk and is out of scope
   for a solid finish (scope sanctions documenting it deferred).

**Runtime-unverified (the orchestrator's final signed gate):** the
cause-specific empty/error states (need a not-synced / no-subscription Mac
state to truly exercise each branch — the *logic* is unit-tested, the
MusicKit signals are not), the auto-start (Play reliably begins *playing* with
no transport nudge + the now-playing bar flips immediately), the inspector
(toggle, observes live `MusicContext`, commands act, never crashes the
player), edge cases under a real library, and the **measured** import
wall-clock improvement. Code-complete here; honestly not runtime-exercised
(no live MusicKit/account/subscription in the agent environment).

**Remaining USER steps to ship (distribution):**
1. `make notary-setup` once — interactive; stores the `djroomba-notary`
   keychain profile (app-specific password from appleid.apple.com). The
   agent cannot and must not do this.
2. `git tag vX.Y.Z` then `make dist` — Developer ID sign + hardened runtime
   + notarize + staple + zip + checksum + `spctl` verify.
3. **The open MusicKit-App-Service question (analyzed):** the most likely
   answer is that the **library-only** path DJ Roomba ships (provenance
   `.library`, `MusicLibraryRequest`/`ApplicationMusicPlayer` only, catalog
   branch dormant) needs **no embedded provisioning profile** on a notarized
   Developer ID build either — consistent with Phase 1's finding that the
   dev build needed none, because the MusicKit App Service / a
   `com.apple.developer.musickit` entitlement gates **catalog** + the
   developer-token web flow, neither of which the shipping path exercises.
   This is **not yet runtime-proven for a Developer-ID/notarized build**
   (different cert chain; notarization validates capabilities against the
   App ID). If the notarized build fails to read the library, the
   pre-wired escape valve is: enable the MusicKit App Service for App ID
   `org.sockpuppet.djroomba` in the Developer portal, generate a
   `.provisionprofile`, and `make dist PROVISION_PROFILE=/path/to.profile`
   (build.sh embeds it + the sign step picks it up). No code/signing-identity
   change is needed for this; it is a portal + one-flag step.
4. Each end user needs their own active Apple Music subscription + their own
   system Apple Account with Sync Library on (Option A, by design; the new
   empty states now explain this in-app if it's missing).

- Files: **new** `DJRoomba/Models/LibrarySidebarState.swift`,
  `DJRoomba/Views/Sidebar/SidebarUnavailableView.swift`,
  `DJRoomba/Views/ExtensionInspectorView.swift`,
  `Tests/DJRoombaTests/LibrarySidebarStateTests.swift`,
  `Tests/DJRoombaTests/MusicContextBoundaryTests.swift`,
  `Tests/DJRoombaTests/EdgeHardeningTests.swift`. **Changed**
  `MusicSubscriptionService.swift` (+`hasCloudLibraryEnabled`),
  `MusicController.swift` (+`sidebarState`/`libraryLoadingMessage`; enriched
  `musicContext`), `PlaybackService.swift` (auto-start re-issue + immediate
  snapshot), `MusicContext.swift` (display fields + `Equatable` +
  `isPlaying`), `PlayerStateSnapshot.swift` (`Status: Equatable`),
  `ImportService.swift` (bounded-parallel fetch — **later reverted to serial
  in the Phase-5 CORRECTIVE; see top entry** / serial unchanged write),
  `PlaylistSidebar.swift` (routes on `sidebarState`),
  `MainShellView.swift` (`.inspector()` + toolbar toggle). Schema, the
  write path, playback recording, and signing identities: **untouched**.
- Docs updated: this entry, `plans/roadmap.md` (Phase 5 status),
  `plans/risks-and-challenges.md` (retired/downgraded resolved items +
  Distribution steps), `plans/architecture.md` (extension surface as built +
  the import perf shape + empty-state inference), `PLAN.md` index still
  accurate. **Not committed** (CLAUDE.md).

## 2026-05-15 — Phase 4 ✅ PASSED the signed runtime gate (all D1–D4 fixed; one orchestrator fix)

Phase 4 is **runtime-verified on a signed build** against the real library
after one functional pass + two UI correctives + one surgical orchestrator
fix. `make check` green; `swift test` **51/11** green; signed build valid;
**nothing committed** (HEAD `112e1b3`).

**Verified live:**
- App-playlist **CRUD**: create (`+`/⌘N), add songs (track context-menu
  "Add to Playlist ▸" submenu), **rename** (native modal `RenamePlaylistSheet`
  via context-menu trigger — commits on Return *and* the Rename button *and*
  blur, Esc cancels, text auto-selected), delete (native `confirmationDialog`
  with reassuring copy). **One-way isolation DB-confirmed**: every app
  mutation left `apple_playlist*`/`song`/`play_event` counts unchanged.
- **App-playlist playback** via the per-id `equalTo` re-resolution
  (`resolveAppPlaylist`, bounded TaskGroup) — **real audio played**
  ("Give It Away"); this is the 🟠 app-playlist re-resolution risk's
  Phase-4 resolution, now proven.
- **Play-tracking bug fixed** (the Phase-3 follow-up): `play_event` +
  `song_stat` now record on *confirmed* playback start —
  observed play_count increment to 1→2→3 and persist, `last_played_at`
  surfaced as "N minutes ago".
- Sidebar "My Playlists" section, **sortable Plays/Last Played columns**,
  all reactive (D3 count / D4 stats refresh verified live).

**The 4 UI defects the first gate caught — all fixed & re-verified:**
- **D2** phantom rounded-gray Table rows → `.bordered(alternatesRowBackgrounds:)`
  clean native empty space. ✅
- **D3** stale sidebar count → `PlaylistSummary.==` now compares
  `trackCount`+`name` so the row re-renders. ✅
- **D4** stale Plays/Last Played → `PlaylistDetailService.refreshStats(for:)`
  on discrete events (play recorded; (re)selection). ✅
- **D1** rename → moved to a deterministic modal sheet (focus/select were
  unreliable inline-in-`List`); the double-click-rename gesture removed
  (it collided with the M2 double-click-to-play). **Final orchestrator
  fix:** `PlaylistSidebarList`'s `.onKeyPress(.return)` Return-to-play was
  unscoped and hijacked Return from the rename sheet's default button
  (Return *played* instead of committing). Gated it on `listFocused` so
  Return-to-play only fires when the sidebar list itself is focused — M2
  Return-to-play unchanged for keyboard nav; the sheet (and the search
  field) now correctly own Return when focused. Verified: Return in the
  sheet commits + dismisses + persists, `play_event` unchanged.

Skill gates: swiftui-pro (focus/concurrency/`@FocusState`/`.onKeyPress`
scoping — clean), macos-design (modal rename + native Table empty space +
context menu + confirm dialog — native, validated live), typography-designer
(no type changes — confirmed). Non-blocking Phase-5 polish carried:
playback can start paused until the transport is pressed (now-playing
snapshot immediacy / auto-start).

## 2026-05-15 — Phase 4 D1 ROBUSTNESS FIX (rename collision + inconsistent commit) — code-complete, runtime-unverified, not committed

The prior Phase-4 UI corrective's D2/D3/D4 fixes were runtime-verified by the
orchestrator and are **untouched**. Its D1 fix (inline-in-`List` rename) was
re-tested on the signed build and still failed the stickler bar with **two**
remaining defects, both root-caused and fixed here as a single, robust,
trigger-independent rename path. Only the rename trigger + the rename editor
changed — playback, the D2/D3/D4 fixes, the data layer, schema, and
`renameAppPlaylist` are **untouched** (the DB persists correctly whenever
commit actually fires; the bug was that commit didn't reliably fire). `make
check` green; `swift test` → **51 tests / 11 suites passed** (unchanged — this
is a view/presentation change; the testable rename logic still lives in the
already-tested `AppPlaylistService.rename` / `LibraryStore.renameAppPlaylist`
path, and `UIRefreshCorrectionTests.summaryEqualityReflectsName` still pins
that a name change re-renders the row). Signed `make` build produced:
`build/DJRoomba.app`, codesigned `Apple Development: Thomas Ptacek
(7F2QE7P59D)`, valid on disk, satisfies its Designated Requirement. **Not
committed.** The agent CANNOT run the app — the orchestrator re-runs the
signed gate (context-menu Rename → focused field with selected text → Return
commits+dismisses+persists; re-enter → click Rename button commits+persists;
re-enter → Esc/Cancel = no change; double-click a My-Playlists row does NOT
rename).

- **Root cause (1) — double-click rename ↔ play collision.**
  `AppPlaylistRowItem` carried a `.simultaneousGesture(TapGesture(count: 2))`
  that called `beginRename()`. The enclosing `List(selection:)` already
  treats a double-click (and Return) on a sidebar row as "play this
  playlist" (an M2 feature: `PlaylistSidebarList`'s `.onKeyPress(.return)` +
  the List's own double-click row activation, both routing to
  `playSelectedPlaylist()`). A double-click on a "My Playlists" row therefore
  *both* started rename *and* started playback (`play_event` bumped) —
  jarring, unacceptable. *Fix:* the `.simultaneousGesture` is **removed
  entirely**. Rename is **context-menu-only** ("Rename", the discoverable,
  standard, collision-free macOS trigger). Double-click on a My-Playlists row
  now does exactly what it does on every other sidebar row (select / play),
  nothing else. The optional slow-second-click Finder idiom was deliberately
  NOT added — on macOS 14 it cannot be cleanly distinguished from the List's
  double-click/Return-to-play without risking that M2 behavior; context-menu-
  only is the clean, native choice (macos-design).
- **Root cause (2) — inconsistent commit across triggers.** The commit-on-
  blur path lived in `.onChange(of: fieldFocused)` on a `TextField`
  *conditionally swapped into a `List(selection:)` row*. `@FocusState` on
  that field competes with the `List`'s own first-responder/selection
  handling, and the field-editor `selectAll` is timing-sensitive. When
  rename was entered via the **context menu**, the menu's focus handoff
  raced the `.task(id: isRenaming)` `Task.yield()`-then-focus so the field
  often never truly became first responder; clicking the detail pane then
  produced no `focused → false` transition, so `commit()` never ran and the
  typed name was lost. A double-click-initiated rename happened to win the
  focus race differently and *did* commit on blur — hence the inconsistency.
  The blur-commit through `@FocusState` inside a conditional `TextField`
  inside a `List` is fundamentally timing-fragile (the List steals the
  click/Return the field needs). *Fix:* **the rename editor is now a modal
  `RenamePlaylistSheet`** (new `RenamePlaylistSheet` + a small
  `PlaylistRenameRequest` `Identifiable` value driving `sheet(item:)`). A
  sheet's `TextField` is the *sole* first responder — the `List` no longer
  competes — so focus + select-all are deterministic, and commit is an
  **explicit, identical** Rename (default button / Return) or Cancel
  (Esc / Cancel button) **every time, regardless of trigger**. The single
  `commit()` (with the `canCommit` non-empty guard) is the one code path;
  `controller.renameAppPlaylist` still ignores empty/unchanged names. The
  click-away-commits requirement of the old inline design is replaced by the
  sheet's explicit, unambiguous Rename/Cancel — *more* consistent, not less
  (no ambiguous "where did I click to blur" path remains).
- **Chosen design + macos-design rationale.** Trigger: context-menu only
  (double-click is already "play" here; overloading it was the collision).
  Editor: a small modal rename sheet — a **standard, fully native macOS
  pattern** (the common fallback Mac apps use for sidebar rename when inline
  is unreliable; macos-design: panels/sheets for modal-ish interactions).
  Given the proven inline-in-`List` fragility on macOS 14, correctness over
  the inline aesthetic — the spec explicitly sanctions the sheet when it is
  more robust, and it is 100% consistent. The new-playlist flow still drops
  straight into rename (create → the row lands in `summaries` → the sheet
  opens via `.onChange(of: summaries)`, deterministic against the async
  store reload). The destructive-delete `confirmationDialog` is unchanged.
- **swiftui-pro before & after.** *Before* drove: a modal `sheet(item:)`
  over fighting `@FocusState` inside a `List` row; the
  `Task.yield()`-then-focus + AppKit field-editor `selectAll` kept (now
  deterministic because the sheet owns first responder); structured
  concurrency only (no GCD/`asyncAfter`/`Task.sleep` hack); one commit path
  guarded by `canCommit`. *After* review applied/clean: `sheet(item:)` for
  safe optional unwrap (navigation.md), button actions as methods, accessible
  buttons (text labels + `.defaultAction`/`.cancelAction` roles, no icon-only
  / no `onTapGesture`-as-action), `AppKit` auto-imported (no redundant
  `import`), no force-unwrap, one type per file, no deprecated API. The
  immediate `openPendingRenameIfReady(in: summaries)` fast-path in
  `createPlaylist()` reads a possibly-stale captured snapshot but is
  idempotent and backstopped by `.onChange(of: summaries)` — correct by
  design, not a defect.
- **typography-designer: not triggered — zero type changes.** The sheet's
  title is the semantic `.headline`, the field default `TextField` text, the
  buttons default — no new font / size / weight / scale / label-role. The row
  reverts to the pre-existing `.body` name + `.caption`/`.secondary` count
  (identical to the imported `PlaylistSidebarRow`).
- Files: **new** `DJRoomba/Models/PlaylistRenameRequest.swift`,
  `DJRoomba/Views/Sidebar/RenamePlaylistSheet.swift`; **changed**
  `AppPlaylistRowItem.swift` (gesture removed; rename props slimmed to
  `beginRename`), `AppPlaylistSidebarRow.swift` (reverted to a plain
  non-editing row — no `TextField`/`@FocusState`/`.task`/AppKit hack),
  `AppPlaylistSidebarSection.swift` (`renamingID` → `renameRequest` +
  `sheet(item:)` + create-then-rename deferral). `MusicController.rename
  AppPlaylist`, playback, data layer, schema, D2/D3/D4: **untouched**.
- Docs updated: this entry, `plans/architecture.md` (the Phase-4 UI
  corrective's inline-rename note superseded by the sheet), `PLAN.md`
  Milestone-4 line still accurate. **Not committed** (CLAUDE.md).

## 2026-05-15 — Phase 4 UI CORRECTIVE (4 stickler-bar UI defects) — code-complete, runtime-unverified, not committed

The Phase-4 signed-build gate confirmed the **core works** (app-playlist CRUD
with one-way isolation DB-verified; per-id app-playlist playback plays real
audio; play-tracking fires on confirmed start; native context menu + delete
dialog) but caught **4 UI defects** that failed the UI bar. All four are
view/reactivity bugs — the verified-good data layer, playback, resolution and
schema are **untouched** (no schema change). `make check` green; `swift test`
→ **51 tests / 11 suites passed** (46→51: +5 `UIRefreshCorrectionTests`
pinning the D3 equality + D4 stats-refresh fixes). Signed `make` build
produced: `build/DJRoomba.app`, codesigned `Apple Development: Thomas Ptacek
(7F2QE7P59D)`, team `KK7E9G89GW`, bundle `org.sockpuppet.djroomba`, valid on
disk, satisfies its Designated Requirement. **Not committed.** The agent
CANNOT run the app — the orchestrator re-runs the signed gate (rename via
menu + double-click; no phantom rows; sidebar count after add; Plays/Last
Played after a play). Code-complete; runtime-unverified.

- **D1 — inline rename was non-functional → fixed.** *Root cause:* the
  rename `TextField` is inserted by `if isRenaming` in
  `AppPlaylistSidebarRow`; `.task(id: isRenaming)` set `@FocusState`
  `fieldFocused = true` in the **same** update pass, before SwiftUI had
  committed the conditional branch and registered the `.focused` binding —
  setting focus on a field not yet in the focus system is a no-op, so the
  field appeared but never took the keyboard (the observed "faint invisible
  box"). Also: **double-click was never wired** (only the context menu
  existed) so that path could never have worked. *Fix:* in the `.task`,
  `await Task.yield()` once (structured concurrency — no GCD/`asyncAfter`) so
  the `TextField` is in the hierarchy and the `.focused` binding registered,
  then assign focus (re-guarded for `isRenaming` + cancellation after the
  suspension). Added select-all on the focus-gained transition via the key
  window's field editor (`@MainActor` AppKit, no representable — macOS 14 has
  no SwiftUI text-selection API) so typing replaces the name, the Finder /
  Music.app idiom. Wired double-click: `.simultaneousGesture(TapGesture(count:
  2))` on `AppPlaylistRowItem` (simultaneous so the List's single-click row
  selection still works; ignored while already editing). Return / blur commit
  + Esc cancel + the double-commit guard are kept; the blur path now only
  commits on focus-**loss** (the gained branch does select-all).
- **D2 — phantom empty rounded-gray pill rows → fixed.** *Root cause:* the
  detail `Table` used the default (`.automatic` → `.inset`) table style,
  whose rounded selection-shaped row backgrounds get drawn for **every empty
  row** below the content in a `NavigationSplitView` detail — the "~7+ empty
  pills" look. *Fix:* `.tableStyle(.bordered(alternatesRowBackgrounds:
  true))` — the flat, full-width alternating striping Music.app / Finder use;
  the empty area below the last track now reads as a clean continuation of
  the table with no rounded shapes (macos-design: native Table empty-space
  treatment).
- **D3 — sidebar "My Playlists" count stale after add/remove → fixed.**
  *Root cause:* the reload path was already correct
  (`AppPlaylistService.load()` re-runs the grouped `appPlaylistTrackCounts()`
  query after every membership write), but `PlaylistSummary.==` compared
  **only `id` + `isFavorite`**, omitting `trackCount`. When the reloaded
  summaries had the same id/favorite but a new count, SwiftUI's `ForEach`
  diffed the row as **unchanged** and never rebuilt its body → "0 tracks"
  persisted. ("Recently Played" looked right because playing the list
  *inserted* that row fresh, forcing a body build with the then-current
  count.) *Fix:* `PlaylistSummary.==` now also compares `trackCount` and
  `name` (so an inline rename re-renders too). Hash stays **id-only** — the
  `Hashable` contract only requires equal values to hash equally and `==`
  still implies equal `id`; no `Set<PlaylistSummary>`/dictionary-key usage
  exists. Efficient: no new query, the count still comes from the single
  grouped batch query (SQLite-idioms guidance honored).
- **D4 — Plays / Last Played columns stale → fixed.** *Root cause:*
  `PlaylistDetailService` caches `PlaylistDetail` per playlist id and only
  (re)loads on a cache **miss** or explicit `invalidate()`; after
  `recordPlay` bumped `song_stat` nothing refreshed the cached rows, and
  re-selecting hit the stale cache. *Fix:* added
  `PlaylistDetailService.refreshStats(for:)` — re-runs the single
  `songsWithStats` LEFT-JOIN query **once** and splices the fresh
  `playCount`/`lastPlayedAt` back into the existing rows (membership/order
  unchanged). Driven by **discrete events only**: `MusicController`
  `recordPlayStart` calls it right after `store.recordPlay`, and `select()`
  on a cache hit serves cached rows instantly then kicks one background
  stats refresh on that (re)selection. No refresh loop, no per-tick / per-row
  re-query — the now-playing 0.5 s snapshot tick is untouched. A failed
  stats refresh is non-fatal (keeps the rows, no error for a count update).
- swiftui-pro consulted **before** (drove: `Task.yield()`-then-focus over
  GCD/`asyncAfter` for the `@FocusState` appearance-timing fix; discrete-
  event `refreshStats` over a `ValueObservation`/tick; id-only hash with a
  broader `==`; `.simultaneousGesture` so row selection survives the double-
  click) and **after** (review applied: removed a redundant `import AppKit`
  — SwiftUI re-exports AppKit on macOS so `NSApp` resolves; everything else
  reviewed clean: structured concurrency only, methods-not-body, modern
  non-deprecated APIs, Hashable contract upheld). macos-design drove the
  Finder/Music inline-rename idiom (auto-focus + select-all + double-click,
  commit-on-Return/blur, cancel-on-Esc) and the flat native Table empty-
  space treatment (`.bordered` striping, no rounded pills).
  **typography-designer: not triggered — zero type changes** (no font /
  size / weight / scale / new label-role changes; the rename field still
  `.body`, the count still `.caption`+`.secondary`, the table cells
  unchanged).
- Docs updated: this entry, the Phase-4 entry's tail (points here),
  `plans/architecture.md` (the D3 equality + D4 stats-refresh notes),
  `PLAN.md` index still accurate. **Not committed** (CLAUDE.md).

## 2026-05-15 — Phase 4 (APP OWNERSHIP: PLAYLISTS + PLAY COUNTS) — code-complete, runtime-unverified, not committed

The actual product value: the user owns their library locally. App playlists
(SQLite-only, never written to Apple), per-song app-playlist playback, the
play-tracking bug fixed, play stats surfaced as sortable Table columns. `make
check` green; `swift test` → **46 tests / 10 suites passed** (35→46: +10
`AppPlaylistCRUDTests`, +1 app-playlist reassembly test). Signed `make` build
produced: `build/DJRoomba.app`, codesigned `Apple Development: Thomas Ptacek
(7F2QE7P59D)`, team `KK7E9G89GW`, bundle `org.sockpuppet.djroomba`, valid on
disk, satisfies its Designated Requirement; the exported drag UTI is in the
bundled Info.plist. **Not committed.** The agent CANNOT run the app — app-
playlist playback (real audio), play-count persistence, and the sidebar
CRUD/drag UX remain for the orchestrator's signed runtime gate; nothing about
playback or persistence is claimed verified here.

- **App-playlist CRUD (SQLite-only, batch idioms, one-way isolation).**
  Extended `LibraryStore` with `createAppPlaylist(named:)` (sort_index =
  `MAX+1` computed inside the write so concurrent creates can't collide),
  `renameAppPlaylist`, `deleteAppPlaylist` (membership cascades per the v1
  FK; song/stat/history untouched), `addSongsToAppPlaylist` (append at tail,
  chunked multi-row INSERT, next-position read inside the same txn),
  `removeTracksFromAppPlaylist` (chunked `IN` delete + dense renumber, all in
  one txn — keeps the `(playlist,position)` PK gap-free), `setAppPlaylistTracks`
  (bulk-delete + chunked multi-row re-insert — the reorder/replace path),
  `reorderAppPlaylists` (chunked `CASE … WHEN` UPDATE — no per-row loop),
  `appPlaylistTrackCounts` (one grouped query for sidebar counts),
  `songsWithStats(in{App,Apple}Playlist:)` (one indexed LEFT JOIN on
  `song_stat`). **No schema change** — the Phase-2 `app_playlist*` tables +
  v1 cascade sufficed (v1 stays frozen; `eraseDatabaseOnSchemaChange` still
  false). New `AppPlaylistService` (`@MainActor @Observable`) owns the
  user-playlist listing + CRUD, awaits the off-main store, reloads from
  SQLite after each write (no dual store). 10 new tests prove order,
  duplicates, chunk-boundary correctness (800-song add), the delete cascade,
  and — crucially — that **every** app-playlist mutation leaves the imported
  `apple_playlist*` snapshot + song/stat/history untouched.
- **App-playlist playback — the per-song 1:1 path (the 🟠 open item,
  resolved in code).** Imported Apple playlists keep the proven
  playlist-granularity re-resolve (`resolvePlaylist`). App playlists are
  arbitrary songs with no backing Apple playlist, so `MusicController.resolve
  AndPlay` now branches on `detail.isAppOwned` to the new
  `PlaybackResolver.resolveAppPlaylist(rows:startAt:)`: it re-resolves each
  **unique** stored library id via `MusicLibraryRequest<MusicKit.Song>`
  `.filter(matching:\.id, equalTo:)` **one id at a time** (the Phase-3 probe
  established this preserves the query→result 1:1 correspondence; only batch
  `memberOf` loses it because the returned `Song.id` differs), issued through
  a **bounded** `TaskGroup` (sliding window of 8 — structured concurrency, no
  GCD, no flooding MusicKit), keyed by the **stored** id, then `reassemble`d
  in playlist order tolerating misses (reported via the existing inline
  `MusicController.playbackProblem`). The disproven batch-`memberOf`
  `resolve(rows:startAt:)` + its `fetchLibrarySongs` helper were **removed**
  (dead, contradicted the working path); the pure `groupByNamespace`/
  `reassemble` helpers + tests are kept and now back `resolveAppPlaylist`.
  Reuses the **unchanged** `PlaybackService`. **Runtime-unverified** — the
  per-id `equalTo` re-fetch + audio is a signed-run check (the agent can't
  run it). Verified MusicKit API shapes (macOS 26.4 SDK): `MusicLibraryRequest
  <Song>.filter(matching:\.id, equalTo: MusicItemID)`, `.limit`, `.response()`
  → `MusicItemCollection<Song>`; `MusicItemID` conforms to the equatable
  filter-value protocol; `MusicKit.Song` is `Sendable` (crosses the
  `TaskGroup`; strict-concurrency build clean).
- **Play-tracking bug fixed (the Phase-3 follow-up).** The old `if playback.
  snapshot.isPlaying` guard read the 0.5 s-polled snapshot too early so plays
  never recorded. `PlaybackService.play` now returns `Bool` and, after
  `player.play()`, `confirmPlaybackStarted()` polls the player's **own**
  `state.playbackStatus` on a short bounded loop (50 ms, ≤2.5 s, `Task.sleep
  (for:)` — never the nanoseconds form) until `.playing`. `recordPlayStart`
  fires only on a confirmed start and records the **stored `song.id`** the
  resolver now reports (`Resolution.startSongID`) — deterministic and correct
  for both paths, replacing the fragile now-playing-id→row match (the
  resolved `Song.id` ≠ the stored `music_item_id`, so that match was
  unreliable; this is the same Track-id≠Song-id finding). `recordPlay` /
  `song_stat` machinery (Phase 2) is unchanged and still tested.
- **Sidebar "My Playlists" + native CRUD/drag UI (macos-design reviewed).**
  New section distinct from Favorites / Recently Played / Library Playlists,
  **always present** (even with zero playlists / no imported library) so the
  create affordance is reachable. Inline `+` in the section header + `⌘N`
  (`CommandGroup(replacing: .newItem)`). Inline rename (`TextField` swapped
  into the row; Return / focus-loss commits, Esc cancels; double-commit
  guarded). Destructive delete via `confirmationDialog` (clean `$Bool`
  binding + `presenting:` — no `Binding(get:set:)`; copy reassures
  songs/play-counts are kept). Per-row context menu (Play / Rename /
  Favorite / Delete). Drag-to-reorder playlists (`onMove`). Track rows are
  `.draggable` (private `SongDragItem` `Transferable` over an exported
  app-scoped UTI — never a public interchange format) and "My Playlists"
  rows are `.dropDestination` so a dragged song appends; a track-table
  context-menu **"Add to Playlist ▸"** submenu is the always-reachable
  equivalent, plus **"Remove from Playlist"** when viewing an app playlist.
  Views extracted per swiftui-pro (`AppPlaylistSidebarRow`,
  `AppPlaylistRowItem`, `AppPlaylistSidebarSection`, `TrackContextMenu`,
  `SongDragItem`) — one type per file, button actions as methods, no
  `@ViewBuilder`-method body splitting.
- **Play count + last played as sortable Table columns.** Two new
  `TableColumn`s ("Plays", "Last Played"), and every column made sortable via
  `Table(…, sortOrder:)` + `KeyPathComparator` (default = playlist order, so
  an unsorted table is pixel-identical to Phase 3). Stats come from the one
  LEFT-JOIN `songsWithStats` query carried into `TrackRow` at load — sorting
  is in memory (fast; the rows are fetched once per selection, never re-hits
  SQLite). Non-optional sort keys (`albumSortKey`/`durationSortKey`/
  `lastPlayedSortKey`) so the native header sort is well-defined.
- swiftui-pro consulted **before** (drove: coarse intent-named store CRUD with
  batch SQL in one `write`; a separate `@MainActor @Observable`
  `AppPlaylistService` awaiting the off-main store; bounded `TaskGroup` for
  per-id resolution; `Resolution.startSongID` instead of fragile id-matching;
  in-memory `KeyPathComparator` sort over re-querying; `Transferable` over
  raw pasteboard) and **after** (applied: extracted the context menu +
  sidebar row/item into their own `View` files, button actions into methods,
  removed the dead disproven `resolve()`, bounded the resolve concurrency,
  guarded the rename double-commit, `$Bool`+`presenting:` over a manual
  binding, `.task(id:)` over `onAppear`, `Task.sleep(for:)`). macos-design
  drove the always-present "My Playlists" section, the inline-`+`/⌘N create,
  Finder-style inline rename, the destructive `confirmationDialog`, the
  context-menu + drag pairing (reachable equivalent), and keeping the table
  deliberately boring. typography-designer: **zero new type roles** — "Plays"
  reuses the `.body.monospacedDigit()`+`.secondary` numeric tier (like
  #/Time), "Last Played" the `.body`+`.secondary` text tier (like
  artist/album), the rename field `.body` (matches the row name), the section
  header the default `Section` styling (identical to the other sections).
- Docs updated: this entry, `plans/data-and-import.md` (the app-playlist CRUD
  store API + per-song re-resolution + play-tracking trigger), `plans/
  architecture.md` (Phase 4 layering: `AppPlaylistService`, the two playback
  paths), `plans/risks-and-challenges.md` (the 🟠 per-song re-resolution
  item → addressed in code, runtime-pending), `PLAN.md` index still accurate.
  **Not committed** (CLAUDE.md).
- **Signed-gate outcome → see the "Phase 4 UI CORRECTIVE" entry at the top
  of this file.** The signed-build computer-use gate confirmed the Phase-4
  core works (CRUD/isolation, real-audio app-playlist playback, fixed play-
  tracking, native menu/dialog) but caught 4 UI defects (non-functional
  inline rename; phantom empty rounded-gray Table rows; stale "My Playlists"
  count; stale Plays/Last Played). All four root-caused and fixed there as
  view/reactivity-only changes (data layer/playback/schema untouched).

## 2026-05-15 — Phase 3 ✅ PASSED the signed runtime gate (D1 root-caused & fixed)

The 🔴 id round trip is **proven working on a signed build against the real
library**. After the corrective pass's song-level strategy still failed the
gate, a temporary diagnostic probe (roadmap-sanctioned; since **removed**)
found the true root cause and the fix was applied + re-verified live.

**D1 root cause (definitive, from the probe):** a stored `music_item_id` is
the playlist **Track** id, which is *not* the library `Song` id.
`MusicLibraryRequest<Song>.filter(matching:\.id,memberOf:storedIDs)` *does*
return the right songs (10 queried → 10 returned, e.g. "Jacqueline") but
keyed by the songs' own `i.`-prefixed ids — so song-level reassembly by the
stored id matched **0**. Probe Strategy C proved re-resolving the *playlist*
by its stored library id → `.with([.tracks])` returns the live tracks with
ids+order aligned **1:1** with the stored snapshot (overlap 19/19, all
`.song`). That is exactly Phase 1's proven playback path.

**Fix:** `PlaybackResolver.resolvePlaylist(libraryPlaylistID:rows:startAt:)`
re-resolves the Apple playlist by its stored library `MusicItemID`, pages
its live tracks (the proven import loop, same cap), extracts `.song`s in
order, starts at the row matched by live-track id, and plays via the
unchanged `PlaybackService`. `MusicController.resolveAndPlay` calls it with
`detail.id`. The song-level namespace/reassemble helpers + their unit tests
are **kept, documented as the dormant Phase-4 app-playlist/catalog path**
(resolving an *arbitrary* stored song id 1:1 is a real open problem — see
risk register).

**Verified live (signed build, real library):** import 8229 songs / 269
playlists / 25148 memberships one-way (app-owned tables untouched);
sidebar/detail render from SQLite; **"90s Alt" (137 tracks) played — "Give
It Away" audio, elapsed advanced 0:05→0:24/4:43, AirPods routed by the OS,
menu-bar now-playing lit**; real cover art everywhere (D2 fixed); recents
survived the one-shot UserDefaults→SQLite migration (Backpacking, then 90s
Alt). `make check` green; `swift test` **35/9** green; nothing committed.

**Non-blocking follow-ups (not Phase-3 exit criteria):**
- *Phase 4:* `play_event`/`song_stat` did not record — the
  `if playback.snapshot.isPlaying` guard in `resolveAndPlay` reads the
  0.5s-polled snapshot too early. Play-tracking is Phase-4 scope; wire it to
  the actual player-start signal there.
- *Phase 5:* playback started **paused** (showed ▶ at 0:05 until the
  transport was pressed) — auto-start-on-Play reliability + now-playing
  snapshot immediacy is a Phase-5 polish item.
- *Phase 4:* per-song re-resolution for app-playlists (arbitrary songs not
  backed by an Apple playlist) is unsolved — the Track-id≠Song-id finding
  means a different id (or reference) must be captured at add-time.
- *Perf:* D3 batch idioms are correct + tested, but first-import wall-clock
  (~88s) is dominated by MusicKit per-playlist `.with([.tracks])` paging
  across 269 playlists, **not** SQLite (identical plateau before/after the
  SQLite fix). This is the documented 🟡 large-library tradeoff; an
  incremental/parallel import is a Phase-5 perf item.
  > **RESOLVED in the Phase-5 CORRECTIVE (top entry):** this MusicKit-bound
  > diagnosis was *correct*. Parallel import was tried and measured
  > ineffective (the cost is CPU-bound + serialized inside MusicKit, not
  > concurrency-limited) and reverted; incremental import stays deferred
  > (unreliable `lastModifiedDate` on the macOS library → stale-snapshot
  > risk). Honest accepted v1 cost: ~90–120 s for ~270 playlists / ~8200
  > tracks, one-time / Refresh-only, surfaced by the progress affordance.

## 2026-05-15 — Phase 3 CORRECTIVE pass — code-complete, runtime-unverified, not committed

Addressed all three defects the signed-build gate caught (entry below). `make
check` green; `swift test` → **35 tests / 9 suites passed** (31→35: +5 new
`BatchImportTests`, the 3 dead string-heuristic namespace tests replaced by 2
provenance/round-trip tests). Signed `make` build produced:
`build/DJRoomba.app`, codesigned `Apple Development: Thomas Ptacek
(7F2QE7P59D)`, team `KK7E9G89GW`, valid on disk, satisfies its Designated
Requirement. **Not committed.** The agent CANNOT run the app — id round
trip + audio + artwork visuals remain for the orchestrator's signed runtime
re-gate; nothing about playback is claimed verified here.

- **D1 (showstopper) — id round trip, fixed in code.** `ImportService.song
  (from:)` now unwraps the `Track` enum (`.song(let s)` → `s.id.rawValue`,
  `.musicVideo(let v)` → `v.id.rawValue`, `@unknown default` falls back to
  `track.id` so a row is never dropped) and stores the **underlying item's**
  id, with `idNamespace` fixed to `.library` by **provenance** (library
  playlists). The string-sniffing `namespace(forRawID:)` / `namespace(of:)`
  is **deleted entirely** (it had degenerated to integer sign on real data —
  the exact gate failure). `PlaybackResolver` keeps `MusicLibraryRequest<
  MusicKit.Song>().filter(matching: \.id, memberOf:)` as the live path (the
  dev-signed path Phase 1 proved; no catalog entitlement) and the
  `MusicCatalogResourceRequest` branch is explicitly commented **dormant**
  (nothing catalog-namespace is imported). New **inline, non-modal** error
  surface: `MusicController.playbackProblem` (resolver error → unresolved-
  count → player error) rendered in the playlist header as a `.caption`
  `Label` with an `.orange exclamationmark.triangle.fill` glyph + `.secondary`
  text (typography-designer tier; macos-design unobtrusive idiom), value-
  animated. No temp debug affordance was added (none needed; none to remove).
  MusicKit API verified against the macOS 26.4 SDK `.swiftinterface`: `Track`
  is `enum { case song(Song); case musicVideo(MusicVideo) }`; `Song` has
  `let id: MusicItemID` + `var artwork: Artwork?`; `MusicItemID` conforms to
  `MusicLibraryRequestFilterValueMembershipComparable`; `Song`/`Playlist`/
  `MusicVideo` all conform to `MusicLibraryRequestable`.
- **D2 (artwork regression) — fixed in code.** Chose the `ArtworkImage`
  strategy (swiftui-pro + macos-design; it is exactly what Phase 1 used to
  show real art, and `plans/musickit-notes.md` already recommends it). The
  unfetchable private-scheme `artwork_url` is no longer stored (`Song`/
  `ApplePlaylist` keep the column for DB stability but write `nil` — **no
  schema migration needed**, so the v1-frozen rule is honored and no v2 was
  required). New `ArtworkProvider` (`actor`: cached, in-flight-deduped,
  negative-cached, no GCD) lazily re-resolves a live `MusicKit.Artwork` by
  stored `MusicItemID` via `MusicLibraryRequest<Song>` / `<Playlist>` (the
  Apple playlist's own id is a library id). `ArtworkThumbnail` rewritten to
  render `ArtworkImage(artwork, width:height:)` (Phase-1-identical) from a
  new `ArtworkRef` (`.song(id,namespace:)` / `.playlist(id)`); same fixed
  frame / corner radius / `.quaternary`+SF-Symbol placeholder / 0.2s value-
  driven cross-fade / no layout shift. `ArtworkImageLoader` deleted. Models
  (`PlaylistSummary`/`PlaylistDetail`/`TrackRow`/`PlayerStateSnapshot`)
  expose a computed `artworkRef`; all call sites repointed.
- **D3 (perf — user-flagged) — fixed in code.** `LibraryStore.upsertSongs`
  is now ONE transaction of chunked multi-row `INSERT … VALUES (…),(…)
  ON CONFLICT(music_item_id, id_namespace) DO UPDATE SET …=excluded.…`
  that deliberately **does not touch `id`** (stable PK / FKs preserved —
  non-destructive re-import, proven by new tests). New
  `LibraryStore.songIDsByKey(_:)` does the id resolution in ONE chunked
  `WHERE (music_item_id, id_namespace) IN (VALUES …)` query, replacing
  `ImportService`'s per-song N-await re-read loop. `replaceApplePlaylist
  Snapshot` membership insert is now chunked multi-row. All chunked under
  SQLite's 999-variable cap via a new `Array.chunked(into:)`. `SongKey`
  moved onto `LibraryStore`. Behavior identical: existing 31 tests stay
  green; new `BatchImportTests` prove UPSERT preserves `song.id` + FK on
  re-import, the batched lookup is correct across a chunk boundary (1200
  rows), and large-playlist membership stays ordered.
- swiftui-pro consulted **before** (drove: provenance over string-sniffing;
  `actor` provider with negative cache over per-view fetch; GRDB batch SQL
  in one `write`; `ArtworkImage` over a hand-rolled loader) and **after**
  (applied: added the missing value-driven `.animation` for the new inline
  surface; verified `.task(id:)` over `onAppear`, structured concurrency
  only, no GCD, one-type-per-file). macos-design drove the `ArtworkImage`
  choice + the unobtrusive inline-warning treatment. typography-designer set
  the new label's type (`.caption`, regular, `.orange` glyph + `.secondary`
  text — same tier as the subscription notice).
- Docs updated: this entry, `plans/data-and-import.md` (corrected id model +
  artwork + batch-write design), `plans/risks-and-challenges.md` (🔴 round
  trip → diagnosed+corrected, runtime re-verification pending), `PLAN.md`
  index still accurate. **Not committed** (CLAUDE.md).

## 2026-05-15 — Phase 3 RUNTIME VERIFICATION: 🔴 FAILED the gate (corrective DONE in the entry above — see it for the fix; runtime re-gate pending the orchestrator)

Signed-build computer-use verification of Phase 3 (the mandated end-of-stage
gate) **failed the core exit criterion**: the id store→re-resolve→play round
trip does not work. This is the 🔴 architectural risk firing — exactly what
the gate exists to catch. `make check` / `swift test` were green and the
SQLite-backed UI + UserDefaults→SQLite migration verified live (recents
survived: Backpacking), but **playback is broken** and there are two more
defects. Phase 3 is NOT handed off; a corrective pass is underway.

Live-observed on a real signed build against the user's library (270
playlists / 8229 songs / 25162 memberships imported):

- **D1 🔴 (showstopper) — id round-trip broken.** Every stored
  `music_item_id` is an opaque 16–20-digit macOS library `MusicItemID`
  (the persistentID-derived value); **none** are real Apple ids (0 are
  `i.`-prefixed; none are catalog store ids). `ImportService` stores the
  playlist `Track`'s id and the namespace classifier (`i.`→library /
  bare-numeric→catalog / else library) degenerates to *integer sign*:
  negative→"library" (4089), positive→"catalog" (4140). `PlaybackResolver`
  then sends non-catalog ids to `MusicCatalogResourceRequest` (resolves
  nothing) and Track-not-Song ids to the library request → nothing
  resolves → "Not Playing". Phase 1 only ever proved playback from *live*
  `Track` objects; the id-only path was explicitly carried as unproven —
  it is now disproven and must be redesigned. Fix direction: import must
  extract the underlying `Song` from each `Track` and store the Song's
  *library* id with namespace by **provenance** (library-playlist →
  library), dropping the string heuristic; resolver re-resolves those via
  `MusicLibraryRequest<Song>` (the dev-signed path Phase 1 proved; no
  catalog entitlement). Also: resolver/playback `lastError` has no UI
  surface — the failure was silent.
- **D2 (UI regression) — artwork all placeholders.** Stored `artwork_url`
  is `musicKit://artwork/transient/600x600?id=…`, a private scheme
  `URLSession` cannot fetch (macOS library `Artwork.url(...)` does not
  yield an https URL). Phase 1 showed real cover art; Phase 3 shows the
  placeholder everywhere. Must restore real artwork.
- **D3 (perf — user-flagged) — row-by-row import.** Full first import
  pegged a CPU core for ~90s: `upsertSongs` does N `SELECT`+`update`/
  `insert`, `ImportService` does an N-await per-song id re-read loop per
  playlist. User feedback: "there are sqlite idioms for batch inserts/
  updates." Apply UPSERT (`ON CONFLICT(music_item_id,id_namespace) DO
  UPDATE` preserving the stable `song.id` PK) + single IN-list id lookup +
  chunked multi-row membership INSERT. See memory `djroomba-sqlite-batch-idioms`.

Verified-good in Phase 3 despite the above: `make check`/`swift test`
(31/8), SQLite-backed sidebar/detail render, lazy detail from SQLite,
empty/loading states, the one-shot UserDefaults→SQLite favorites/recents
migration (Backpacking recent survived; selection restored). Artwork
*placeholder* rendering itself (frame/no-shift/transition) is correct —
only the source URL is wrong.

## 2026-05-15 — Phase 3 (IMPORT PIPELINE & UI ON SQLITE) — code-complete, not committed

The app now operates **from SQLite**; Apple Music is a one-way import source
+ playback engine only. No user-visible behavior regresses; the data path
underneath changed. `make check` green; `swift test` → **31 tests / 8
suites passed** (20 Phase 2 carried + 11 new). **Not committed.**

- **`ImportService`** (`DJRoomba/Music/`, `@MainActor @Observable`) — paged
  `MusicLibraryRequest<Playlist>` + per-playlist `playlist.with([.tracks])`
  paging (the proven M1 loops, caps `maxPlaylistBatches`/`maxTrackBatches`),
  maps `Track`→`Song` / `Playlist`→`ApplePlaylist`, dedupes per import key,
  writes via `LibraryStore.upsertSongs` + `replaceApplePlaylistSnapshot`
  (transactional). Strictly one-way: only touches `song`/`apple_playlist*`
  (the store guarantees app_playlist*/song_stat/play_event/favorites/recents
  are never touched — Phase 2 test still green). Wired to Refresh (⌘R /
  toolbar) and run on first authorized launch when `songCount() == 0`.
  Namespace capture (`library` vs `catalog`) is a pure, unit-tested
  classifier (`i.`-prefixed → library; bare-numeric → catalog; else
  library) — this is what the resolver keys re-fetch on.
- **Models de-MusicKit-ed** — `PlaylistSummary`/`PlaylistDetail`/`TrackRow`/
  `PlayerStateSnapshot`/`MusicContext`/`MusicCommand` no longer carry live
  `Playlist`/`Track`/`Artwork`/`MusicItemID`; they carry stored ids
  (String) + display fields + `artwork_url`. New `LibraryReadService`
  (sidebar from SQLite) replaces `PlaylistLibraryService` (deleted);
  `PlaylistDetailService` rewritten to read `songs(inApplePlaylist:)`.
  `MusicController` `await`s the store and republishes observable state;
  sidebar "Loading playlists…" now also covers the import window
  (`isLibraryBusy`) so first launch never flashes "No Playlists" — same UI,
  honest state.
- **Artwork from URL** — `ArtworkImageLoader` (an `actor`: `NSCache` +
  in-flight de-dup, `URLSession` async, no GCD/locks) + rewritten
  `ArtworkThumbnail` rendering the stored URL. Pixel-equivalent to the
  Phase-1 MusicKit look (macos-design reviewed): identical fixed frame /
  corner radius / `.quaternary`+SF-Symbol placeholder, no layout shift
  (frame fixed before load), gentle 0.2s value-driven cross-fade (no
  "pop"). All three call sites repointed (sidebar 28/r4, now-playing
  40/r6, header 104/r8).
- **One-shot UserDefaults → SQLite migration** — `LegacyPreferencesMigration`
  reads the M2 `favoritePlaylistIDs`/`recentlyPlayedPlaylistIDs` keys once,
  writes them into `favorite_playlist`/`recent_playlist` (recents stamped
  oldest→newest so `ORDER BY played_at DESC` reproduces the legacy
  most-recent-first order), sets a sentinel, then **never reads the old
  keys again** (no dual write). `FavoritesStore`/`RecentlyPlayedStore`
  deleted; the controller's favorites/recents now go through `LibraryStore`
  (optimistic local update + async persist). `UserPreferencesStore` (last
  selection) stays in UserDefaults by design.
- **`PlaybackResolver`** (`DJRoomba/Music/`, `@MainActor @Observable`) —
  groups a queue's stored rows by namespace (pure, de-duped), batch
  re-fetches library ids via `MusicLibraryRequest<Song>.filter(matching:
  \.id, memberOf:)` and catalog ids via `MusicCatalogResourceRequest<Song>
  (matching:\.id, memberOf:)`, reassembles in original order **tolerating
  unresolvable tracks** (reported via `unresolvedMusicItemIDs`, queue not
  broken — risk register), then plays via the **unchanged** M1
  `PlaybackService` (now takes resolved `MusicKit.Song`s). `recordPlay`
  fires on play start for the track that actually started (song_stat
  rollup is the Phase 2 machinery).
- **Tests added** (no faked MusicKit): `ImportNamespaceTests` (pure
  classifier), `PlaybackResolverTests` (grouping split/dedupe, both-namespace
  non-conflation, reassembly reports every unresolved id + empty queue
  doesn't crash), `LegacyMigrationTests` (pure plan ordering + end-to-end
  one-shot: migrates, idempotent, legacy keys never re-read, empty state
  still completes).
- `swiftui-pro` consulted **before** (drove: plain `Sendable` structs for
  the de-MusicKit'd model layer; `@MainActor @Observable` import/resolve
  services awaiting the off-main `Sendable` store; `actor`+`NSCache`
  loader over `AsyncImage`; pure logic factored as `nonisolated static`
  for testability) **and after** (applied: replaced a `try!` with
  `fatalError(desc)`; removed a redundant dedupe reduce + dead
  `mergeFavoritesIntoSummaries` hook; verified value-driven `.animation`,
  `task(id:)` over `onAppear`, ZStack+opacity over `_ConditionalContent`).
  `macos-design` consulted for the artwork loading/placeholder/fade.
  `typography-designer` **not triggered** — no type/label/scale changes
  (same strings, same fonts; artwork view has no text).
- **🔴 id round-trip status:** the store-id → discard → re-resolve →
  play path is now **code-complete** end-to-end (resolver + repointed
  player + recordPlay) but **runtime-unverified**: only a signed run on
  the user's Mac can finally confirm catalog/library re-resolution and
  audio. The orchestrator will do that signed run. Pure logic is tested;
  the MusicKit-session parts honestly are not (can't be, without a live
  account/subscription).
- Docs updated: `plans/data-and-import.md` (as-built ImportService +
  PlaybackResolver + namespace rule + legacy migration), `plans/
  architecture.md` (Phase 3 layering realized), `plans/
  risks-and-challenges.md` (🔴 round-trip → code-complete /
  runtime-pending), `PROGRESS.md` (this), `PLAN.md` index still accurate.
  **Not committed** (CLAUDE.md).

## 2026-05-15 — Phase 2 (LOCAL STORE FOUNDATION) — DONE, not committed

GRDB SQLite layer landed, **purely additive — no UI, no import wiring, app
behavior unchanged.** `make check` and `swift test` both green.

- **GRDB** added to `Package.swift` (`from: "7.0.0"`, resolved 7.10.0) as a
  dep of the `DJRoomba` target. New `.testTarget DJRoombaTests`. Verified
  `@testable import DJRoomba` of the `@main` executable target links + runs
  on Swift 6.3 SwiftPM, so **no `@main` restructuring needed**.
- **Schema** = one frozen migration `v1.initialSchema` covering all nine
  tables (song, apple_playlist[+track], app_playlist[+track], play_event,
  song_stat, favorite_playlist, recent_playlist). FKs enforced;
  `UNIQUE(music_item_id, id_namespace)` on song; ownership cascades;
  **song delete RESTRICTed** so play history is never silently destroyed;
  indices for the FK/sort/lookup paths. `eraseDatabaseOnSchemaChange =
  false`. Never-edit-shipped-migrations rule documented in a comment block
  at the migrator and in `plans/data-and-import.md`.
- **`LibraryStore`** (`DJRoomba/Persistence/`) — `Sendable`, NOT
  `@MainActor`; async read/write over a GRDB `DatabaseQueue` off the main
  actor. Coarse intent-named API (upsert songs / replace snapshot / record
  play / favorites / recents) so future columns are localized changes.
  `AppDatabase` opens `Application Support/DJRoomba/library.sqlite`
  (`URL.applicationSupportDirectory`, subdir created if missing) + an
  in-memory init for tests. Records: one Codable record per file in
  `Persistence/Records/`.
- **Tests**: 20 tests / 5 suites, all pass. Cover: fresh DB applies all
  migrations; migrator idempotent on re-run; song upsert dedupes on
  `(music_item_id, id_namespace)` and preserves the stable id (FKs intact);
  snapshot replace is transactional, ordered, atomic-on-failure, and does
  NOT touch app_playlist/song_stat/play_event; favorites + recents
  round-trip (idempotent, source preserved, capped, no dup on replay);
  `recordPlay` maintains song_stat (count + last_played_at, only-advances,
  FK-rejected for a missing song with rollback). `swift test` →
  `Test run with 20 tests in 5 suites passed`.
- `swiftui-pro` consulted **before** (drove: Sendable value type not
  `@MainActor`, async/await only, modern Foundation `applicationSupportDirectory`,
  `Date.now`, one-type-per-file) **and after** (clean — no defects; noted
  the per-song upsert fetch is acceptable for v1 volumes, Phase 5 perf
  item). Carried-forward Phase 1 unknown (id-only re-resolve, esp. catalog)
  is untouched here — it's a Phase 3 PlaybackResolver concern.
- Docs updated: `plans/data-and-import.md` (sketch → as-built schema +
  FK-policy + migration-extensibility rules + as-built concurrency),
  `PROGRESS.md` (this), `PLAN.md` index still accurate. **Not committed**
  (CLAUDE.md: commit only when asked).

## 2026-05-15 — Build system migrated to the mdv environment

Replaced XcodeGen/`xcodebuild` with the **tqbf/mdv build environment**
(SwiftPM + `build.sh` + `Makefile`; no Xcode IDE, no `xcodebuild`, no
XcodeGen). Xcode is now only a toolchain provider, reached only by
`make dist`. Full rationale + targets + signing in
[plans/build-system.md](plans/build-system.md).

- Added `Package.swift` (executableTarget over `DJRoomba/`, macOS 14, Swift
  6 language mode), `build.sh`, `Makefile`. Deleted `project.yml` and
  `DJRoomba.xcodeproj/`. De-templated `Info.plist` to literal values
  (`$(…)` were Xcode-only substitutions; literal `$(…)` as
  `CFBundleIdentifier` would break MusicKit's App ID match).
- Verified: `swift build` compiles the whole Swift 6 strict-concurrency
  tree clean; `make` produces `build/DJRoomba.app` signed with the
  Phase-1 identity `Apple Development: Thomas Ptacek (7F2QE7P59D)`,
  bundle id `org.sockpuppet.djroomba`, designated requirement satisfied;
  `make check` / `clean` / `check-version` guard all work.
- One deliberate deviation from mdv: mdv adhoc-signs; DJ Roomba signs dev
  builds with the Apple Development cert (adhoc → empty MusicKit library,
  Phase 1 fact). `make dist` = Developer ID + hardened runtime + notarize
  + staple (the standard mdv pipeline).
- The "notarized Developer ID build may need an embedded MusicKit
  provisioning profile for catalog APIs" question is **not solved** — it
  is pre-wired as the optional `PROVISION_PROFILE` hook and remains the
  Phase 2/3 risk-register item.
- NOT verified by this change: runtime MusicKit behaviour (unchanged from
  Phase 1) and `make dist` end-to-end (needs a `vX.Y.Z` tag + stored
  `djroomba-notary` keychain profile — neither done yet).
- Not committed (CLAUDE.md / process note: commit only when asked).

## Current status: ✅ PHASE 1 PASSED (2026-05-15) — core viability proven

Ran a properly **Apple Development-signed** build (team KK7E9G89GW, App ID
`org.sockpuppet.djroomba`) and observed the full chain working live:

- ✅ Authorization (granted, no re-prompt).
- ✅ **Real library playlists** load with artwork — large set ('80s Hits
  Essentials, 2-Tone, 4AD Records: The '80s, 70's Protest Music, 91X
  Top 91 of 1992/93/94, …).
- ✅ **Tracks load** for a selected playlist with full metadata
  ("Backpacking", 52 tracks: ATCQ, De La Soul, The Pharcyde, The Roots…).
- ✅ **In-app playback works** — pressed Play, "Go Ahead In The Rain — A
  Tribe Called Quest" streamed in-process (elapsed ticked 0:09 → 0:41),
  pause works, macOS now-playing indicator lit.
- ✅ **M2 features verified live**: "Recently Played → Backpacking" section
  appeared after playing; sidebar/detail/now-playing/filter UI all correct.

Setup checklist (final):
- [x] Step 1 — Apple Music + Sync Library on this Mac (user, confirmed).
- [x] Step 2 — Apple ID in Xcode → Accounts (user). Verified: Xcode created
  the **"Apple Development: Thomas Ptacek (7F2QE7P59D)"** cert + provisioning;
  `-allowProvisioningUpdates` signed build SUCCEEDED.
- [x] Step 3 — **NOT required for library read/playback on macOS.** A real
  Apple Development signature + `NSAppleMusicUsageDescription` + system
  account + synced library was sufficient. (Enabling the MusicKit App
  Service for the App ID may still matter for Apple Music *catalog* API
  / re-resolving catalog-namespace ids / distribution — treat as open,
  validate when PlaybackResolver hits catalog ids in Phase 2/3.)

`project.yml` already had `CODE_SIGN_STYLE: Automatic` + team KK7E9G89GW
since M1 — no "signing flip" was needed; ad-hoc was only ever a CLI override.

Earlier "empty library" fully explained: ad-hoc unsigned build **and**
unsynced library. Both fixed. The 🔴 access/signing/library risks are retired.

**Still to validate (carried to Phase 2 — lower risk now):** the explicit
*store id → discard object → re-resolve by id → play* round trip, especially
for catalog-namespace ids. Playback from a live playlist's tracks is proven;
the id-only resolution path is the remaining unknown for the SQLite design.

The project pivoted to **local-first** (SQLite-owned library, native MusicKit
as import + playback only). All planning docs are written and consolidated.
No Phase-1+ code started yet — by design, Phase 1 is a validation gate.

## Decisions locked

- **Identity:** native MusicKit, system Apple Account ("Option A"). No in-app
  login. User has an ADC membership and has used MusicKit before.
- **Local store:** SQLite via **GRDB** (SPM dep in `Package.swift`).
- **Data ownership:** app owns playlists, play counts, favorites, recents,
  metadata in SQLite. One-way import from Apple. **No write-back to Apple.**
- **Playback:** native `ApplicationMusicPlayer`, in-process; stored
  `MusicItemID`s re-resolved at play time. Requires active subscription.
- **Tooling/identity:** mdv-cloned build env (SwiftPM + `build.sh` +
  `Makefile`; no Xcode IDE/xcodebuild/XcodeGen — see
  [plans/build-system.md](plans/build-system.md)); macOS 14 min (Swift
  6.3); app "DJ Roomba" / `org.sockpuppet.djroomba` / team `KK7E9G89GW`.

## Done to date

**Scaffold & M1 ("Play a library playlist") — code complete.**
XcodeGen project, Info.plist (`NSAppleMusicUsageDescription`), sandbox+network
entitlements, `.gitignore`. Full model/service/view layer: authorization,
subscription, paginated library load, lazy+cached detail, thin
`ApplicationMusicPlayer` wrapper, `MusicController` coordinator,
`MusicContext`/`MusicCommand` boundary scaffold; SwiftUI shell
(NavigationSplitView + native Table + persistent now-playing bar +
transport), reusable `ArtworkThumbnail`. Build verified clean (Swift 6 strict
concurrency). `swiftui-pro` pre/post review applied. **Committed to `main`
as `ff3294f`.**

**M2 ("Make it pleasant") — code complete, build-verified, NOT committed.**
`FavoritesStore`/`RecentlyPlayedStore` (UserDefaults; observable mirrors on
the controller), sidebar refactored into router + list + section + row,
Favorites / Recently Played / Library sections, favorite toggle + star,
`.searchable` playlist & track filtering (⌘F), Return-to-play on sidebar,
⌘L/⌘1 focus, `@SceneStorage` sidebar collapse. Build clean; `swiftui-pro`
pass applied. Held uncommitted intentionally before the pivot (can commit as
a checkpoint on request).

**Runtime evaluation (ad-hoc signed build, computer-use).**
- ✅ Auth flow verified end to end (AuthorizationView → Allow → system prompt
  → approved → authorized shell). M1 auth step is runtime-verified.
- ✅ Native layout, empty states, now-playing bar, window chrome, type
  hierarchy, Playback menu (Space/⌘→/⌘←/⌘R), View menu (⌘1/⌘L) — all good.
- ⚠️ `MusicLibraryRequest<Playlist>` returned **empty, no error** — the Mac
  had never synced the account's library + ad-hoc build lacks the MusicKit
  entitlement. Not a code bug. This is what Phase 1 must resolve/validate.

**Architecture pivot + planning (this stretch).**
Decisions resolved with the user; docs rewritten: `PLAN.md` (decisions +
recast milestones), `plans/architecture.md` (Local-first pivot section),
`plans/data-and-import.md` (GRDB rationale, schema, import, resolver),
`plans/roadmap.md` (end-to-end 5-phase plan, Phase 1 = access-validation
gate), `plans/risks-and-challenges.md` (live risk register). Memory updated:
`djroomba-local-first-pivot`, `djroomba-musickit-identity-reality`,
`user-prefers-prose-questions`.

## Verified vs NOT verified (be honest)

- Verified: builds (signing-disabled) clean through M1+M2; auth flow live;
  UI/states/menus/shortcuts live.
- NOT verified: real library read, playlist→track loading, actual audio
  playback, id round-trip, favorites/recents persistence at runtime — all
  gated on the Phase 1 signed build.

## Next

Execute **`plans/roadmap.md` Phase 1 (ACCESS VALIDATION)** — the hard gate.
Then Phases 2–5 (local store → import/UI-on-SQLite → app playlists+play
counts → polish/extension/hardening). M3 tasks (#11–16) map to Phases 2–3.

## Open user actions (remaining)

1. ✅ ~~Apple Music + Sync Library on this Mac~~ — done 2026-05-15.
2. ✅ ~~Apple ID / dev cert~~ — `Apple Development: Thomas Ptacek
   (7F2QE7P59D)` present and used by `build.sh`; no Xcode-Accounts /
   automatic-provisioning step anymore (we sign directly).
3. **For `make dist` only:** `make notary-setup` once (interactive;
   stores the `djroomba-notary` keychain profile).
4. **Open Phase 2/3 question:** whether a notarized Developer ID build
   needs the MusicKit App Service / an embedded provisioning profile for
   *catalog* APIs. Pre-wired as `PROVISION_PROFILE`; validate when
   PlaybackResolver first hits catalog ids.

## Process notes

- Committed to `main`: `ff3294f` (M1), `4f0a7f9` (M2 + local-first pivot
  planning docs), `112e1b3` (Phase 1). The build-system migration is
  **uncommitted** (working tree has the SwiftPM/Makefile changes).
- Build (agent / CI, no signing): `make check` (== `swift build`).
  Full signed dev build: `make`. See
  [plans/build-system.md](plans/build-system.md) for all targets.
- Will not commit/push without being asked; **never merge to `main`**
  (CLAUDE.md).
