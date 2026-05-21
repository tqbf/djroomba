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

## Phase-3-gate deferred (2026-05-20)

The Phase-3 gate of `plans/genre-metro-map.md` (the "stop compacting"
reset) executed the blocker — delete the compaction pass, widen the
world, center-on-heaviest-community default, fix strand-label
typography. Two `toms-laws` proposals were declined for the gate and
deferred here.

### Phase-3-gate Phase B — Extract `GenreMapViewport` state struct

- **What:** `GenreMapPanel` holds `scale` / `offset` / `dragging` /
  `centredOnce` / `fitRequested` / `selectedGenre` / `evidence` /
  `isLoadingEvidence` / `evidenceTask` / `hoveredStrandID` /
  `gestureScale` / `gestureOffset` as eleven separate `@State` /
  `@GestureState` properties on the same view. Pull the viewport-
  geometry subset (`scale`, `offset`, `centredOnce`, `fitRequested`,
  `gestureScale`, `gestureOffset`) into a single `@Observable
  GenreMapViewport` model. Wire the zoom shortcuts + the
  `baseTransform` against the model instead of free properties.
- **Law(s):** 6 (cohesion — viewport state is one thing), 11
  (boilerplate — six @State props move to two: `viewport` + dragging
  state).
- **Pays its freight (falsifiable):** the view's `@State` /
  `@GestureState` properties for viewport geometry drop from 6 → 1
  (`@State private var viewport = GenreMapViewport()`); the
  `resetZoom` / `fitToView` / `zoomIn` / `zoomOut` private functions
  collapse into methods on the model.
- **Risk:** medium — `@GestureState` semantics differ from `@State`
  and don't trivially live on an `@Observable`; a naive port turns
  the updating(_:state:) gesture composition into a mid-render
  mutation. Veto if porting `gestureScale` / `gestureOffset` adds
  more lines than it removes.
- **Depends on:** none (pick freely).
- **Verify:** the panel still pans/zooms; computer-use verifies the
  default presentation is unchanged.
- **Effort:** M.

### Phase-3-gate Phase C — Simplify `interCommunityBridges` first-call magic

- **What:** `GenreMapBuilder` currently runs Louvain *twice* — once
  on the mutual-kNN ∪ MST substrate, then runs
  `GenreMapLayoutGraph.interCommunityBridges` against the initial
  partition, then re-runs Louvain on the widened layout graph. The
  intermediate partition is only used to choose bridges. Replace
  with a one-pass formulation: admit the heaviest cross-genre edge
  per `mediumGamma`-cluster *as identified at one community-
  detection pass* — i.e. detect on the widened graph directly,
  using a structural admit-bridges criterion that doesn't depend on
  an earlier partition.
- **Law(s):** 1 (complexity — two Louvain runs for one final
  partition), 6 (cohesion — the bridge-admission and partition-
  detection are entangled across the same dataset twice).
- **Pays its freight (falsifiable):** `GenreMapLouvain.detect` is
  called once per `GenreMapBuilder.build` (the second call goes
  away); the intermediate `initialPartition` variable in the
  builder is deleted; the substrate-widening posture is preserved
  (the Phase-2-gate test for "inter-community bridges admitted"
  stays green).
- **Risk:** medium — the structural admit-bridges criterion that
  doesn't need a pre-existing partition is non-obvious. Veto if the
  replacement criterion either loses the heaviest cross-pair signal
  or admits more bridges than the current one (which would change
  the layout substrate the Phase-2 transferness was tuned against).
- **Depends on:** none (pick freely).
- **Verify:** `GenreMapBuilderTests` + `GenreMapLayoutGraphTests`
  green; computer-use spot-checks unchanged transfer-station count
  on the real library.
- **Effort:** L.

## Phase-5-gate deferred (2026-05-21)

### Phase-5-gate Phase A — Modern modifier-keys idiom once macOS 15+

