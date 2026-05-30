# DJ Roomba — Master Plan

A playlist-forward, **local-first** macOS music manager built on native
MusicKit. The user's playlist library lives in a **local SQLite database that
the app owns**; Apple Music is a one-way *import source* (read only) plus the
*playback engine*. The app manages its own playlists, play counts, and
metadata locally and never writes back to Apple / Music.app. The UI stays
playlist-forward and intentionally simple.

> **Direction changed after Milestone 2** (see `plans/architecture.md` →
> "Local-first pivot"). This supersedes the original spec's "don't build a
> local DB before browse/playback works". M1/M2 code (native MusicKit read,
> playlist UI, favorites/recents/filtering) stands and is re-pointed at the
> SQLite layer. The authoritative product spec lives in the bootstrapping
> conversation; this file + `plans/` are the durable distillation.

## Locked architecture decisions (post-pivot)

- **Identity: native MusicKit, system Apple Account** ("Option A"). No in-app
  login. User has an ADC membership; App ID `org.sockpuppet.djroomba` must
  have the MusicKit App Service enabled for real runs.
- **Local store: SQLite via GRDB** (SPM dep, added in `Package.swift`). The
  app's source of truth. Apple data is imported into it one-way.
- **Playback: native `ApplicationMusicPlayer`**, in-process. Catalog/library
  `MusicItemID`s are stored in SQLite and re-resolved to MusicKit items at
  play time. Full-track audio always goes through Apple's player (no raw
  streams, ever). Requires active Apple Music subscription.
- **No Apple library mutation.** App playlists / play counts / ratings are
  SQLite-only; never written to Apple. (Big simplification.)
- **Single-user, subscriber.** This is a personal app for its owner, who
  **is an Apple Music subscriber** — the app may assume an active Apple
  Music subscription. No preview-only / unsubscribed / upsell UX is built;
  the existing subscription gating stays only as a cheap already-built
  safety net (a lapsed/changed account degrades gracefully), not a design
  driver. See `plans/catalog-playlists.md`.

## Documentation index

