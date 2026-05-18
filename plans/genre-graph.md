# Genre graph — the "Analyze" action

Build a graph of **genres** by relating tracks of different genres that
**share a playlist**. Output is a single SQLite adjacency-list edge table,
rebuilt wholesale by one CTE-driven statement. Pure SQLite — no MusicKit, no
import, works offline.

> Resume pointer: this is the durable design. The store SQL is the source of
> truth (`LibraryStore.rebuildGenreGraph`); this file explains the *why*.

## What the graph means

- **Node** = a genre string, verbatim from `song.genre_names` (the user's
  own Apple tags, including hierarchical ones like `"Alt/Punk/Pixies-
  Related"`). No case-folding, no hierarchy splitting — out of scope; the
  node is the tag as stored. Only whitespace is trimmed and empties dropped.
- **Edge** = two genres are related iff a track of one and a track of the
  other appear in the **same playlist** (Apple imported snapshot *or*
  user-owned app playlist). A single song carrying multiple genres relates
  *its own* genres to each other (it is in a playlist).
- **Weight** = the number of **distinct** playlists the pair co-occurs in.
  A song listed twice in one playlist does not inflate it; an Apple and an
  app playlist are two distinct playlists.

The graph is **undirected**. It is stored as a real **adjacency list**:
both directed half-edges (`a→b` and `b→a`) are materialized with the same
weight, so "the genres related to X" is a single PK-indexed
`WHERE genre_a = ?` lookup either way. That is the deliberate trade — a
little redundancy for trivial, mess-free read SQL (graph SQL is otherwise a
mess; that was the explicit ask).

## Schema (`v6.genreGraph`)

```
genre_edge(
  genre_a TEXT NOT NULL,
  genre_b TEXT NOT NULL,
  weight  INTEGER NOT NULL,
  PRIMARY KEY (genre_a, genre_b))
```

- **No FK.** A genre is denormalized free text inside the
  `song.genre_names` JSON array, not an entity row — exactly the no-FK
  rationale `favorite_playlist` / `recent_playlist` already use. The table
  is wholly derived; a rebuild re-creates it from the live data.
- **No extra index.** The composite PK `(genre_a, genre_b)` *is* the
  adjacency index — its leftmost prefix covers the `genre_a` neighbour
  lookup. Whether to index `weight` for ranking is a separate future
  decision, not implied by adding the table (a node's neighbour set is
  small enough to sort in memory).
- **No `v5.*` migration.** The documented "v5" (album→track genre import,
  2026-05-17) was data-only — it reused the v4 `genre_names` column and
  added no schema. The migration label is just an ordered string; the next
  schema change is `v6`, which keeps the migration id aligned with the
  doc's schema-version story (v4 = the columns, v5 = the genre data,
  v6 = the graph). Purely additive — v1–v4 stay frozen; an existing DB
  migrates non-destructively (the table is empty until the first analyze).

## The rebuild (`LibraryStore.rebuildGenreGraph(maxPlaylistTracks:maxPairsPerPlaylist:)`)

ONE `DELETE` + ONE CTE-driven `INSERT … SELECT … UNION ALL`, in a single
write transaction. **Wholesale** — never row-by-row, never an incremental
edit — so the table is internally consistent by construction, including the
two mirrored directions of every edge. Idempotent for fixed inputs +
thresholds. Returns the rebuilt edge-row count (both directions).

**Density is shaped here, at the source** (the principled place — it shapes
the persisted graph and every consumer, and is user-tunable, not a
display-only band-aid). Two thresholds, why a co-occurrence graph is
otherwise near-complete: a playlist *clique-connects* all its genres, so
the edge count is quadratic in playlist breadth and a few sprawling lists
blanket the whole pair space.

| CTE | Role |
|-----|------|
| `membership` | every `(playlist, song)` across BOTH libraries, under a `'apple:'`/`'app:'`-prefixed composite playlist key so the two sources can never collide. `UNION ALL`. |
| `eligible` | **threshold (a):** playlists whose `COUNT(*)` membership `<= maxPlaylistTracks`. Everything downstream joins through this, so an oversized list ("every track WLIR played for 8 years") never enters the graph at all. |
| `playlist_genre` | explode `genre_names` with `json_each` (`IS NOT NULL`+`json_valid`+`TRIM<>''` guards) and, per `(eligible playlist, genre)`, `COUNT(DISTINCT song_id)` = that genre's track count in the playlist (the strength input). |
| `pair` | self-join on `a.genre < b.genre` (drops self-pairs **and** the mirror), carrying `strength = min(track_ct_a, track_ct_b)` — high only when *both* genres are substantially present, so a stray track or one dominant genre can't fake a strong pair. |
| `ranked` / `kept` | **threshold (b):** `ROW_NUMBER() OVER (PARTITION BY playlist ORDER BY strength DESC, genre_a, genre_b)`; keep `rn <= maxPairsPerPlaylist`. Each playlist contributes only its strongest N pairs instead of `G·(G−1)/2`. |
| `edge` | `COUNT(DISTINCT playlist_key)` over the kept per-playlist pairs = the weight. |

