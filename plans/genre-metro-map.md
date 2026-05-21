# Genre metro map — user-specific topology + inferred corridors

The successor to today's force-directed *genre graph* panel
(`plans/genre-graph.md`). Same persistent question — "what does my library
look like as a space of genres?" — but a fundamentally different rendering
grammar: **stable geography + inferred metro strands + transfer stations**,
with individual edges revealed only on interaction. The current panel
collapses four distinct meanings (position, continuity, hybridity,
evidence) into one drawing primitive (line); this plan gives each its own
visual.

> **Predecessor:** the v6 `genre_edge` SQLite table and
> `LibraryStore.rebuildGenreGraph` (`plans/genre-graph.md`) become **one
> input channel** of a richer edge model; the vendored `ForceGraphView` is
> replaced by a routed metro-style renderer specific to djroomba (the
> generic control was always a stepping stone — see Phase 7 for what to
> upstream and what to retire).

## Product goal (the four questions the map must answer)

1. **Where am I** in my library's genre space?
2. **What neighborhoods** exist?
3. Which genres are **bridges** between neighborhoods?
4. **Why does this relationship exist** — which artists / albums / tracks
   caused it?

Mapped to visual primitives, the design invariant is:

```
position           → "this genre lives near this region of my library"
metro strand       → "these genres form an inferred corridor"
transfer station   → "this genre connects multiple corridors"
individual edge    → "here is the concrete evidence" (interaction only)
```

Position is **stable geography**. Continuity is **inferred** from
topology, not human-authored genre taxonomy. Hybridity gets its own node
kind. Evidence is **on demand**.

Hard non-goals: rendering every relationship by default; cross-edge
spaghetti; pre-authored macro categories ("Rock", "Electronic"…); generic
giant genres becoming visual black holes; full re-randomisation on
re-import.

## Data model — what we already have vs. what we need

### Today (`plans/genre-graph.md`)

- One persisted table: `genre_edge(genre_a, genre_b, weight INTEGER)`.
- `weight` = **distinct-playlist co-occurrence count** with two curated
  thresholds (`maxPlaylistTracks`, `maxPairsPerPlaylist`).
- One channel of evidence (shared-playlist) only. No artist/album/track
  overlap. No per-genre track/artist/album cardinality on the edge row.
- Display fold is `nonisolated static GenreGraphService.buildDisplayGraph`
  → `[GraphNode<Void>] + [GraphEdge(0…1)]` for the vendored
  `ForceGraphView`.

### What this plan requires

- A **multi-channel** edge model: per pair, separate `artist_overlap`,
  `album_overlap`, `track_overlap`, and the existing playlist
  co-occurrence — each with its own raw **support** (intersection size,
  not just a Jaccard). Evidence pointers (artists/albums/tracks) are
  retrievable on demand, not materialised onto every edge.
- A **per-genre weight** (importance) computed from
  `log(1 + track_count) + 0.8·log(1 + album_count) + 1.2·log(1 +
  artist_count)`, then normalised, so the giant "Rock"-shaped genres do
  not eat the layout. (We have the underlying counts in `song`; this is
  pure SQL.)
- A persisted **layout state** — node positions, community ids/colors,
  strand ids/colors/labels, revision number — keyed by genre id, so
  re-import perturbs locally, not wholesale.

The natural shape is two new tables alongside `genre_edge`:

```
genre_node(
  genre TEXT PRIMARY KEY,
  track_count INTEGER NOT NULL,
  album_count INTEGER NOT NULL,
  artist_count INTEGER NOT NULL,
  weight REAL NOT NULL)               -- normalised importance

genre_edge_evidence(
  genre_a TEXT NOT NULL,
  genre_b TEXT NOT NULL,
  artist_overlap_jaccard REAL NOT NULL,
  album_overlap_jaccard  REAL NOT NULL,
  track_overlap_jaccard  REAL NOT NULL,
  playlist_cooccur_weight REAL NOT NULL,
  shared_artist_count INTEGER NOT NULL,
  shared_album_count  INTEGER NOT NULL,
  shared_track_count  INTEGER NOT NULL,
  total_weight REAL NOT NULL,
  PRIMARY KEY (genre_a, genre_b))     -- canonical a < b
```

Evidence lists (the actual artist/album/track ids per pair) are **not**
materialised — they're queried JIT for hover/click via two CTE shapes on
`song.genre_names + song_*` joins, the same posture as
`associatedPlaylists`. That keeps the persisted footprint small and the
write-time cost bounded.

