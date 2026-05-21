# Son of genre map — trunk + radial tree, with faint back-edges

The successor to `plans/genre-metro-map.md` (which is feature-complete
through Phase 6 on `feature/genre-metro-map` but not merged). The
substrate Phases 1–6 built — multi-channel edge scoring, multi-resolution
Louvain communities, transferness, `song_genre` materialised view, Yen-k
discovery, `v9.genreMapState` persistence — all stays. The display
grammar is what's being replaced.

> **Predecessor:** `plans/genre-metro-map.md`. Read its "Ship status —
> 2026-05-21" prelude block for the full per-phase resolution of the
> previous attempt. This plan strips the metro renderer, the
> obstacle-aware A\* router, the corridor-bundling pass, and the
> strand-as-metro-line grammar in favour of a tree-shaped layout with
> on-demand radial focus. The previous plan's success criterion was
> *explanation* (every relationship answerable); this plan's success
> criterion is **inspiration** (a glance is enough to know what to
> listen to next).

## The reframe

The metro map worked but solved the wrong problem. Its design
invariant was "every relationship explainable in one click" — the
strand grammar, the transfer stations, the dense-edges-only-when-
focused rule, the compare mode with Yen-k evidence, the on-canvas
crossings each in principle nameable. All of that was correct as
information visualisation and is a poor fit for the actual question
the user has when they open it:

> "What should I listen to right now?"

That question is answered by **browsing**, not reading. The visual
should be inviting more than informative. So:

- A glance at the map shows the shape of the library — a small number
  of trunks, each a recognisable lane.
- Clicking a genre rearranges to that genre's neighbourhood — a radial
  fan of related genres — so the user can drift sideways.
- Background detail (full graph edges, strand membership, evidence
  counts) stays available but doesn't shout. The metro plan's
  "evidence is on demand" posture is preserved; the new plan extends
  it to "structure is on demand."