The two `?` binds are, in textual order, `maxPlaylistTracks` then
`maxPairsPerPlaylist`. Final `SELECT … UNION ALL SELECT (swapped)`
materializes both half-edges from the canonical set; the two halves can
never collide on the PK (one is `a<b`, the other `a>b`); an empty/curated-
to-nothing library inserts nothing.

**Defaults** `maxPlaylistTracks = 500`, `maxPairsPerPlaylist = 30` (in
`UserPreferencesStore`, clamped ≥ 1, surfaced in the Advanced settings
pane). Measured on the real library: defaults take **5,719 → 731 edges /
88 genres** — the genuine strong-relationship graph, legible and fast.
Genres with no qualifying relationship under the thresholds are absent by
design (raise either knob in Advanced to widen the net).

**One-way isolated**: touches only `genre_edge`. `song`,
`apple_playlist*`, `app_playlist*`, `song_stat`, `play_history`, favorites,
recents are never read-for-write nor mutated — same posture as the import
paths, test-verified (`GenreGraphTests` "rebuild is one way isolated").

`json_each` / `json_valid` are SQLite JSON1, compiled into the system
SQLite GRDB links on the macOS-14 target — available unconditionally.

## Reads

- `relatedGenres(to:limit:)` — adjacency lookup, strongest first
  (`weight DESC`, then neighbour name), capped (a node can have a long weak
  tail). Backs a future "related genres" surface.
- `genreGraphEdges()` — the whole table (both directions), strongest first.
  For export / a future graph view / tests. Not a per-view hot path (the
  graph is one row per related pair, twice — small vs the song table).
- `GenreEdge` is a read-only `FetchableRecord`; nothing constructs/persists
  one (the rebuild is the only writer).

## The "Analyze" surfaces

- **Service:** `GenreGraphService` (`@MainActor @Observable`), the thin
  wrapper mirroring `GenreImportService`/`ImportService` — `analyze()`,
  `isAnalyzing` (re-entrancy guard), `lastError`, `edgeCount`. No MusicKit.
- **Menu (on-demand):** Playback ▸ **Analyze Genre Graph** (⌥⌘A). Placed
  beside **Reimport Everything** — the other wholesale "rebuild derived
  state from the library" action. ⌘A/⇧⌘A are reserved (Select All /
  Deselect); ⌥⌘A is free and mnemonic. Always runs, regardless of the
  toggle.
- **Auto-reanalyze (default ON):** Playback ▸ **Reanalyze Automatically**
  (a native checkmark `Toggle` menu item, bound via `Bindable` — the
  modern Observation binding, not `Binding(get:set:)`). Persisted in
  `UserPreferencesStore.autoReanalyzeGenreGraph` (UserDefaults; absence
  reads as `true`, so an existing install opts in with no migration). The
  observable mirror lives on `MusicController` (`@AppStorage` must not live
  in an `@Observable`); its `didSet` writes straight back to the store —
  exactly the `lastSelectedPlaylistID` pattern.
- **Advanced settings pane (⌘,):** a native `Settings` scene
  (`SettingsView` = a one-tab `TabView`, fixed 520×320 →
  `GenreAnalysisAdvancedPane`, a grouped `Form`). Two bounded `Stepper`s
  ("Largest playlist analyzed" / "Genre links per playlist") with a
  `.caption` explainer each and a footer noting changes apply on the next
  analysis. Bound by `@AppStorage` to the same `UserDefaults` keys
  `UserPreferencesStore` exposes (`genreAnalysisMaxPlaylistTracks` /
  `…MaxPairsPerPlaylist`; the store clamps ≥ 1) — `@AppStorage` is fine
  here because this is a plain view, NOT inside an `@Observable`; so the
  pane needs no `controller` wiring and the next analysis just picks the
  change up. SwiftUI auto-wires the ⌘, menu item for a `Settings` scene.