Migration label is the next ordered string after `v6.genreGraph`
(`v7.genreMap` is the obvious one). Purely additive; v1–v6 stay frozen.

### Edge scoring (composite)

```
edge_weight =
    0.45 · artist_jaccard
  + 0.35 · album_jaccard
  + 0.15 · track_jaccard
  + 0.05 · playlist_cooccurrence_norm
```

with a **support floor**: drop any pair whose
`shared_artist_count + shared_album_count + shared_track_count < 2`.
Track-level genre metadata is the noisiest channel, hence the smallest
weight; tiny genres with one shared thing must not produce a fake strong
edge.

This is the *full* edge graph. The **layout graph** is much sparser —
see Phase 1.

## Phases

> Each phase ends with both a Swift-side success criterion (does it
> compile/test/render correctly) and a perceptual one (does it pass the
> "look at it for 30 seconds — is it readable?" check). The perceptual bar
> is the harder one; the macos-design + typography-designer skills run at
> the end of every phase.

### Phase 1 — Better graph substrate

Replace today's hairball with stable constrained force geography. **No
metro strands yet.**

1. **Schema (`v7.genreMap`).** Add `genre_node` + `genre_edge_evidence`
   (above). Keep `genre_edge` as-is for now; this phase populates the new
   tables alongside it. Rebuild path is one wholesale CTE-driven write
   transaction, same posture as `rebuildGenreGraph`.
2. **Compute per-genre weight.** SQL aggregation over `song.genre_names`
   (`json_each`) joined to artist/album cardinalities. Pure SQLite.
3. **Compute multi-channel edges.** Three Jaccards from
   `song.genre_names ⨯ song.artist_id / album_id / song.id`. The
   playlist channel is the existing `genre_edge` weight, normalised to
   `0…1`. Composite into `total_weight` + materialise support counts.
4. **Construct the layout graph** (sparse — this is the key shift):
   - filter by `support ≥ 2 && total_weight ≥ adaptive_threshold`
     (top 5–10 % by weight per node, with floors for low-degree nodes);
   - per-node mutual-kNN (`k ∈ [4, 8]`, library-size-sensitive);
   - add a **maximum spanning tree** for guaranteed connectivity;
   - add the strongest inter-community bridge edges.
   The *display* graph still knows about more edges (for hover-reveal),
   but the **physics only sees the layout graph**. This alone is the
   single biggest visual win.
5. **Multi-resolution community detection.** Louvain first (no dep,
   easy), Leiden later if quality matters. Run at three resolutions —
   `0.4` (continent), `1.0` (region), `1.8` (block). Persist all three
   per-node memberships.
6. **Constrained force layout.** Build a djroomba-owned layout pipeline.
   Force terms:
   - **edge attraction** ∝ `total_weight` over the layout graph
   - **node repulsion** that accounts for **label rectangle size**, not
     a circular radius (this is what the vendored control does worst —
     the layout is genuinely label-first)
   - **community gravity** (medium resolution) — soft pull to centroid
   - **macro-region gravity** — derived **algorithmically**, not from
     human labels: collapse coarse communities into a supernode graph,
     layout that first, use those positions as the macro anchors for
     the main pass.
7. **Render: geography only.** Major nodes as labelled pills (size from
   per-genre weight); subtle community hulls (or tint background); the
   layout backbone at ≤10 % opacity; **no metro lines yet**.

**Success criteria.**
- Map has recognisable neighbourhoods. Labels do not collide.
- Broad genres do not collapse the graph. Small genres do not fly off.
- `swift test` green; new tests pin the layout-graph construction
  (mutual-kNN symmetry, MST connectivity, threshold adaptivity) and the
  community algorithm against fixtures.

### Phase 2 — Transferness (without metro lines)

Identify bridge genres **from topology alone**, before drawing any
strands.

