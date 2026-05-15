# DJ Roomba — Master Plan

A playlist-forward macOS music player built on MusicKit. Not a Music.app clone:
the user's Apple Music **library playlists** are the home screen, playlist
selection is the primary navigation action, and playback flows from playlists
into a persistent now-playing surface. Intentionally simple, designed to become
an extension point for other apps.

The authoritative product spec lives in the conversation that bootstrapped this
repo; this document and the files in `plans/` are the durable distillation.

## Documentation index

| Doc | What it covers |
|-----|----------------|
| [PLAN.md](PLAN.md) | This index + product shape, milestones, key decisions |
| [PROGRESS.md](PROGRESS.md) | Running log of what is done / in flight / next |
| [plans/architecture.md](plans/architecture.md) | Module layout, model/service/view layers, data flow, concurrency |
| [plans/project-setup.md](plans/project-setup.md) | XcodeGen project, signing, MusicKit entitlement/plist, how to build |
| [plans/milestone-1.md](plans/milestone-1.md) | "Play a library playlist" — detailed implementation notes |
| [plans/musickit-notes.md](plans/musickit-notes.md) | MusicKit-on-macOS API specifics, gotchas, identity risks |
| [plans/typography.md](plans/typography.md) | Semantic-font type system + hierarchy rules |

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
- **MusicKit owns playback + queue state.** The app owns favorites, recents,
  selection, layout, and extension context — *app state, not music state*.
- **Catalog search is subordinate** and deferred to Milestone 4.

## Milestones

1. **Play a library playlist** ✅ code-complete & build-verified (runtime
   playback unverified — signing-gated; see PROGRESS.md). Auth → load library playlists →
   sidebar → select → lazy-load tracks → Play / double-click track → now-playing
   bar reflects state. No catalog search, editing, or queue editor.
2. **Make it pleasant.** Favorites, recently played, playlist + track filtering,
   persisted selection/window state, keyboard shortcuts, good empty/error states.
3. **Extension readiness.** `MusicContext` boundary, collapsible inspector,
   publish selected playlist/track/now-playing/playback without letting
   extensions touch `ApplicationMusicPlayer` directly.
4. **Catalog & library mutation.** Catalog search, add-to-library, playlist
   creation/edit. Only after the player is solid.

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
