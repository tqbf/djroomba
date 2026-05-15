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
- **Local store: SQLite via GRDB** (SPM dep, added through XcodeGen). The
  app's source of truth. Apple data is imported into it one-way.
- **Playback: native `ApplicationMusicPlayer`**, in-process. Catalog/library
  `MusicItemID`s are stored in SQLite and re-resolved to MusicKit items at
  play time. Full-track audio always goes through Apple's player (no raw
  streams, ever). Requires active Apple Music subscription.
- **No Apple library mutation.** App playlists / play counts / ratings are
  SQLite-only; never written to Apple. (Big simplification.)

## Documentation index

| Doc | What it covers |
|-----|----------------|
| [PLAN.md](PLAN.md) | This index + product shape, milestones, key decisions |
| [PROGRESS.md](PROGRESS.md) | Canonical record: done / verified / next / open actions |
| [plans/roadmap.md](plans/roadmap.md) | **Forward source of truth** — end-to-end 5-phase plan; Phase 1 = access-validation gate |
| [plans/risks-and-challenges.md](plans/risks-and-challenges.md) | **Live risk register** — every problem we're up against, with status |
| [plans/architecture.md](plans/architecture.md) | Local-first pivot layering + original M1/M2 layers, data flow, concurrency |
| [plans/data-and-import.md](plans/data-and-import.md) | GRDB/SQLite schema, import pipeline, playback resolution |
| [plans/project-setup.md](plans/project-setup.md) | XcodeGen project, signing, MusicKit entitlement/plist, how to build |
| [plans/musickit-notes.md](plans/musickit-notes.md) | MusicKit-on-macOS API specifics, gotchas, identity risks |
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
3. **Local store + import pipeline** ← *next*. Add GRDB; SQLite schema;
   `ImportService` (MusicKit read → one-way upsert into SQLite); re-point the
   sidebar/detail at the DB; move favorites/recents into SQLite; playback
   resolves stored `MusicItemID`s → MusicKit items at play time. Switch
   project back to automatic signing (user wires Apple ID into Xcode).
4. **App-owned playlists + play counts.** Create/rename/delete/reorder app
   playlists (SQLite only, never written to Apple); "My Playlists" section
   distinct from imported "Library Playlists"; play-count + last-played
   tracking incremented on play, surfaced in the track table.
5. **Polish + extension readiness.** `MusicContext` boundary + collapsible
   inspector (deferred from old M3); smarter empty states (e.g. "library not
   synced to this Mac" hint); the standing unit-test gap (GRDB stores,
   import, filtering); optional catalog search as an import affordance.

## Key design decisions

- **Tooling:** XcodeGen (`project.yml` in git, `.xcodeproj` generated, gitignored).
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
