# Milestone 2 — Make it pleasant

## Scope (from spec "Second Milestone")

- Favorites section.
- Recently played playlists.
- Playlist filtering.
- Track filtering inside the selected playlist.
- Persist selected playlist. *(already done in M1)*
- Persist window / sidebar state.
- Add keyboard shortcuts.
- Improve empty / loading / error states.

## Design calls

- **Filtering uses `.searchable`** (Apple's standard sidebar/content search,
  per macos-design). Sidebar `.searchable` filters playlists; detail
  `.searchable` filters that playlist's tracks. ⌘F focuses the search field of
  the focused column automatically — no custom key handling needed. Matching
  uses `localizedStandardContains` (swiftui-pro Swift rule).
- **Favorites / Recents are app state**, not music state. `FavoritesStore`
  (a `Set<String>` of playlist id rawValues) and `RecentlyPlayedStore` (capped
  ordered list) back onto `UserDefaults`. They are *not* `@Observable`
  (UserDefaults can't live in an `@Observable` per swiftui-pro data rule);
  `MusicController` holds the observable mirror and writes through.
- **Sidebar sections**: Favorites → Recently Played → Library Playlists.
  Sections only appear when non-empty. Favoriting is a row context-menu action
  with a star indicator (keeps the row uncluttered; macos-design progressive
  disclosure).
- **Recents are recorded when playback starts from a playlist** (controller
  intent), not on mere selection — "recently played", not "recently viewed".
- **Window/sidebar state**: sidebar column visibility persists via
  `@SceneStorage` in the view layer (never `@AppStorage`/scene state inside an
  `@Observable`). Window frame relies on macOS automatic state restoration.

## Keyboard shortcuts (spec required set)

| Key | Action | Status |
|-----|--------|--------|
| Space | Play/pause | done (M1) |
| ⌘R | Refresh playlists | done (M1) |
| ⌘← / ⌘→ | Previous / Next | done (M1) |
| ⌘F | Focus filter | `.searchable` (automatic) |
| Return | Play selected playlist (sidebar) / track (table) | sidebar added here; table done M1 |
| ⌘L | Focus playlist sidebar | added here |
| Arrows | Navigate sidebar/table | native to List/Table |
| ⌘1 | Playlists | added here (focus sidebar column) |
| ⌘2 | Queue | **deferred** — no queue surface until M3+ |
| ⌘I | Toggle extension inspector | **deferred** — M3 |

## Out of scope (later milestones)

Queue editor/view, extension inspector contents, catalog search, mutation.

## Verification

`xcodebuild ... CODE_SIGNING_ALLOWED=NO build` clean; post-code `swiftui-pro`
pass; update PROGRESS.md. Runtime still signing-gated (see project-setup.md) —
report honestly, do not claim verified playback/persistence behavior.
