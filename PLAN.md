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
| [DESIGN-TODO.md](DESIGN-TODO.md) | Deferred Thomas'-Laws cleanup phases (B/C) + decided-against list, with freight claims & veto conditions |
| [plans/roadmap.md](plans/roadmap.md) | **Forward source of truth** — end-to-end 5-phase plan; Phase 1 = access-validation gate |
| [plans/risks-and-challenges.md](plans/risks-and-challenges.md) | **Live risk register** — every problem we're up against, with status |
| [plans/architecture.md](plans/architecture.md) | Local-first pivot layering + original M1/M2 layers, data flow, concurrency |
| [plans/data-and-import.md](plans/data-and-import.md) | GRDB/SQLite schema, import pipeline, playback resolution; **`v4`** adds 9 "free" nullable track-metadata columns (track/disc #, genres, release date, composer, ISRC, lyrics flag, work/movement) pulled from the existing import fetch — no extra Apple calls |
| [plans/catalog-playlists.md](plans/catalog-playlists.md) | **Planned** — add Apple Music *catalog* tracks to app playlists. Native MusicKit only (**no web service / developer token / REST**); needs the MusicKit App Service enabled on the App ID (portal step spelled out). Schema is already namespace-aware + resolver branch dormant-wired ⇒ clean addition. Phased, signed-gated. Assumes an Apple Music subscription |
| [plans/genre-graph.md](plans/genre-graph.md) | **The "Analyze" action + visualizer** — `v6` `genre_edge` adjacency-list table; relates genres whose tracks share a playlist; one wholesale CTE rebuild (`LibraryStore.rebuildGenreGraph`); `GenreGraphService`; menu action ⌥⌘A + default-on auto-reanalyze. Pure SQLite, no MusicKit. Rendered by a **collapsible/resizable detail-pane panel** built on `tqbf/fdg`'s `ForceGraph`, **vendored at `Vendor/ForceGraph`** (v1.0.0 commit + 5 "DJROOMBA PATCH" fixes 1–5: search-pulse redraw-pin, pan-only→zoom centring, neighbour-walk, onFocusChange callback, hub-cell crossing-detector O(E²) beachball) |
| [plans/genre-browsing.md](plans/genre-browsing.md) | **Genre browsing + top-pane Back stack** — select a genre → its tracks fill the top pane (`songsWithStats(matchingGenre:)`, synthetic `isGenre` detail, per-song playback); associations-card rows navigate to the playlist; pure unit-tested `DetailNavStack` (LIFO, cap 50) wired via the `selectedPlaylistID.didSet` choke point; Back toolbar `chevron.backward` + ⌘[. In-session only, no schema change. Live-verified |
| [plans/playlist-folders.md](plans/playlist-folders.md) | **Folders imported as playlists** — phased fix. Phase 0 ✅ (signed probe: MusicKit has *no* folder discriminator) + **Phases 1–4 ✅** (Option A `iTunesLibrary.framework`, exclude-only: classifier+8 tests, off-main folder source w/ graceful degradation, skip-before-fetch, active converge + isolation/associated-playlists tests; Phase 5 hierarchy **skipped** — optional/not requested). Signed blitz **EXECUTED & PASSED** on the real library (270→265, all 5 folders incl. "AAA ME" gone, graph de-skewed, one-way isolation held) |
| [plans/build-system.md](plans/build-system.md) | **mdv-cloned build env** — SwiftPM + Makefile, no Xcode IDE/xcodebuild, signing, dist pipeline |
| [plans/project-setup.md](plans/project-setup.md) | Signing, MusicKit entitlement/plist, how to build (points at build-system.md) |
| [plans/musickit-notes.md](plans/musickit-notes.md) | MusicKit-on-macOS API specifics, gotchas, identity risks |
| [plans/profiling.md](plans/profiling.md) | **Import perf investigation** — swift-profile-recorder runbook + the self-time hypotheses to test |
| [plans/memory-and-laziness.md](plans/memory-and-laziness.md) | **Residency plan (A+B done)** — killed per-`body` recompute + bounded detail cache; records why GRDB observation was rejected (single-writer) and the mutation-chokepoint forward pattern |
| [plans/recently-played.md](plans/recently-played.md) | **Recently Played** landing surface — replaces the "Select a Playlist" empty state with a keyset-paginated, lazily-scrolled distinct-songs list (built on `play_history`); + a Debug-menu synthetic-history seeder. Code-complete |
| [plans/play-statistics.md](plans/play-statistics.md) | Capped 50k numeric play history (`song.local_id`) + skip/replay counters; canonical attribution (no Apple ids as app keys); drops `play_event`. **ALL 4 phases ✅ code-complete** — Phase 1 shipped (v3 schema + store API, no gate); Phases 2–4 (canonical play context / skip-replay counting / auto-advance recording) code-complete, **signed runtime gate pending (user)**. 100 tests/18 suites green |
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