## The visualizer (detail-pane panel)

A collapsible, resizable force-directed visualizer docked at the **bottom of
the detail pane** — the native "debug-area" idiom (a secondary panel inside
the main content, not a window or a third split column). It is **library-
wide** and deliberately independent of the selected playlist: it stays put
while the user moves between playlists above it.

- **Dependency (vendored + patched):** `tqbf/fdg`'s `ForceGraph` library
  (one public `ForceGraphView`, no third-party deps, macOS 14).
  **Vendored** at `Vendor/ForceGraph` via `.package(path:)` — the exact
  v1.0.0 commit `0a8a43e` we previously consumed remotely, trimmed to the
  library target only (Lab/tests/corpus dropped). Vendored, not remote,
  because two field-reported bugs have **no public API hook** and live in
  `GraphEngine` — both marked `// DJROOMBA PATCH` for upstreaming to
  tqbf/fdg:
  1. **Search-pulse redraw pin (cursor flicker / tight loop).** Upstream
     pinned `wantsContinuousRedraw = true` for the *entire* time the
     search HUD is visible (to breathe the match pulse), so the opaque
     `Canvas` redrew the whole graph at display refresh even on a fully
     settled graph the whole time you typed/cycled — wasted CPU and a
     flickering mouse cursor (the OS resets it over a continuously-
     invalidating view). Patch: drop the pulse pin (`pulseWantsRedraw =
     false`) so a settled search idles like any other static graph —
     making the existing Reduce-Motion no-pulse path universal. Matches
     still light up/dim (snapshot-driven, not pulse-driven); the
     recenter-on-cycle animation still runs via the finite
     `keepLiveUntil` tail.
  2. **Pan-only search centring (tiny dots).** `onSearchCycle` /
     query-narrowing called `recenterViewport` → `viewport.center(on:)`,
     which only *translates* (preserves the current zoom), so cycling
     while zoomed out just panned between unreadable dots. Patch: a new
     `Viewport.focus(on:minScale:)` (centre **and** raise zoom to a
     readable floor, never zoom *out*) + a `recenterViewportForSearch`
     used by cycle/narrow. The layout-bloom follow and the selection pin
     keep the pan-only recenter (their zoom is intentionally preserved).
  3. **Neighbour-walk.** Genre selected + search inactive ⇒ arrow keys
     cycle its linked genres (strongest edge first), `Return` commits the
     previewed one as the new centre and the walk continues, no `Return`
     in 2 s snaps back. Engine state + a cancellable MainActor revert
     `Task`; `KeyCaptureView` dispatches ↑↓←→/Return/Esc unconditionally
     and the engine decides consumption (search-cycle / walk / pass
     through). `selection`'s didSet resets the walk.
  4. **`onFocusChange(genre, edgeOther)` callback** (new optional
     `ForceGraphView` param, defaulted) reporting what's focused —
     selected genre, previewed-neighbour edge, snap-back, commit,
     deselect — so the host can show context without reaching into the
     engine. Drives the associations card below.
  5. **Hub-cell crossing-detector blow-up (beachball).** `CrossingIndex`'s
     uniform grid claims "never O(E²)", but for a **high-degree hub** the
     layout centres on it so *all* its incident edges fall in one grid
     cell; that super-cell's `for x { for y in x+1… }` pair test is
     O(degree²) — the detector degenerates to O(E²) for a hub star. On the
     post-import genre graph (denser after the playlist-folder blitz
     correctly rebuilt it) selecting a hub (e.g. "Alt/Laptop") and
     dragging pegged the **main thread** for seconds on every settle's
     `refreshCrossings` (a profiler caught ~67% of the main thread in
     `CrossingIndex.recompute`, dominated by the pair loop's `Set<Int>`
     churn + cross-module Swift generic-metadata instantiation) → an
     app-wide beachball. Patch: skip the pair test for any cell past
     `maxCellMembers` (96) — such a cell is an illegible knot the
     `glyphBudget` thinning discards anyway and whose pairs mostly share
     the hub endpoint (not crossings), so only crossings *interior to a
     degenerate hub core* are omitted (HUD `count` a lower bound there —
     consistent with the spec's already-explicit representative-not-
     exhaustive glyph contract). Profiler-verified on the signed build:
     `CrossingIndex.recompute` **11 978 → 10** main-thread samples under
     the identical drag repro; app stays responsive (~99.9% main-thread
     idle). 155/25 tests green; normal non-hub graphs unaffected.
  Same major-pin posture as GRDB; the pin is now a fixed commit copy.
