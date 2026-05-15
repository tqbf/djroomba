# Typography system

Principles (typography-designer + macos-design + swiftui-pro):

- **Use SwiftUI semantic fonts, never hardcoded point sizes.** Semantic styles
  (`.largeTitle`, `.body`, `.caption`…) map to Apple's native macOS scale
  (Body ≈ 13pt, Caption ≈ 11pt) *and* get Dynamic Type for free.
- **De-emphasize with color (`.secondary`/`.tertiary`), not lighter weight.**
- **Weight is used sparingly** — `.semibold`/`.bold` only for titles and the
  now-playing track title. Everything else is regular. Hierarchy comes from
  size + color, not a soup of weights.
- **Numeric columns/timers use `.monospacedDigit()`** so they don't jitter.

| Role | Font | Weight | Color | Where |
|------|------|--------|-------|-------|
| App / auth title | `.largeTitle` | `.semibold` | primary | AuthorizationView |
| Auth body | `.body` | regular | `.secondary` | AuthorizationView |
| Sidebar section header | (List `Section` default) | — | secondary | PlaylistSidebar |
| Sidebar playlist name | `.body` | regular | primary | PlaylistSidebarRow |
| Sidebar secondary line | `.caption` | regular | `.secondary` | PlaylistSidebarRow |
| Detail title | `.largeTitle` | `.bold` | primary | PlaylistHeaderView |
| Detail metadata | `.subheadline` | regular | `.secondary` | PlaylistHeaderView |
| Table cell — title | `.body` | regular | primary | TrackTableView |
| Table cell — artist/album | `.body` | regular | `.secondary` | TrackTableView |
| Table cell — #/duration | `.body` + `.monospacedDigit()` | regular | `.secondary` | TrackTableView |
| Now-playing title | `.subheadline` | `.semibold` | primary | NowPlayingBar |
| Now-playing artist | `.caption` | regular | `.secondary` | NowPlayingBar |
| Now-playing time | `.caption2` + `.monospacedDigit()` | regular | `.secondary` | NowPlayingBar |
| Empty/error state | `ContentUnavailableView` | (built-in) | — | sidebar/detail |

Durations/elapsed render via `Duration`/`Date.FormatStyle` or a small helper —
never `String(format:)` (swiftui-pro Swift rule).