1. **Compute four transferness inputs** on the layout graph:
   - normalised betweenness centrality (Brandes — bounded library, fine);
   - **neighbour-community entropy** (Shannon over the medium-resolution
     community labels of `v`'s neighbours);
   - **cross-community edge fraction** (weight outside `v`'s community ÷
     incident weight);
   - membership entropy if soft community detection is in play (skip
     while we're on Louvain/Leiden hard partitions; placeholder = 0).
2. **Composite transferness** per the spec's weights
   (`0.30/0.25/0.20/0.15/0.10`, with the strand-count slot at 0 until
   Phase 3 fills it).
3. **Dampen for generic giants.** If a node has high library weight and
   low *multi-community* support (i.e. broad but not actually bridging),
   knock its transferness down — explicit guard so "Rock" doesn't become
   a fake transfer station just for being big. Pin this in a unit test.
4. **Classify** into ordinary stop / junction / transfer station at
   `0.35` / `0.65`.

   > **Phase-2-gate revision (2026-05-20):** the absolute cuts assume
   > the full five-input composite contributes (membership-entropy + the
   > strand-count slot Phase 3 fills). Phase 2 runs with two of the five
   > slots at zero so the composite's mathematical ceiling is **0.75**;
   > even after the Phase-2-gate substrate widening (heaviest inter-
   > community edge per community pair admitted on top of mutual-kNN ∪
   > MST, +3 layout edges on the real ~115-genre library), absolute cuts
   > at `0.35 / 0.65` land **0 junctions + 0 transfer stations**. The
   > observed composite ceiling on the real library is ~0.22 (Alt/Indie,
   > Hard Rock). Phase 2 therefore ships with **relative-rank
   > classification** — top decile of non-zero composites =
   > transferStation, top quartile = junction (`transferStationRank =
   > 0.90`, `junctionRank = 0.75`). Pinned in
   > `GenreMapTransfernessTests.rank classify promotes top decile to
   > transfer and top quartile to junction`. The absolute-cut classifier
   > stays as `GenreMapTransferness.classify(composite:)` and remains
   > pinned at `0.35 / 0.65`; Phase 3 will revisit (probably back to
   > absolute cuts) once the strand-count slot stabilises the composite
   > ceiling at ~1.0. Calibration drift from absolute to relative is a
   > spec decision and not a silent threshold tweak — it's the right
   > robustness posture across libraries with different bridge-density
   > profiles (a library with one giant connected blob still surfaces
   > its strongest bridges; a library with many small islands still
   > surfaces them in proportion).
5. **Render the three node kinds.** Ordinary = small dot or compact
   pill; junction = pill with a tick mark; transfer station = larger
   pill with a *neutral* multi-strand marker (single colour for now —
   coloured strand ticks come in Phase 3).
6. **Click a transfer station** → show *why*: connected community
   labels (their algorithmic names from Phase 3 not yet available, so
   list member-genre samples), the dampening contributors, and the
   evidence edges from this node (the first time individual edges are
   rendered — for one node, on demand, in a side panel).

**Success criteria.**
- The genres that *feel* like junctions on the current ForceGraph view
  (Alt/BritPop, the Trip-Hop-shaped clusters, the Laptop hubs from the
  CrossingIndex Patch 5 repro) come out as transfer stations.
- No giant generic genre is a fake transfer station.
- Tests pin the betweenness / entropy / cross-fraction / dampening on
  hand-crafted fixtures (small enough to compute by hand).

### Phase 3 — Infer metro strands

Extract algorithmic corridors from the topology. **No human-curated
labels anywhere.**

1. **Per-community strands.** For each medium-resolution community:
   build its induced subgraph → MST → extract heavy paths
   (`length ≥ 3` and `total_weight ≥ τ`); promote side branches as
   branch strands. Bounded count per community (2–4).
2. **Cross-community bridge strands.** Build the community graph; find
   the strongest inter-community edges; for each, recover the strongest
   path through the *original* graph between them (Yen-k or just
   weighted shortest path; the cost function is `1 − total_weight`).
3. **Rank + cull.** Keep 5–12 strands total at default zoom. Rank by
   `node-weight-sum + length + edge support + transfer-station count`.
   Cull pairs whose Jaccard on member sets exceeds `0.6`; the survivor
   absorbs the loser as a branch.
4. **Algorithmic labels.** Per strand: tokenise member genre names,
   drop junk tokens (`misc`, `other`, `genre`, …), TF-IDF across all
   strands, pick top 2–4 terms. Also surface 1–2 representative
   high-centrality genre names. Output is a **placename**, not truth —
   default render shows no strand label until hover. Representative
   artists are computed JIT from `song`/`artist` on hover (cheap query;
   no extra persisted state).
5. **Wire strand membership back into transferness.** Phase 2's
   `strand_count(v)` slot becomes real; recompute transferness; reclassify.
6. **Render strands as faint splines** (Catmull-Rom through the strand's
   station positions). Stations gain coloured ticks for each serving
   strand; transfer stations show 2+ ticks. **No routing or bundling
   yet** — splines may cross; that is the next phase. Default opacity
   for non-selected strands is low.

**Success criteria.**
- Lines feel like *meaningful* corridors, not arbitrary tree branches.
- Transfer stations visibly replace the cross-edge bursts of the current
  view.
- Cycling strand hover walks distinct regions of the map (good
  topological coverage).

### Phase 4 — Routing and bundling

Make the metro overlay visually coherent. This is the longest phase by
implementation surface and the one most likely to spawn its own sub-doc.

1. **Routing graph** over the 2D plane. Inputs: station coords; label
   bounding boxes (already known from Phase 1 layout); community hulls;
   obstacle padding. Cost: passing through labels, sharp turns,
   crossing unrelated lines, coming too close to unrelated stations,
   long detours. Reward: following an existing bundled corridor,
   passing through a valid transfer station, hugging the strand's own
   stations.
2. **Spline shaping.** Replace naïve Catmull-Rom with obstacle-aware
   routing (probably an A* over a coarse grid + spline relaxation). Pin
   curvature bounds for legibility.
3. **Bundling.** When two strands share a path segment between the same
   (or near-the-same) station pair, give them a shared corridor id;
   render each strand with a small perpendicular offset inside the
   corridor. The five-colour parallel-strands case is the visual proof.
4. **Crossing minimisation.** When unrelated strands must cross, prefer
   crossings at high angles and at transfer stations (where the user
   already expects a visual knot).
5. **Performance.** Routing runs on a background actor; the layout pass
   only re-runs it on geographic change. Cache routed splines keyed by
   `(strand_id, layout_revision)`.

**Success criteria.**
- Crossings are *interpretable*: each crossing is between strands the
  user can name (after Phase 5's hover).
- Shared corridors look intentional — the eye reads them as a bundle,
  not five overlapping wires.
- Labels remain readable; no strand passes through a label rectangle.
- Routing recompute on a layout-revision bump is ≤200 ms for the real
  library (731-edge curated graph today; budget assumes ~3–5× growth).

### Phase 5 — Evidence and discovery UX

Make every relationship explainable. This is where the map becomes a
**discovery tool**, not a picture.

1. **Hover a genre.** Highlight; show serving strands; highlight 1-hop
   layout-graph neighbours; fade unrelated regions; tooltip with
   track/album/artist counts, transferness, top related genres **with
   evidence counts** (`Alt/Indie — 18 shared artists, 42 shared albums`).
2. **Click a genre.** Open a local detail mode. For an ordinary genre:
   ego network + nearest genres + representative artists/albums (the
   first place we materialise evidence in-app). For a transfer station:
   the **transfer map** — selected genre centred, serving strands shown
   in full, nearby stations grouped by strand, evidence panel docked.
   Click is the ONLY state where dense edges are safe to render.
3. **Hover a strand.** Highlight path + station labels along it; fade
   unrelated; show generated label + representative artists.
4. **Compare two genres.** Two-genre selection mode. Show
   highest-weight paths between them (Yen-k); the transfer stations
   along those paths; shared artists/albums/tracks (full evidence
   lists); the involved strands. This is the highest-value interaction
   and the one that earns the whole map.
5. **Side panel.** Native `.inspector()` (matches `MusicContext`'s
   pattern from M5) for evidence and comparisons. Toolbar toggle, same
   collapse-state idiom as the existing inspector.

**Success criteria.**
- A user can point at any visible edge or strand and get an answer to
  "why is this here?" in one click.
- The current "select Alt/Laptop → 8 playlists" associations-card
  affordance is subsumed by the new evidence panel without regression.

### Phase 6 — Persistence and incremental updates

The map must feel like the user's stable personal atlas.

1. **Persist layout state.** New table:
   `genre_map_state(genre TEXT PRIMARY KEY, x REAL, y REAL,
   community_coarse TEXT, community_medium TEXT, community_fine TEXT,
   strand_ids TEXT (JSON array), updated_at INTEGER, revision INTEGER)`.
   Strand-level state (`strand_id`, colour, label tokens) in a sibling
   `genre_map_strand` table keyed by `strand_id`. The `revision` int
   bumps wholesale every recompute.
2. **Match new communities to old.** Jaccard over member sets;
   threshold (`0.5`?) preserves the **community id, anchor, colour and
   placename**. Below threshold, mint a new id.
3. **Match new strands to old.** Member-Jaccard + path-similarity
   composite. Preserve strand colour + label tokens for high matches.
4. **Incremental layout.** Initialise positions from
   `genre_map_state.x/y`; add a stability force
   `μ · (previous − current)` only on the *existing* nodes; let new
   nodes settle around their neighbours. **Never reseed from random** on
   re-import.
5. **Trigger surface.** Same hook points the genre graph uses today
   (`runImport` after the genre pass, `addSongs` / `removeTracks` /
   `setAppPlaylistTracks` / `deleteAppPlaylist`); unchanged plumbing,
   just a different recompute target. The `MusicController`
   `runMapRebuildIfEnabled()` funnel replaces
   `reanalyzeGenreGraphIfEnabled()`; the existing pref
   `autoReanalyzeGenreGraph` is renamed / re-pointed (UserDefaults
   key kept, semantics preserved).

**Success criteria.**
- Adding ~100 albums to the library changes the **local** neighbourhood
  and may add/remove a few strands; the rest of the map is visibly the
  same place (positions, community colours, strand colours and labels
  preserved). Pin this with a fixture-driven test that diffs the
  rendered `RenderModel` before/after a controlled mutation.
- Strand colours don't flip on every reanalyze.

### Phase 7 — Upstream the `DJROOMBA PATCH`es and retire the vendored copy

The five patches in `Vendor/ForceGraph` were marked from day one for
upstreaming. After Phase 4 lands, **djroomba no longer uses
`ForceGraphView` directly** — the metro renderer is its own thing — but
the patches are still substantively correct upstream improvements to a
generic force-directed control. Upstream them so anyone else consuming
`tqbf/fdg` benefits, then either drop the vendor dir or keep it as a
tiny secondary dependency for very-zoomed-in evidence views (TBD; the
plan is **drop** unless an explicit need surfaces).

Patches, each as its own PR against `tqbf/fdg` `main`:

1. **Search-pulse redraw pin removal** (`GraphEngine.swift:351`).
   The `wantsContinuousRedraw = true` while-search-HUD-up wakes the
   `TimelineView` against a fully-settled graph, churns 60 Hz Canvas
   redraws of ~1.5 k nodes, and (most visibly) flickers the mouse
   cursor because the OS resets the cursor over a continuously-
   invalidating view. Dropping the pulse pin makes the Reduce-Motion
   path universal; matches still light up/dim (snapshot-driven) and
   recenter-on-cycle still animates via the finite `keepLiveUntil`
   tail. Open with a 30-second screen capture demonstrating the cursor
   flicker on the current `main` and the fix.
2. **Pan-only → focus-with-zoom on search centring**
   (`GraphEngine.swift:630`, `Viewport.swift:99`). New
   `Viewport.focus(on:minScale:)` (centre **and** raise zoom to a
   readable floor, never zoom *out*) used by `recenterViewportForSearch`
   for both cycle and query-narrowing. Layout-bloom follow + selection
   pin keep the pan-only path (their zoom is intentionally preserved).
3. **Neighbour-walk** (`GraphEngine.swift:109,729`,
   `KeyCaptureView.swift:137`). Arrow keys cycle a selected node's
   neighbours strongest-edge-first; `Return` commits the previewed
   neighbour as the new centre; 2 s of inactivity snaps back to the
   anchor. Engine state + a cancellable MainActor revert task;
   `KeyCaptureView` dispatches ↑↓←→/Return/Esc unconditionally and the
   engine decides consumption (search-cycle vs walk vs pass-through).
   This one needs a small public-API change upstream (a new optional
   `onNeighbourWalk` callback or — better — a documented
   "engine-driven keyboard navigation" mode toggle); discuss the API
   shape in the PR description before code review.
4. **`onFocusChange(genre, edgeOther)` callback** (`ForceGraphView.swift:78`,
   `GraphEngine.swift:36,655,772…`). New optional `ForceGraphView`
   parameter; defaulted to `nil` so it's strictly additive. Lets hosts
   show context (selected node, previewed-neighbour edge during walk,
   snap-back, commit, deselect) without reaching into the engine. The
   cleanest of the five PRs.
5. **`CrossingIndex` hub-cell pair-test bound**
   (`CrossingIndex.swift:67,169`). Skip the per-cell all-pairs test
   when a cell exceeds `maxCellMembers = 96` — such a cell is a
   degenerate hub-star super-cell whose `O(degree²)` pair test
   degenerates `recompute` to `O(E²)` and pegs the main thread
   (profiler-verified: 11 978 → 10 main-thread samples on the identical
   drag repro). Crossings interior to a degenerate hub core are
   omitted; HUD count is then a documented lower bound, consistent
   with the existing representative-not-exhaustive glyph contract.
   This one needs a sentence in the README about the lower-bound
   semantic; otherwise mechanical.

**Order.** Land 4 first (cleanest, additive, no upstream API debate),
then 1 (mechanical bugfix, screen-capture diff), then 5 (mechanical
perf fix + one-line README note), then 2 (new `Viewport` method —
small API surface), finally 3 (largest API surface — needs design
discussion in the issue first).

**Vendor retirement.** Once 1, 2, 4, 5 are merged + tagged upstream
(probably `v1.1.0`), drop `Vendor/ForceGraph` and point the root
`Package.swift` back at `tqbf/fdg` from a published version pin. Patch 3
(neighbour-walk) is *probably* not used by the metro renderer anyway
(arrow-key navigation in the metro view is mode-specific — pan vs
strand-walk vs station-walk); if it isn't, it's fine to leave open
indefinitely as an upstream-side enhancement and **not** block vendor
retirement on it. If it *is* still used by some residual `ForceGraphView`
instance after Phase 4, hold vendor retirement until 3 also lands.

**Success criteria.**
- All four mechanical PRs merged upstream at a tagged release.
- `Vendor/ForceGraph/` removed; `Package.swift` consumes the upstream
  release; `swift build` + `swift test` green.
- The neighbour-walk PR is either merged, or has a clear hold and
  documented reason on `PROBLEMS.md`.

## Tests

This plan adds enough new pure logic (graph construction, community
detection, transferness, strand extraction, label generation, routing,
matching) that test posture matters. The rule:

- **Pure functions get unit tests** — layout-graph construction, the
  per-genre weight, the composite edge score, mutual-kNN symmetry, MST
  connectivity, betweenness on fixtures, community-matching Jaccard,
  strand-matching Jaccard, label tokenisation/TF-IDF, the routing cost
  function (the search routine itself is pinned by snapshot tests
  against a small grid).
- **Store SQL gets store tests** — the v7 migration ordering &
  idempotence, the wholesale CTE rebuild for the new tables, the
  evidence-on-demand reads, one-way isolation, all the same posture as
  `GenreGraphTests`.
- **The visualizer is screenshot-evidence + macos-design/typography
  review**, same precedent as `plans/genre-graph.md`. Correctness lives
  in the pure layers; the renderer is a layout.

Target: each phase ends with `swift test` green and at least one
fixture-driven test per new pure subsystem.

## What lives where

| File / module | Purpose |
|---|---|
| `DJRoomba/Music/GenreMap/GenreMapBuilder.swift` | One pure pipeline: edges → layout graph → communities → layout → transferness → strands. Phase-by-phase, sub-files. |
| `DJRoomba/Music/GenreMap/GenreMapService.swift` | `@MainActor @Observable` wrapper (same shape as `GenreGraphService`). |
| `DJRoomba/Music/Store/LibraryStore+GenreMap.swift` | v7 schema + rebuild SQL + evidence-on-demand reads. |
| `DJRoomba/Views/GenreMap/*` | All view code. Subdivided so swiftui-pro "extract subviews" stays clean — `GenreMapPanel`, `StationLabel`, `StrandSpline`, `CommunityHull`, `EvidencePanel`, etc. |
| `Vendor/ForceGraph/` | Stays for Phases 1–3 (reuses Viewport / Canvas / pulse infra inside it isn't worth re-writing); deleted at the end of Phase 7. |
| `plans/genre-graph.md` | Historical context for the v6 panel. Cross-link this file at its top once Phase 1 lands. |

## Deliberately deferred

- **Soft community detection.** The `membership_entropy(v)` slot stays
  at 0 until we have a reason to add a soft algorithm. Hard partitions
  are sufficient for the first six phases.
- **Embedding-based edge similarity.** The `metadata_similarity` slot
  in the spec is 0 until/unless we have an embedding source we trust.
  Not blocking.
- **Curated overrides.** No "always promote `Rock` to a continent"
  hooks. The whole point is algorithmic — if the algorithm gets it
  wrong, tune the algorithm.
- **Multi-library / multi-user.** Same single-user posture as the rest
  of djroomba.
- **Animated transitions on incremental recompute** (e.g. nodes gliding
  to their new positions). Nice, but Phase 6's success criterion is
  *positional* stability, not animation; revisit after Phase 6 lands.