- **Associated-playlists card.** Selecting a genre shows a
  `.regularMaterial` corner card (top-trailing of the FDG view) of its
  playlists — source icon + name + strength, **sorted by strength desc,
  capped at 8**; during neighbour-walk it **narrows to the previewed
  edge** (playlists where both genres co-occur, strength = `min` pair
  co-strength), resets to the anchor on snap-back / the new genre on
  commit, clears on deselect — all driven by `onFocusChange` +
  `.task(id: focus)` (auto-cancels the prior load so rapid previews
  can't race a stale list). Backed by
  `LibraryStore.associatedPlaylists(genre:neighbor:limit:)` — two CTE
  shapes (single-genre / edge), derived live from `genre_names` +
  membership (association isn't persisted; no eligibility filter — the
  honest "every playlist this genre is in"). `PlaylistAssociation` DTO;
  `GenreGraphService.associatedPlaylists` wrapper (cap 8). Views:
  `GenreAssociationsCard` (own file).
- **`GenreGraphService` (extended):** beyond `analyze(maxPlaylistTracks:
  maxPairsPerPlaylist:)` it publishes the displayable graph —
  `displayNodes`, `displayEdges`, `isLoadingGraph`, `hasLoadedGraph`.
  `loadGraph()` (no rebuild) on the panel's `.task` shows a prior/auto
  graph immediately; `analyze(…)` refreshes it in the **same** call.
  `MusicController` reads the two thresholds from `UserPreferencesStore`
  and passes them through one `runGenreAnalysis()` funnel (both the ⌥⌘A
  action and the auto-reanalyze hook), so analysis always uses the live
  settings and the pref read lives in one place.
- **Density is shaped at analysis time, not here (the re-evaluation).**
  The earlier display-time "greedy strongest-neighbour backbone" was
  **removed**: now that `rebuildGenreGraph`'s thresholds curate the graph
  at its source (principled, persisted, user-tunable), re-pruning it in
  the view only obscured it. `buildDisplayGraph(from:maxEdges:)` is now a
  faithful projection — canonical `a<b` fold; weight `raw/maxRaw` over
  kept, floored `0.12` (single edge ⇒ `1`); and a single documented
  **perf backstop** `displayEdgeMax = 1200` (strongest-by-weight) so the
  view stays responsive if some library still yields a large curated
  graph. Post-curation it rarely binds — the real library analyzes to
  731 < 1,200, so the panel shows the true analyzed graph. `sparsify`
  and the per-node-degree knob are deleted.
- **Every analyzed genre stays a node.** Nodes are every genre in the
  canonical analyzed set (not just the genres still in a kept edge after
  the perf backstop), so a low-degree genre stays searchable/centerable
  (floats free of springs — honest "no strong ties"). Node count was
  never the cost; edges were. (A genre the analysis thresholds curated
  out entirely is legitimately absent — that is the user's chosen
  curation; widen it in Advanced.) `ForceGraph` explicitly supports
  partly-disconnected graphs.
- **View tree** (each its own file, swiftui-pro "extract subviews"):
  `DetailPaneView` (the detail column = `PlaylistDetailView` taking the
  space + `GenreGraphPanel` docked below) → `GenreGraphPanel` (owns
  collapse/height) → `GenreGraphResizeHandle` + `GenreGraphPanelHeader` +
  `GenreGraphContent` (loading / Analyze empty-state / `ForceGraphView`).
- **Collapsible + the reveal affordance:** a header chevron toggles
  `collapsed` (value-animated). Field feedback: once collapsed, a faint
  chevron in a slim bottom bar is *not* a discoverable way back. The
  discoverable control is a **`MainShellView` toolbar toggle** (the
  `point.3.connected.trianglepath.dotted` glyph, beside the inspector
  toggle — the same native idiom) bound to the **same**
  `@SceneStorage("genreGraphPanelCollapsed")` key, so the toolbar button
  and the header chevron stay in sync within the scene with no
  state-lifting. A collapsed panel is always re-openable from the
  toolbar.
- **Resizable:** a top-edge drag handle changes the body height (clamped
  180–680, VoiceOver-adjustable, macOS up/down resize cursor). `collapsed`
  + height are `@SceneStorage` (scene state lives in the view layer, never
  in an `@Observable`) so both survive relaunch. **Default expanded** at a
  modest 300 pt — the user asked for it in the main pane, so it's visible
  on first run without crowding the track list.
- **Type:** reuses the established semantic scale (no new scale) — a
  `.subheadline` semibold title + `.caption` secondary count, one tier
  below `PlaylistHeaderView` because this is a docked utility bar.
- The panel's Analyze button and the empty-state CTA both call the same
  `MusicController.analyzeGenreGraph()` as the ⌥⌘A menu item.

### When auto-reanalyze fires

`MusicController.reanalyzeGenreGraphIfEnabled()` — fire-and-forget on the
MainActor (it must not block the sidebar/detail refresh the caller just did;
`analyze()` republishes `displayNodes`/`displayEdges`, so the panel updates
reactively when it completes). The
`isAnalyzing` guard coalesces a burst of edits into one in-flight rebuild;
because the rebuild is wholesale, the next trigger after it finishes already
reflects everything that changed in between — nothing is missed.

Triggered after a change that can alter which genres share a playlist:

| Trigger | Why |
|---|---|
| import (`runImport`, after the genre pass) | new/changed Apple playlists + (full/first) refreshed `genre_names`; the "new playlists added" case |
| `addSongs` / `removeTracks` / `setAppPlaylistTracks` | app-playlist membership changed |
| `deleteAppPlaylist` | its membership dropped |

**Deliberately NOT** rename / sidebar-reorder / empty-playlist *create*:
none of those change any genre↔playlist relationship, so a rebuild there is
guaranteed wasted work (a freshly created playlist has no songs ⇒ no genres
⇒ no edges; the import path covers genuinely-new *populated* playlists).
`setAppPlaylistTracks` doubles as drag-reorder — a pure reorder is a cheap
graph no-op, not worth distinguishing.

## Tests

`GenreGraphTests` (12) pin the deterministic store half — symmetric
two-direction edges; distinct-playlist weighting incl. the duplicate-row
collapse and Apple+app both feeding it; multi-genre-song self-linking; the
no-shared-playlist→no-edge case; NULL/blank/invalid genre ignored without
aborting; adjacency ordering + `limit`; idempotence; one-way isolation;
**threshold (a) oversized-playlist exclusion**; **threshold (b)
per-playlist top-N by `min`-strength**. `MigrationTests` has the
`v6.genreGraph` ordering/idempotence assertions, the `genre_edge`
table+composite-PK check, and `genre_edge` in `expectedTables`.
`GenreGraphDisplayTests` (7) pin the pure `buildDisplayGraph` projection:
canonical-half dedupe, max+floor weight normalisation, single-edge⇒1,
empty input, the strongest-by-weight perf backstop, **every analyzed
genre stays a node when the backstop trims its edges**, and a small graph
passing through untouched under the default backstop. The
`GenreGraphService` async wrapper, the SwiftUI panel and the Settings
pane are not unit-tested (same precedent as the import services / the
view layer — correctness is the store SQL + the pure fold; the rest is an
`isAnalyzing`-guarded passthrough / layout / `@AppStorage`) and are
covered by the computer-use check instead, which confirmed: panel render,
Analyze end-to-end, the toolbar reveal toggle, "americana" → 1 match →
`Return` centres it, the ⌘, Advanced pane (both steppers / captions /
footer), **re-analyze with the default thresholds = 5,719 → 731
edges / 88 genres** (the curated graph, well under the 1,200 backstop),
and the **associated-playlists card** (select "Alt/Laptop" → 8 playlists,
strength-sorted, capped, pretty). Two new `GenreGraphTests` pin the
`associatedPlaylists` store read (single-genre by strength + limit; edge
narrowing requires *both* genres). Neighbour-walk's keyboard path is
user-confirmed + code-reviewed: the computer-use env can't reliably drive
standalone synthetic arrows (a recurring macOS Accessibility gate), so it
is not screenshot-verified.

143 tests / 23 suites green; `swift build` clean; `swiftformat` /
`swiftlint` 0.

## Deliberately out of scope

Genre hierarchy splitting; case/spelling normalization; community/cluster
detection; incremental (non-wholesale) edge maintenance; weighting by track
count rather than distinct playlists; making a graph-node click filter the
playlist list / drive selection (the `selection` binding is wired but
app-side behaviour on it is a later hook). The edge table + reads + the
`ForceGraphView` panel make any of these a later, localized addition.