- **What:** `selectNode` currently reads `NSApp.currentEvent?.modifierFlags`
  to detect a ⇧-modified click, because `.onModifierKeysChanged` (the
  SwiftUI-native equivalent) is macOS-15-only and the project targets
  macOS 14. The current posture is correct and reliable, but reaches
  into AppKit. Once the minimum bumps to macOS 15, replace with
  `@State shiftHeld` + `.onModifierKeysChanged(mask: .shift) { _, new in
  shiftHeld = new.contains(.shift) }` on the panel root and read the
  state inside `selectNode` instead.
- **Law(s):** 14 (idiomatic SwiftUI; avoid AppKit reach-throughs where
  SwiftUI now offers a native modifier).
- **Pays its freight (falsifiable):** `NSApp.currentEvent` call goes
  away from `GenreMapPanel.swift`; `import AppKit` becomes unused (if
  nothing else still needs it).
- **Veto condition:** if `.onModifierKeysChanged` doesn't reliably
  observe modifier-down at the same instant the SwiftUI tap closure
  runs in the live walkthrough, fall back to the current posture —
  the AppKit reach-through is correct, just not idiomatic.
- **Depends on:** macOS-15 minimum deployment target.
- **Effort:** XS.

### Phase-5-gate Phase B — Compare-mode discoverability cue on the canvas

- **What:** the ⇧-click compare gesture has no canvas-side cue. Users
  discover compare either by reading the help-bar copy ("⇧-click to
  compare") or by clicking the inspector's Compare button. The plan
  contracts a discoverable affordance. Add a faint compare-mode
  affordance: when a genre is selected and the user hovers a
  *different* genre, render a thin connecting line / "⇧" badge on the
  hovered pill so the gesture is visible before they invoke it.
- **Law(s):** macos-design (discoverability of non-obvious gestures).
- **Pays its freight (falsifiable):** a first-time user can discover
  compare without reading help-bar copy; the canvas itself surfaces
  the affordance.
- **Veto condition:** if the affordance reads as a permanent edge
  instead of a hover hint, **stop** — that re-introduces the dense-
  edge anti-feature the plan explicitly forbids outside transfer-map
  mode.
- **Depends on:** none.
- **Effort:** M.

### Phase-5-gate Phase C — Tooltip clipping at canvas right edge

- **What:** when a hovered pill sits near the right edge of the
  canvas, the `HoverTooltipCard` overflow gets clipped by the
  surrounding ZStack. Cosmetic but visible (Phase-5-gate
  walkthrough's early Ambient/Alt/BritPop hovers showed it). One-line
  `.position()` clamp: if the tooltip's natural anchor would push it
  past the canvas's trailing edge, anchor it on the leading side of
  the pill instead.
- **Law(s):** macos-design (don't clip primary affordances).
- **Pays its freight (falsifiable):** a hover on the right-most pill
  renders the tooltip fully inside the canvas.
- **Veto condition:** if the clamp logic grows beyond a single
  `.position` modifier with a measured-size branch, **stop** — it's a
  cosmetic edge case, not worth a layout refactor.
- **Depends on:** none.
- **Effort:** XS.

### Phase-6-gate carry-forward — Genre Map: sheet → top-level window?

- **What:** "Show Genre Map…" currently presents as a sheet that
  reopens centred on the heaviest community each time. macos-design
  Phase-6-gate consult: a sheet is a *modal task surface*, not an
  atlas. If the user wants persistent pan/zoom across opens (so the
  map feels like Maps.app's main window, where state survives), the
  correct Mac idiom is to promote Genre Map to a top-level
  `WindowGroup`, not to add `@AppStorage` to a sheet. Adding state
  persistence inside a sheet would be the wrong idiom — sheets are
  meant to reset.
- **Law(s):** macos-design (don't bolt window-level state onto a
  sheet); HIG (sheets are transient, windows are documents).
- **Pays its freight (falsifiable):** the Genre Map becomes openable
  as a real macOS window with its own toolbar and state, separable
  from the main window. The Show Genre Map menu item moves to a
  `Window` command. Pan/zoom + selection survive close/reopen
  naturally because the WindowGroup re-uses its scene.
- **Veto condition:** if it turns out users mostly open the map for
  spot inspection and dismiss within seconds, the sheet is correct
  and persistence is over-engineering — keep as is.
- **Depends on:** none. **Effort:** M.