The previous plan asked the four questions "where am I / what
neighbourhoods / which bridges / why this relationship?" This plan
answers two of them well (*where am I* and *what's adjacent to this*)
and demotes the other two to inspector affordances when the user
explicitly asks.

## Visual grammar

### Default state — trunk tree

- **k trunks** (cap 7), laid out from `(0, 0)` toward `(max, max)` along
  the canvas diagonal. Trunk labels are large pills; trunk colour is
  the community colour persisted from `genre_map_state`.
- **Branches** fan **radially** around each trunk over a partial arc
  (~120° aimed off-diagonal, alternating sides per trunk to balance
  ink). Multi-level: a branch can itself fan into sub-branches if it
  has many sub-children to surface.
- Branch-to-parent edges drawn as smooth curves (Catmull-Rom over the
  centripetal variant, same as the metro renderer's spline kernel that
  Phase 4 settled on — kept).
- **Faint back-edges**: every non-tree edge from the original
  multi-channel edge graph rendered at very low opacity (~6%). These
  are the cross-community connections the MST drops. They tell the eye
  "there is more here than the tree shows" without crowding.

### Highlighted state — radial focus

- Click any pill → animated transition to a **radial focus layout**
  centred on the selected genre. Animation is a 300–400 ms easeInOut
  morph (positions interpolate from trunk-tree placement to radial
  placement, opacity of unrelated pills fades in tandem).
- Selected genre sits at the centre. Its 1-hop neighbours fan around
  it in a full circle; 2-hop neighbours sit in an outer ring at lower
  opacity. Edges to non-neighbours hidden.
- Click empty area or press `Escape` → animated transition back to
  the trunk view.

### Compare state

- ⇧-click a second genre while one is selected → Yen-k shortest
  paths through the layout graph, same logic as `GenreMapDiscovery`
  from the previous plan (kept verbatim). The two-genre comparison
  rides on top of either the trunk or the radial-focus layout —
  whichever is current — and highlights the path nodes + dims everything
  else.

### Will-not-fit-to-window posture

Explicit. The map is **not** designed to fit on one screen. With k=7
trunks and ~108 leaves spread across them, the canvas is large; the
user pans (and scrolls and zooms) to explore. Inherited directive
from the previous plan's Phase 3 gate:

> "We CANNOT reasonably visualize the entire genre space in one
> screen, so don't try."

No fit-to-view default, no compaction pressure, no shrinking of
labels to make everything fit. The same memory at
`~/.claude/projects/.../genre-metro-map-scrolling-fine.md` enforces
this for every agent.

## What stays vs. what goes

| Layer | Status |
|---|---|
| `v7.genreMap` schema (`genre_node`, `genre_edge_evidence`) | KEEP — input to the MST + trunk-selection. |
| `v8.songGenreMaterialised` (the `song_genre` view + indexes) | KEEP — evidence-on-demand still feeds the inspector. |
| `v9.genreMapState` (positions, communities, strand ids, label tokens) | KEEP — repurposed: positions now mean trunk-fan placement, communities still match across re-imports, strand-ids retire (see below). |
| Multi-resolution Louvain (γ = 0.4 / 0.85 / 1.8) | KEEP — γ=0.85 medium-resolution communities select the trunks. Coarse + fine resolutions retained for future use. |
| Per-genre weight + composite edge weight | KEEP — feeds the MST cost function. |
| `GenreMapTransferness` (Brandes betweenness + entropy + cross-community fraction + giant-genre dampening) | KEEP — one of the candidate trunk-selection metrics. |
| `GenreMapPersistence` (community / strand Jaccard matching + stability force) | KEEP — community matching still applies; strand matching retires with the strands; stability force becomes "trunk-membership inertia" (a genre that was on Trunk-X stays on Trunk-X across re-import if its community still maps). |
| `GenreMapDiscovery` (selection state, Yen-k, transfer-map plan, 1-hop helpers) | KEEP — wired to the new view. Transfer-map plan retires; replaced by the radial-focus plan (a similar pure-function plan, different geometry). |
| Phase 5 evidence reads in `LibraryStore+GenreMap.swift` (top artists/albums + shared artists/albums/tracks) | KEEP — the inspector still surfaces these. |
| `GenreMapStrandInference` (per-community heavy paths + cross-community bridges + TF-IDF strand labels) | RETIRE the *display* side. The TF-IDF label generator gets re-targeted onto trunks: a trunk's label tokens are derived from its branch composition. The per-community MST heavy-path extraction also gets re-targeted into the new "main paths inside each trunk fan" picker. |
| `GenreMapForceLayout` (constrained force + label-rectangle repulsion + stability force) | RETIRE. Geometric layout replaces it. Cheap, deterministic. |
| `GenreMapRouting` (A\* over coarse grid, label-obstacle costs, spline relaxation) | RETIRE. Tree edges follow parent-child Bezier curves; no routing needed. |
| `GenreMapBundling` (corridor extraction + perpendicular offsets) | RETIRE. No parallel-strand bundling. |
| `GenreMapRoutingActor` + `GenreMapRoutingVerifier` | RETIRE. No background routing compute. Main thread can do the tree layout in tens of ms. |
| `StrandSpline` view | RETIRE. Replaced by a single `BranchEdge` view (parent-child Bezier) + a `BackEdge` view (faint straight line for non-tree edges). |
| Phase 4 cold-rebuild latency (~1.27 s on the live library) | GOES AWAY. Geometric layout is O(n); the slow path was the router. |
| `GenreMapPanel` (the sheet host) | KEEP, restructure. Drop the strand-chip footer. Inspector docking, ⌘⌥I toggle, ⌘+/-/0/9 zoom shortcuts all retained. |
| Right-docked 340 pt inspector | KEEP. |
| Standing user directive "scrolling is fine" | KEEP — explicitly the layout's defining constraint. |

The net effect: roughly half the metro plan's code volume (the routing
+ bundling + verifier subsystem, ~2500 LOC + tests) becomes deletable.
What remains is the substrate that justifies its existence by feeding
the new view + the pieces of the discovery UX that still apply.

## Data model

No schema changes. The repurposing fits inside `v9.genreMapState`:

- `genre_map_state.x` / `.y` now mean tree-layout placement, not
  force-layout settled position. Same column, different geometric
  semantics. Persistence Phase 6's community matching still preserves
  these on re-import.
- `genre_map_state.strand_ids` retires as a concept; the JSON column
  stays (additive deprecation) so a v9 → v10 migration is unnecessary.
  Future cleanup: a `v10.genreMapState` drops the column, but not for
  the first ship.
- `genre_map_state.community_medium` becomes the **trunk-id** for any
  genre that shares its community's representative — i.e. the trunk
  membership is *derived* from existing data, not separately persisted.
- One new derived structure (in-memory only, no schema): `GenreTreeNode`
  = { genre, parent: GenreTreeNode? (nil ⇒ trunk), children:
  [GenreTreeNode], depth, fan-angle, layout: (x, y) }.