| Doc | What it covers |
|-----|----------------|
| [PLAN.md](PLAN.md) | This index + product shape, milestones, key decisions |
| [PROGRESS.md](PROGRESS.md) | Canonical record: done / verified / next / open actions |
| [PROBLEMS.md](PROBLEMS.md) | **Every outstanding issue** — actionable open-issue index (severity/owner/status) |
| [APPLE-TOUCHPOINTS.md](APPLE-TOUCHPOINTS.md) | **Apple media integration boundary** — every MusicKit / iTunesLibrary API down to the call + `file:line`, with LIVE/GATED/DORMANT/PORTAL provenance; the macOS-gotcha index; what's deliberately not used (REST/JWT/MediaPlayer/AVFoundation) |
| [DESIGN-TODO.md](DESIGN-TODO.md) | Deferred Thomas'-Laws cleanup phases (B/C) + decided-against list, with freight claims & veto conditions |
| [plans/roadmap.md](plans/roadmap.md) | **Forward source of truth** — end-to-end 5-phase plan; Phase 1 = access-validation gate |
| [plans/risks-and-challenges.md](plans/risks-and-challenges.md) | **Live risk register** — every problem we're up against, with status |
| [plans/architecture.md](plans/architecture.md) | Local-first pivot layering + original M1/M2 layers, data flow, concurrency |
| [plans/data-and-import.md](plans/data-and-import.md) | GRDB/SQLite schema, import pipeline, playback resolution; **`v4`** adds 9 "free" nullable track-metadata columns (track/disc #, genres, release date, composer, ISRC, lyrics flag, work/movement) pulled from the existing import fetch — no extra Apple calls |
| [plans/catalog-playlists.md](plans/catalog-playlists.md) | **✅ ALL DONE (2026-05-20)** — Apple Music *catalog* tracks in app playlists, native MusicKit only (no REST/developer-token). Phases 0 (access gate) + 1 (ingest) + 2 (search surface) + 3 + F1a (mixed-namespace playback via sequential sub-queues) + 4 (artwork) all complete and live-verified. End-to-end: search catalog → add to app playlist → play in a mixed queue → real cover art on search rows and the now-playing bar. The architecture pre-anticipated this — schema was namespace-aware day one, resolver branch was dormant-wired, artwork actor's `Key` already discriminated namespace — so every phase landed as a clean addition, not a refactor |
| [plans/son-of-genre-map.md](plans/son-of-genre-map.md) | **Phases A–E complete on `feature/genre-tree-map` (2026-05-21, NOT merged).** Successor to the metro plan; replaces force-layout + obstacle-aware routing + corridor bundling + strand grammar with a Kruskal-MST trunk-tree view + radial-focus mode + faint back-edges. Phase E retires the metro renderer entirely (10 files deleted, ~3415 LOC) — the substrate (community detection, transferness, multi-resolution Louvain, Yen-k discovery, `song_genre` evidence reads, `v9.genreMapState` persistence) survives + powers the tree view through `GenreMapService` + `GenreTreeService`. 362/52 tests green. See plan file's "Ship status" prelude for the full per-phase breakdown. |
| [plans/genre-metro-map.md](plans/genre-metro-map.md) | **RETIRED 2026-05-21 in favour of `plans/son-of-genre-map.md`. Kept as historical record.** Phases 1–6 landed on `feature/genre-metro-map` (PR #5, NOT merged); Phase 7 (upstream patches + vendor retirement) intentionally deferred. The display layer (force layout, A* routing, corridor bundling, strand inference, the metro panel) was deleted in Phase E of the son-of-genre-map plan. The substrate (multi-channel edge scoring, multi-resolution Louvain, transferness, `song_genre` materialised view, Yen-k discovery, `v9.genreMapState`) survives + feeds the trunk-tree view. Full per-phase resolution lives in the plan file's "Ship status — 2026-05-21" prelude block. 357/54 tests green; signed build clean. Working discovery tool on the live build: hover/click/transfer-map/⇧-click compare via Yen-k, persistence across re-launch (`v9.genreMapState`). Standing user directives encoded: "scrolling is fine" and "we CANNOT reasonably visualize the entire genre space in one screen, so don't try." _Earlier history kept inline below:_ Phase-6 GATE (2026-05-21) — toms-laws A+B+C applied: (A) deleted dead `stockPalette`/`defaultColour` in `GenreMapPersistence` (renderer's `StrandSpline.colourAt` was the actual source of truth); (B) renamed `matchStrands` → `matchStrandsByMembers`, dropped `PathPair`/`consecutivePairs`/composite weights (path channel was always degenerate at this scale — docstring promised math the only caller never fed); (C) clear `lastError` at success site in `GenreMapService.build` (a persistence-write failure can't shadow a subsequent clean build). +2 tests = **357/54** green. swiftui-pro verdict: no Phase-6-introduced view-render regression (`layoutRevision` is a builder contract only). macos-design verdict on "remember last pan/zoom?": **defer** — sheets reset, atlas state belongs in a top-level `WindowGroup`; carry-forward to `DESIGN-TODO.md`. Drift spot-check on the live 115-genre library confirms positions/strand colours/community hulls preserved across Re-Analyze (`/tmp/phase6-gate-{before,after}-reanalyze.png`). **GO for Phase 7.** _Earlier:_ Phase 6 (2026-05-21) adds v9.genreMapState persistence + incremental updates: re-imports + re-launches preserve positions / community ids / strand ids / strand colours / TF-IDF label tokens. New `v9.genreMapState` migration (two additive tables — `genre_map_state(genre PK, x, y, community_coarse/medium/fine, strand_ids JSON, updated_at, revision)` + `genre_map_strand(strand_id PK, colour, label_tokens JSON, revision)`). New pure `GenreMapPersistence` module: community Jaccard ≥ 0.5 ⇒ reuse predecessor id (else mint `new-N`); strand `0.6·member + 0.4·path-pairs` ≥ 0.5 ⇒ reuse colour + label tokens. New `GenreMapBuilder.buildWithPersistence(previousState:)` entrypoint folds the matching pass + emits the persistence payload; the legacy `build` overload stays. `GenreMapForceLayout` gains `previousPositions` + `stabilityForce` (μ=0.05) — existing nodes seed from persisted (x,y) + feel a per-step `μ·(previous−current)` restoring force; new nodes scatter as before, NOT stability-anchored. `LibraryStore+GenreMap` adds `loadGenreMapState`/`writeGenreMapState` (single-tx, multi-row INSERT). `MusicController.reanalyzeGenreGraphIfEnabled` + `rebuildGenreMapIfEnabled` collapse into a single `runMapRebuildIfEnabled()` funnel (UserDefaults key `autoReanalyzeGenreGraph` preserved). +17 tests = **355/53** green; `make check`/`swift test`/`make build` clean; swiftformat + swiftlint --strict clean. Live-verified on the real 115-genre library: strand pill colours preserved across quit+relaunch + re-analyze; community hulls in the same regions; v9 tables populate 115 + 12 rows; matched community ids carry forward; persistence perf <10 ms r/w. Known limit: Phase 4's routing-actor cache is in-memory ⇒ A* re-runs on every fresh launch (rendered layout identical but routing-recompute itself unimproved); a disk-backed routing cache is a Phase 7 / post-merge candidate. **GO for Phase 7.** _Earlier:_ — Phase 5 (2026-05-21) adds the evidence + discovery UX layer: hover-a-pill ⇒ tooltip card (transferness%, track/album/artist counts, top-3 neighbours by composite weight) + 1-hop neighbour brighten + fade-non-neighbours, cosmetic-only state (no recompute on hover); click-ordinary ⇒ docked-side inspector with header / serving-strands / nearest-neighbours / representative artists+albums (paginated `song_genre` reads on `(genre, artist_key)` / `(genre, album_key)`); click-junction ⇒ above + connected-neighbourhood placenames (intersecting strand TF-IDF); click-transfer-station ⇒ **transfer-map mode** (pan+zoom plan via pure `GenreMapDiscovery.transferMapPlan`; layout edges incident to the station rise to ~30 % — the only state where dense edges are allowed); ⇧-click a second genre ⇒ **compare mode** (Yen-k shortest paths over the layout graph at cost `1 − total_weight`, k=5; transfer stations along the paths; traversed strands; shared artists / albums / tracks paginated via three new `genreMapShared*` reads). New pure `GenreMapDiscovery.swift` module (selection enum, Yen-k, helpers — `nonisolated static`, deterministic, +9 tests); new `GenreMapInspector.swift` view (pure presentational, dispatches on `.empty` / `.single(node)` / `.compare(lhs,rhs)`); `GenreMapEvidencePanel.swift` restructured into modular `EvidenceHeader` / `EvidenceNeighbours` / `EvidenceStrands` / `EvidenceRepresentative` / `EvidenceConnectedNeighbourhoods` / `EvidenceCompare` subviews; `GenreMapPanel.swift` shifts to a right-docked 340pt side-column inspector (toolbar toggle ⌘⌥I, `sidebar.trailing` glyph, `@SceneStorage` persistence) — the plan's native `.inspector()` prescription is a main-window pattern; a sheet hosts the equivalent docked-column. +16 tests = **338/50** green; `make check`/`swift test`/`make build`/`make install` clean; swiftformat + swiftlint --strict clean. Live-verified hover (Alt/BritPop tooltip: transferness 19%, 96/42/18, top-3 neighbours; surrounding pills correctly faded); workstation auto-lock interrupted the visual capture for click / transfer-map / compare, those modes are pinned by the +16 tests + closed by a pre-merge manual walkthrough. **GO for Phase 6.** _Earlier:_ — Phase-4-GATE (2026-05-21) closes out Phase 4 with the two items the REDO ship deferred: (1) 12 per-strand screenshots at `/tmp/phase4-gate-strand-NN-*.png` + `GenreMapRoutingVerifier.runIfDebug` CLEAN on every strand across 4 fresh routing passes (cold + 3 drag-relax) on the live library; (2) honest perf reconciliation — live cold ~1229 ms, drag-relax median ~1267 ms, **200 ms target re-classified to Phase 5/6 polish**, not a Phase 4 acceptance criterion. toms-laws A+B+C also landed: (A) the plan's Phase 4 success-criteria block annotated achieved-vs-aspirational; (B) `quadBezier` / `cubicBezier` De-Casteljau helpers promoted to `nonisolated static` on `StrandSpline` (three duplicates collapse to one canonical implementation); (C) `verifyStrandsClearLabels` extracted from `GenreMapRoutingActor` into a new `DJRoomba/Music/GenreMap/GenreMapRoutingVerifier.swift` file (DEBUG-only enum, one-line entry-point from the actor). Tests stable at 322/48 green. **GO for Phase 5.** _Earlier:_ Phase-4-REDO (2026-05-21) fixes the headline-criterion regression the first Phase-4 ship missed: `smoothPolyline` was replacing sharp-corner waypoints with two midpoints, drawing a diagonal cut across the corner that re-entered labels A\* had detoured around. Fix: keep the corner + insert fillet pair bracketing it; `labelPadding` 8 → 12 pt; cost-map hot path tightened. +4 tests = **320/48** green. Live-verified clean on the real library — no strand passes through a non-member label rectangle. Routing-perf is ~1.2–1.8 s on the live 12-strand × 115-station library (over the plan's 200 ms budget); flagged as a Phase-5 perf polish item, not a correctness blocker. **GO for Phase 5.** Earlier Phase 4 (also 2026-05-21) adds obstacle-aware A* routing + corridor bundling + a background routing actor. New pure modules `GenreMapRouting` (A* over 100×100 coarse grid, label/proximity/crossing penalty terms, deflection-floor smoothing) + `GenreMapBundling` (union-find corridor extraction over cell-set intersection ≥3, ±k perpendicular offset slots inside each corridor, crossing inventory with transfer-station discount). New actor `GenreMapRoutingActor` (`ArtworkProvider` shape; layoutRevision-keyed cache; `MainActor.run`-bridges the result back). Model gains `routedStrands: [Int: GenreMapRoutedStrand]` + `layoutRevision: Int`; service gains `commitDrag` (no-ops on sub-`geographicEpsilon=6.0` motion). Renderer (`StrandSpline`) prefers the routed polyline + falls back to Phase-3 Catmull-Rom during routing. +12 tests = **314/47** green. Synthetic 10-strand fixture routes inside the pinned 200 ms budget. Live-verified on the real library — splines no longer pass through label rectangles. Known polish item: Catmull-Rom self-overlap on very-sharp interior corners (left as Phase-5 / corrective). **GO for Phase 5.** _Earlier:_ — Phase-3-gate 2026-05-20 (the "stop compacting" reset) deleted the post-settle compaction pass entirely, widened the force layout hard (`worldSide` 2800 → 5000, `idealEdgeLength` 440 → 700, every restoring force scaled with it), replaced fit-to-view-on-appear with **identity-scale centred on the heaviest community** (a recognisable neighbourhood, not the world centroid), added Cmd-+/-/0/9 zoom shortcuts, and refined strand-label typography (cap-at-2-tokens, single-space join, Title Case; junk-token blacklist extended with the genre-particles `hip`/`hop`/`mor`/`aor`/`crossover`/`tribute`). Labels read as concise placenames ("Alternative Bristol", "Rap Soul", "Folk 60s") instead of token soup. **Live-verified on the real library, signed build, computer-use.** +3 tests = **302/45**. **GO for Phase 4.** _Earlier:_ Phases 1+2+3 — Phase 3 added algorithmic metro strands (`GenreMapStrandInference`: per-community heavy paths + cross-community bridges via Dijkstra over `1−weight` + member-Jaccard cull + TF-IDF labels), faint Catmull-Rom spline overlay + per-station coloured strand ticks + minimal hover affordance + materialised `song_genre` (new `v8.songGenreMaterialised` migration, three indexes ⇒ evidence-on-demand latency collapses 6–8 s → <100 ms) + strand_count fed back into transferness. Live-verified on the real library: 12 strands (the plan's upper bound) with sensible TF-IDF labels ("Alternative · Bristol · Britpop · Electronic", "Folk · 60s · 70s · Classic", …). +13 tests = 299/45. **User directive 2026-05-20**: "the whole map does not need to usefully fit on the screen all at once — scrolling is fine!" — applied as layout-widening (`worldSide` 2000 → 2800, `idealEdgeLength` 320 → 440, `compactionIterations` 40 → 16) instead of post-settle compaction polish. **GO for Phase 4** (routing + bundling). _Earlier_: Phase 1 = `v7.genreMap` schema (`genre_node` + `genre_edge_evidence` alongside the v6 `genre_edge`); pure pipeline (mutual-kNN ∪ MST layout graph + in-tree Louvain + djroomba-owned constrained force layout with label-rectangle repulsion); `Analyze Genre Map` (⌥⇧⌘A) + `Show Genre Map…` sibling actions alongside (not replacing) the v6 panel; +25 tests (262/42 green). Live-verified on the real library; lands with a known defect (candidate filter too aggressive ⇒ 41 layout edges across 115 genres ⇒ 93 over-fragmented communities + label collisions in the dense centre — carry-forward into Phase 2's first tuning pass). **Successor to the genre-graph panel** — user-specific genre *map*: constrained force geography + algorithmically-inferred metro strands + transfer stations, with individual edges revealed only on interaction. Seven phases — substrate (v7 `genre_node`/`genre_edge_evidence` + multi-channel edge scoring + sparse layout graph + multi-resolution communities + label-aware constrained force layout), structural transferness (no strands yet), strand inference (per-community MST heavy paths + cross-community bridges + algorithmic strand labels), routing + bundling (obstacle-aware splines + corridor bundling), evidence/discovery UX (hover/click/compare with on-demand evidence), persistence + incremental updates (positions + community/strand identity preserved across re-imports), and a final upstream-the-5-`DJROOMBA PATCH`es-to-`tqbf/fdg`-and-retire-the-vendor-dir phase. Supersedes the **display** layer of `genre-graph.md`; the v6 `genre_edge` table + `rebuildGenreGraph` become one input channel of the richer model |
| [plans/genre-graph.md](plans/genre-graph.md) | **The "Analyze" action + visualizer** — `v6` `genre_edge` adjacency-list table; relates genres whose tracks share a playlist; one wholesale CTE rebuild (`LibraryStore.rebuildGenreGraph`); `GenreGraphService`; menu action ⌥⌘A + default-on auto-reanalyze. Pure SQLite, no MusicKit. Rendered by a **collapsible/resizable detail-pane panel** built on `tqbf/fdg`'s `ForceGraph`, **vendored at `Vendor/ForceGraph`** (v1.0.0 commit + 5 "DJROOMBA PATCH" fixes 1–5: search-pulse redraw-pin, pan-only→zoom centring, neighbour-walk, onFocusChange callback, hub-cell crossing-detector O(E²) beachball) |
| [plans/genre-browsing.md](plans/genre-browsing.md) | **Genre browsing + top-pane Back stack** — select a genre → its tracks fill the top pane (`songsWithStats(matchingGenre:)`, synthetic `isGenre` detail, per-song playback); associations-card rows navigate to the playlist; pure unit-tested `DetailNavStack` (LIFO, cap 50) wired via the `selectedPlaylistID.didSet` choke point; Back toolbar `chevron.backward` + ⌘[. In-session only, no schema change. Live-verified |
| [plans/genre-editing.md](plans/genre-editing.md) | **Genre rename/merge + assign to selected tracks** — header "Rename" button on a browsed genre (merge is implicit: literal tag rewrite + dedupe, so renaming onto an existing name unions them); native `Table` `Set` multi-select + "Add to Genre ▸" context submenu (existing genres + "New Genre…"). Pure unit-tested `GenreEdit`; batched song-only `LibraryStore` ops (one-way isolated); no schema change; graph auto-reanalyzes |
| [plans/playlist-folders.md](plans/playlist-folders.md) | **Folders imported as playlists** — phased fix. Phase 0 ✅ (signed probe: MusicKit has *no* folder discriminator) + **Phases 1–4 ✅** (Option A `iTunesLibrary.framework`, exclude-only: classifier+8 tests, off-main folder source w/ graceful degradation, skip-before-fetch, active converge + isolation/associated-playlists tests; Phase 5 hierarchy **skipped** — optional/not requested). Signed blitz **EXECUTED & PASSED** on the real library (270→265, all 5 folders incl. "AAA ME" gone, graph de-skewed, one-way isolation held) |
| [plans/snapshot-export-import.md](plans/snapshot-export-import.md) | **`.djroomba` library snapshot** — export = `VACUUM INTO` + zlib (magic `DJRMBA01`); import = **content-merge metadata** (pure tiered `MetadataMatcher`: ISRC → music_item_id → norm(title,artist,album) → norm(title,artist)) onto matched local rows only, never blitzing playlists/history; quiet pre-import backup + Revert via GRDB online-backup into the live queue. Non-MusicKit ⇒ test/build-verifiable without a signed run |
| [plans/build-system.md](plans/build-system.md) | **mdv-cloned build env** — SwiftPM + Makefile, no Xcode IDE/xcodebuild, signing, dist pipeline |
| [plans/project-setup.md](plans/project-setup.md) | Signing, MusicKit entitlement/plist, how to build (points at build-system.md) |
| [plans/musickit-notes.md](plans/musickit-notes.md) | MusicKit-on-macOS API specifics, gotchas, identity risks |
| [plans/profiling.md](plans/profiling.md) | **Import perf investigation** — swift-profile-recorder runbook + the self-time hypotheses to test |
| [plans/memory-and-laziness.md](plans/memory-and-laziness.md) | **Residency plan (A+B done)** — killed per-`body` recompute + bounded detail cache; records why GRDB observation was rejected (single-writer) and the mutation-chokepoint forward pattern |
| [plans/recently-played.md](plans/recently-played.md) | **Recently Played** landing surface — replaces the "Select a Playlist" empty state with a keyset-paginated, lazily-scrolled distinct-songs list (built on `play_history`); + a Debug-menu synthetic-history seeder. Code-complete |
| [plans/play-statistics.md](plans/play-statistics.md) | Capped 50k numeric play history (`song.local_id`) + skip/replay counters; canonical attribution (no Apple ids as app keys); drops `play_event`. **ALL 4 phases ✅ code-complete** — Phase 1 shipped (v3 schema + store API, no gate); Phases 2–4 (canonical play context / skip-replay counting / auto-advance recording) code-complete, **signed runtime gate pending (user)**. 100 tests/18 suites green |
| [plans/AI.md](plans/AI.md) | **AI umbrella** — every AI feature in the app, posture (no ambient AI, no local models, no audio DSP), privacy + cost stance, observability index, deferred phases. Drill into the per-feature docs (today: just `openai-gpt.md`) for depth. |
| [plans/openai-gpt.md](plans/openai-gpt.md) | **OpenAI GPT integration** — Phases 0 → 1.8 all landed on `feature/openai-gpt-spike` (2026-05-29). The assistant ships as the **DJ Roomba** tab of the main window's bottom dock pane (⌥⌘\\), shared with the Genre Map tab via a segmented picker. Persistent `ContextWindow` over a separate SQLite store at `Application Support/DJRoomba/assistant.sqlite`; **13 tools** (`list_playlists`, `playlist_contents`, `track_genres`, `search_apple_music`, `recently_played`, `create_playlist`, `add_tracks_to_playlist`, `play_playlist`, `play_track`, `add_genre_to_tracks`, `rename_genre`, `sql_query` (read-only SELECT against `library.sqlite`), `app_state`). Multi-conversation sidebar with hash-keyed avatar discs + swipe-/right-click-to-delete, **New Request** archives + summarizes via **`gpt-5.4-mini`**, conversations + titles + current-pointer persisted across relaunches. Main chat model is **`gpt-5.4`** on **`service_tier: "flex"`** (cheaper / higher-latency tier — not latency-sensitive). Vendored `contextwindow-swift` carries `DJROOMBA PATCH 1` (multi-turn tool_call_id) + `DJROOMBA PATCH 2` (service_tier field). Tool-call transcript rows are a togglable subtle checkbox. See `PROGRESS.md` 2026-05-29 entries (six top-of-file blocks). **Library now vendored** at `Vendor/contextwindow-swift` with `DJROOMBA PATCH 1` — `OpenAIChatModel.message(for:)` lost `tool_call_id` on `.toolOutput` records, breaking every multi-turn conversation with HTTP 400; replaced with a sequential walker that pairs each output to its preceding call. **Unified logging** (subsystem `org.sockpuppet.djroomba`, category `openai`) records every user / tool / assistant turn so conversations can be replayed with `log show` instead of screenshots. "Signin" reality: OpenAI has no OAuth → key flow for desktop apps, so the user pastes a key into a `SecureField`; the pane's footer says so. Phase 2+ (streaming, model picker, richer surface) still deferred. |
| [plans/typography.md](plans/typography.md) | Semantic-font type system + hierarchy rules |
| [plans/milestone-1.md](plans/milestone-1.md) | _Historical_ — original "Play a library playlist" notes |
| [plans/milestone-2.md](plans/milestone-2.md) | _Historical_ — original "Make it pleasant" notes |

> For a future agent: read `PLAN.md` then `PROGRESS.md`. That is enough to
> resume. Drill into `plans/*` for specifics on whatever you're touching.

## Product shape

Four persistent conceptual regions, mapped to the macOS layout formula:

```
+---------------------------------------------------------------+
| Toolbar: Search filter | Refresh | (Settings)                 |  <- ~50px drag zone
+----------------------+---------------------+------------------+
| Playlist sidebar     | Playlist detail     | Extension        |
| (NavigationSplitView | (boring Table of     | inspector       |
|  sidebar column)     |  tracks)            | (.inspector,    |
|                      |                     |  collapsed by   |
|                      |                     |  default)       |
+----------------------+---------------------+------------------+
| Now Playing bar: artwork | title - artist | transport         |  <- safeAreaInset, always visible
+---------------------------------------------------------------+
```

- **Playlists first.** App never opens into catalog search.
- **One obvious primary action per screen** (Play).
- **SQLite owns library + app data.** MusicKit owns the live player/queue
  only. The app owns imported snapshot, app playlists, play counts, favorites,
  recents, layout — *all in SQLite*.
- **Catalog search is subordinate** and deferred.

## Milestones (recast for local-first)

1. **Play a library playlist** ✅ code-complete; auth runtime-verified.
   Native MusicKit read → sidebar → select → tracks → play / double-click →
   now-playing. (Auth confirmed live; playlist/playback signing-gated.)
2. **Make it pleasant** ✅ code-complete & build-verified. Favorites, recents,
   filtering, persisted selection/sidebar state, keyboard shortcuts, states.
   *(Favorites/recents currently UserDefaults — migrate into SQLite in M3.)*
3. **Local store + import pipeline** ✅ code-complete (Phase 2 store +
   Phase 3 import/UI-on-SQLite + the Phase 3 **corrective**); signed
   runtime re-gate pending the orchestrator. GRDB + schema (Phase 2);
   `ImportService` (one-way MusicKit→SQLite, stores the underlying Song's
   **library** id by provenance), sidebar/detail re-pointed at the DB,
   favorites/recents migrated one-shot into SQLite, `PlaybackResolver`
   re-resolves stored library ids via `MusicLibraryRequest` at play time,
   artwork re-resolved by id through `ArtworkProvider` + `ArtworkImage`,
   batched SQLite import (UPSERT + IN-list lookup + chunked membership).
   The signed gate caught 3 defects (broken id round trip, placeholder
   artwork, ~90s row-by-row import); all corrected in code — see PROGRESS.md
   top entry. `make check` + `swift test` (**35**) green. Signing uses the
   Phase-1 Apple Development cert directly (no Xcode-Accounts step).
4. **App-owned playlists + play counts.** ✅ code-complete; signed gate ran
   (core PASSED) + UI corrective applied; signed re-gate pending.
   Create/rename/delete/reorder/add/remove app playlists (SQLite only, batch
   idioms, one-way isolated, no schema change); native "My Playlists" sidebar
   section distinct from imported "Library Playlists"; per-song 1:1
   app-playlist re-resolution; play-tracking fixed (fires on the player's
   confirmed start), surfaced as sortable track-table columns. The signed
   gate confirmed the core works but caught 4 UI defects (inline rename;
   phantom Table rows; stale sidebar count; stale Plays/Last Played) — all
   root-caused + fixed as view/reactivity-only changes (see the Phase-4 UI
   CORRECTIVE PROGRESS.md top entry). `make check`/`swift test` (51/11)
   green; signed build produced; not committed.
5. **Polish + extension readiness.** ✅ code-complete; signed gate pending.
   `MusicContext` boundary realized as a real collapsible native
   `.inspector()` (collapsed by default, toolbar toggle, observes the
   read-only context / acts only via `MusicCommand`, never touches the
   player); cause-inferred empty states ("Library Not Synced to This Mac" vs
   "Subscription Needed" vs "No Playlists Yet" vs error — pure, unit-tested
   `LibrarySidebarState` cross-checking `MusicSubscription`); auto-start
   polish (Play reliably begins playing, no transport nudge; recording not
   regressed); edge hardening (rapid switching / disappeared playlist /
   unplayable track / network-down — tested where deterministic); honest
   import-cost finding (full re-import of a ~270-playlist / ~8200-track
   library is ~90–120 s, dominated by MusicKit's per-playlist track
   resolution on macOS — *not* SQLite, *not* reducible by app-side
   parallelism; the bounded-parallel attempt was measured ineffective and
   reverted to the simple serial loop, keeping only the "Importing N of M
   playlists…" progress affordance; accepted as the one-time/Refresh v1
   cost); +16 tests (67/14 green); final swiftui-pro/macos-design/typography
   pass. Catalog search + incremental import documented as deliberately
   deferred. Distribution pipeline reviewed (nothing notarized by the
   agent). See PROGRESS.md top entry for the exact remaining USER steps to
   ship, plus the Phase-5 CORRECTIVE entry (title/inspector/import fixes,
   including the deeper window-sizing root cause: the hard outer
   `.frame(minWidth:)` clamp on the split-view-bearing `WindowGroup` root
   removed in favor of a content-derived window minimum via
   `.windowResizability(.contentSize)`, so the inspector no longer clips at
   either window edge and state restoration can't pin a too-narrow frame).

## Key design decisions

- **Tooling:** mdv-cloned build env — SwiftPM (`Package.swift`) + `build.sh`
  + `Makefile`; **no Xcode IDE, no xcodebuild, no XcodeGen**. Xcode is only a
  toolchain provider, used solely by `make dist`. See
  [plans/build-system.md](plans/build-system.md).
- **Code style:** Airbnb Swift Style Guide, enforced by `swiftformat`
  (`.swiftformat`) + `swiftlint` (`.swiftlint.yml`), Airbnb canonical
  configs. Apply the global `airbnb-swift-style` skill (+ `swiftui-pro`)
  when writing/reviewing Swift; see the 2026-05-15 style-pass PROGRESS
  entry. Formatting is `[AUTO]` (run `swiftformat`); judgment rules are
  manual.
- **Min target:** macOS 14 Sonoma. Built with Xcode 26.4 / Swift 6.3.
- **Identity:** App "DJ Roomba", bundle `org.sockpuppet.djroomba`, team
  KK7E9G89GW (Thomas Ptacek), automatic signing.
- **State:** `@Observable @MainActor` model layer; `@State` ownership at root,
  `@Environment` to pass down. No `ObservableObject`/`@Published`. No
  `@AppStorage` inside `@Observable` classes (does not trigger updates).
- **Navigation:** `NavigationSplitView` (sidebar + detail) + `.inspector()`
  (macOS 14) for the extension surface + `safeAreaInset(edge: .bottom)` for the
  persistent now-playing bar.
- **Track list:** native SwiftUI `Table` — deliberately boring, operational.
- **Concurrency:** Swift structured concurrency only. No GCD.
- **MusicKit wrapper stays thin** — debuggability over abstraction.

## Observability

The assistant boundary is fully traced via Apple's unified-logging
subsystem so conversations can be inspected programmatically — no
screenshots required. One `Logger` (`os.Logger`) under
`subsystem = org.sockpuppet.djroomba`, `category = openai` covers:

- `→ user: …` and `← assistant: …` — chat turn boundaries (`.info`)
- `→ tool name args=…` and `← tool name out=…` — every tool call + its
  output, output truncated to ~600 chars (`.info`, so they persist to disk)
- `! …` — anything that broke a round trip (`.error`)

Read it with the `log` CLI:

```sh
# Live stream:
log stream --predicate \
  'subsystem == "org.sockpuppet.djroomba" AND category == "openai"' \
  --info --debug

# Replay the last N minutes:
log show --predicate \
  'subsystem == "org.sockpuppet.djroomba" AND category == "openai"' \
  --info --last 5m
```

The API key is never logged; the full system prompt is never logged;
tool outputs are truncated. See `AssistantLog.swift` for the helpers
and `LoggedToolRunner` for the per-tool wrapper.

## Hard constraints (from CLAUDE.md)

- Keep `PLAN.md` (index), `plans/*.md` (depth), `PROGRESS.md` (status) current.
- Consult `swiftui-pro` before and after deciding on code.
- Consult `typography-designer` when setting type.
- Consult `macos-design` for UI idioms; keep it simple.
- May push PRs; **must never merge to `main`**.

## Non-goals

No local audio engine. No decoding protected streams. No Music.app clone. No
catalog-search-centric UX. No heavy local DB before browse+playback work. No
visualizers / audio taps / EQ / waveform analysis.