## Trunk selection

One representative per medium-resolution community (γ=0.85, which the
previous plan settled on after the gate calibration). Cap at 7; if the
library has > 7 communities, take the 7 with the highest total
community weight (sum of per-genre weights of members).

**The selection metric inside each community is configurable.**

The user has explicitly said: "I won't know what metric is best until I
see it." So the implementation must let us swap metrics quickly and
A/B them on the real library. Initial set:

- **`.highestWeight`** — heaviest single member by per-genre weight.
  Risk: generic giants (Rock, Pop, Country) dominate the trunks.
- **`.highestTransferness`** — the Phase 2 composite (with strand-count
  slot zeroed out — strands are retired). Picks the most *connective*
  member of each community. Risk: a community's most-bridging genre
  may be obscure even if its trunk role is important.
- **`.highestCentrality`** — normalised betweenness inside the
  community's induced subgraph. Mid-ground between weight and
  transferness.

The metric lives behind a `TrunkSelectionMetric` enum + a Debug menu
toggle so the user can flip live and compare visually. The default
ships as the one the user picks after seeing all three on the live
library.

## MST construction

- Edge cost = `1 − total_weight` (same cost function as Phase 4's
  `GenreMapRouting.routeSegment` used for in-graph paths).
- Algorithm = Kruskal with union-find (the union-find scaffolding is
  already in `GenreMapPersistence`; reuse it).
- Result: an `n-1`-edge spanning tree over all 115 genres.

The 3 dropped edges (117 − 114 = 3 on the real library — the previous
plan's substrate widening admitted) are exactly the cross-community
bridges Phase 2 worked to add back. They DON'T disappear; they become
**faint back-edges** rendered at ~6 % opacity. The eye knows they're
there; the topology doesn't crowd because of them.

## Tree construction from trunks

For each trunk, BFS outward through the MST. Each non-trunk genre is
claimed by the trunk that reaches it first (ties broken by lowest
cumulative MST cost). The result is a forest of k ≤ 7 trees covering
every genre.

Branches at depth-1 fan radially around their trunk over the trunk's
allocated arc (~120°, alternating side-of-diagonal). Depth-2 branches
fan radially around their depth-1 parent over a narrower arc (~60°).
Depth-3 and beyond: same recursion, narrower arc each level.

A branch's radial position within its parent's arc is decided by its
own per-genre weight (heavier = closer to the parent's local "12
o'clock"). This makes the heaviest branch readable first.

## Phases

Five phases. Each ends with `swift test` green and a live spot-check
on the real 115-genre library.

### Phase A — MST + trunk selection + tree construction (pure logic)

Pure module `DJRoomba/Music/GenreTreeMap/GenreTreeBuilder.swift`:

- Kruskal MST over `genre_edge_evidence`.
- Pluggable trunk selection via a `TrunkSelectionMetric` enum with the
  three variants above. Cap k = 7; tie-break by community weight.
- BFS tree from each trunk; first-claim wins.
- Output: `GenreTreeModel { trunks: [GenreTreeTrunk], orphans: [Genre] }`.
  Orphans exist only if a genre has no MST path to any selected trunk
  — shouldn't happen in a connected library, but defensively handled.

**Tests.** Kruskal on a 5-node fixture; trunk-cap behaviour at k > 7
communities; tie-break determinism; BFS first-claim correctness;
metric variants produce different trunks on a hand-crafted fixture.

### Phase B — Geometric layout + the trunk-tree view

Pure geometric placement in `GenreTreeLayout.swift`. Trunks along the
diagonal; branches radial as specified above. Returns concrete world
coordinates for every node + every branch curve's control points.

New view `GenreTreeMapPanel.swift` replaces `GenreMapPanel.swift` as
the sheet's content. Renders:

- Trunk pills (large, community colour, semibold-bold weight).
- Branch pills (mid-weight, smaller).
- Sub-branch pills (small, regular).
- Parent → child curves (Catmull-Rom centripetal, the survivor of
  Phase 4's spline work).
- Faint back-edges (straight lines, ≤ 8 % opacity).

The metro panel stays in-tree but unwired from the menu — easy to
re-enable for a comparison build but not user-visible. The new menu
item is "Show Genre Tree…" (keystroke ⌥⇧⌘A re-pointed; the previous
"Analyze Genre Map" action stays under a different shortcut for
manual rebuilds during development).

**Performance.** Geometric layout is O(n + e). Should be < 50 ms on
the real library, dominated by `genre_edge_evidence` read + Kruskal.
No background actor; main thread does it.

**Live verification.** Open the map; the new tree view appears. Pan
around (the canvas is huge — explicitly larger than any reasonable
viewport). Confirm trunks readable along the diagonal; branches
legible at the default zoom; back-edges visible but faint.

### Phase C — Radial focus + animated transition

Pure: `GenreTreeRadialPlan.swift` computes the radial layout for a
selected genre — 1-hop neighbours on a circle of radius `r1`, 2-hop
on `r2`, fade-amounts per ring. Returns target positions for every
visible node.

View: animate `GenreTreeMapPanel` between trunk-tree layout and
radial-focus layout. Interpolate positions linearly; interpolate
opacities (faded nodes go to ~6 %). 300 ms ease-in-ease-out. Click
empty area or press `Escape` to return.

**Performance.** Single SwiftUI `withAnimation` block; no per-frame
recompute. The target positions are computed once on click.

**Live verification.** Click any pill; the layout flows into the
radial focus. Click empty area; flows back. Drag inside the radial
view: the focused pill remains at centre; user can pan to read the
fanned neighbours.

### Phase D — Inspector + compare + listen-to-this

The Phase 5 inspector content survives: hover tooltip, click-to-show
neighbours + representative artists + representative albums, ⇧-click
compare → Yen-k paths. All re-uses `GenreMapDiscovery.swift` from
the previous plan.

What's new: a **listen-to-this** action surfaces in the inspector
when a single genre is selected. The action picks a small playlist
from the genre's `song_genre` rows (top N by artist diversity?
sampling? — pick after first prototype) and either:

- Adds to a transient queue and starts playback, or
- Creates a "Genre Tree: <name>" app playlist and opens it.

This is the inspiration-loop closer. The whole tree exists to spark
"oh, let me hear that" — the click should deliver. Default to a
transient queue (less commitment); the inspector exposes "Save as
Playlist" as a follow-up.

**Tests.** The track-picking algorithm is pure and fixture-testable.
The queue / playlist write path goes through the existing
`AppPlaylistService` + `PlaybackService` (no schema change).

**Live verification.** Pick a trunk, listen → playback begins. Pick a
branch, listen → playback shifts to the branch's character. Drift
through several radial focuses; the listen-to-this affordance
remains one click away.

### Phase E — Persistence repurpose + retirement

- `v9.genreMapState` repurpose: `x` / `y` semantics change from
  force-settled to tree-layout; `strand_ids` column stays unused
  (additive deprecation); `community_medium` becomes the trunk
  membership when matched.
- `GenreMapPersistence.matchStrandsByMembers` retires (no strands).
- Phase 6's community matching by Jaccard ≥ 0.5 stays — preserves
  trunk identity across re-imports.
- `GenreMapForceLayout` deleted; `GenreMapRouting` /
  `GenreMapBundling` / `GenreMapRoutingActor` /
  `GenreMapRoutingVerifier` deleted; `StrandSpline` deleted;
  `GenreMapStrandInference` deleted (after confirming TF-IDF label
  generator is re-targeted, see Phase B's trunk-label work if any).
- The retired metro plan's tests for the deleted modules are deleted
  with them. Tests for the substrate (community detection,
  transferness math, Kruskal, evidence reads, persistence matching)
  stay.

**Final test count target.** Phase 6 left us at 357 / 54. Phases
A–D add tests; Phase E deletes the metro-only tests. End state
probably 290–330 / 45–50. The reduction is fine — the deleted
tests were proving correctness of subsystems that no longer exist.

## Tests

The substrate tests stay green throughout (community detection,
transferness, persistence matching, evidence reads). The new pure
modules each get fixture-driven tests:

- **`GenreTreeBuilder`** — Kruskal correctness on a 5-node fixture;
  trunk-cap at k > 7; tie-break determinism; BFS first-claim wins.
- **`GenreTreeLayout`** — diagonal placement deterministic; radial
  arc partitioning sums to the allocated arc; depth-recursion
  narrows correctly.
- **`GenreTreeRadialPlan`** — 1-hop / 2-hop ring assignment;
  opacity targets correct; positions don't escape the canvas.
- **`TrunkSelectionMetric`** variants produce different trunks on
  hand-crafted fixtures.

The visualizer remains screenshot-evidence + macos-design /
typography-designer review, same precedent as the previous plan.

## Open questions to workshop as we go

These are decisions the user has explicitly deferred to "I'll know
when I see it." Each is small enough to flip in a single agent pass
without re-architecture.

1. **Trunk selection metric.** Three variants ship behind a Debug
   menu toggle. The user picks after seeing all three on the live
   library.
2. **Diagonal angle.** 45° is the natural default. 30° (more
   horizontal) or 60° (more vertical) might pack labels better
   depending on the library shape.
3. **Branch arc width.** ~120° per trunk is a starting point;
   tighter (90°) is more compact but harder to fan many branches;
   wider (150°) is more readable but eats into neighbours.
4. **Listen-to-this track-picking.** Top-N by artist diversity?
   Random sample weighted by per-genre composite? Round-robin
   across albums? First prototype: deterministic top-N by play
   count then artist diversity. Refine after listening to several
   genres.
5. **How many depth levels.** Some trunks have ~20 branches; depth-2
   sub-fanning may be needed to fit them. Default: depth ≤ 3, fall
   back to a "(N more)" affordance if it exceeds.
6. **Animation timing.** 300 ms is the starting point. The user is
   shown screen-recordings of 200 / 300 / 400 / 500 ms variants and
   picks.
7. **Where to put the `Listen` action.** Inspector header, or a
   dedicated overlay button on the selected pill, or a global "Play
   this neighbourhood" toolbar action when in radial-focus mode.

## Deliberately deferred

- **Multi-library / multi-user.** Same single-user posture as the
  rest of djroomba.
- **Curated overrides.** No "always promote Rock to a trunk" hooks.
  Algorithmic-only, per the standing project principle.
- **Soft community detection** and **embedding-based edge similarity**
  — both still deferred from the previous plan; same posture here.
- **Reviving the metro view as a toggle.** The metro code stays
  in-tree through Phase D; Phase E retires it. If the trunk view
  doesn't ship the user any inspiration the metro view did better,
  we can roll back the deletion. Otherwise it goes.
- **Animated transitions on re-import** (genres gliding to new
  positions when the library changes). Nice; not blocking. Same
  posture the metro plan settled on.

## Branch posture

Probably best done on a fresh branch off `main`:
`feature/genre-tree-map`. The `feature/genre-metro-map` branch + PR
#5 stay open as historical reference; if Phase E retires the metro
view entirely, that PR's commits become "intermediate state we
learned from" — keep the branch alive but don't merge.

If the user prefers to land the tree view as a sequel commit on
`feature/genre-metro-map` (so all genre-visualisation work lives on
one branch and ships as one PR), that also works. The decision
doesn't affect implementation, only PR shape.

## What lives where

| File / module | Purpose |
|---|---|
| `DJRoomba/Music/GenreTreeMap/GenreTreeBuilder.swift` | Kruskal MST + trunk selection + BFS tree construction. Pure, fixture-tested. |
| `DJRoomba/Music/GenreTreeMap/GenreTreeLayout.swift` | Geometric placement (diagonal trunks, radial branches). Pure. |
| `DJRoomba/Music/GenreTreeMap/GenreTreeRadialPlan.swift` | Per-genre radial focus plan. Pure. |
| `DJRoomba/Music/GenreTreeMap/TrunkSelectionMetric.swift` | The pluggable metric enum + the three implementations. |
| `DJRoomba/Views/GenreTreeMap/GenreTreeMapPanel.swift` | The new sheet content. Replaces `GenreMapPanel.swift`. |
| `DJRoomba/Views/GenreTreeMap/TrunkPill.swift` / `BranchPill.swift` | Pill renderers (re-targeted from `StationLabel.swift`). |
| `DJRoomba/Views/GenreTreeMap/BranchEdge.swift` / `BackEdge.swift` | Curve / line renderers. |
| `DJRoomba/Music/GenreMap/GenreMapDiscovery.swift` | KEPT verbatim — Yen-k + 1-hop helpers + selection enum still drive the inspector. |
| `DJRoomba/Music/GenreMap/GenreMapPersistence.swift` | Phase 6's community matching kept; strand matching retired. |
| `DJRoomba/Persistence/LibraryStore+GenreMap.swift` | All Phase 5 evidence reads + Phase 6 persistence load/write kept. |
| `Vendor/ForceGraph/` | Untouched (no upstream PRs in this plan either). |

---

The plan stops being the document the next agent reads when the first
phase lands. From that point forward, the entries land in `PROGRESS.md`
and a "Ship status" block at the top of *this* file, same posture the
metro plan settled on.
