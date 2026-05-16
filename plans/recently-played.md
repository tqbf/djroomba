# Recently Played — lazy landing surface

The detail pane's old "Select a Playlist" empty state is replaced, when no
playlist is selected, by a **scrollable, lazily-paginated list of the
user's recently-played songs** (distinct songs, newest play first). Built
on the Phase-1–4 play-statistics model (`play_history`).

## Semantics (decided)

- **Distinct songs, ordered by each song's most-recent play, newest
  first.** A song played many times appears once, at its latest position
  — the conventional "Recently Played" browse list, not the raw repeated
  history vector (`recentlyPlayedSongIDs` still exists for the raw vector;
  this is a different, UI-facing read). Easy to switch to raw if wanted
  (one query).

## Store

`LibraryStore.recentlyPlayedPage(beforeSeq:limit:) -> [RecentlyPlayedSong]`
(`{ song, lastSeq, playCount, lastPlayedAt }`):
`… FROM play_history h JOIN song s ON s.local_id = h.song_local_id LEFT
JOIN song_stat … GROUP BY h.song_local_id [HAVING MAX(h.seq) < :beforeSeq]
ORDER BY last_seq DESC LIMIT :limit`. **Keyset**, not OFFSET — cursor =
the last row's `lastSeq`, passed as the next page's `beforeSeq`. `seq` is
the `play_history` AUTOINCREMENT PK (monotonic, never reused), so the
distinct set has no dup/gap across pages for an unchanged history; a new
play only mints a higher seq. One by-design eventual-consistency nuance:
a song *already paginated* then replayed mid-scroll floats above the live
cursor — it isn't re-emitted in a later page and its rendered row stays
put until a `reload()` (documented at the method; not a gap in the
distinct set). `GROUP BY` is over ≤`playHistoryCap` (50k) integer-PK
rows — cheap.

`seedRandomPlayHistory(count:) -> Int` (debug): one transaction — pick up
to `count` random songs that are members of some playlist, mirror
`recordPlay`'s per-row work (resolve `local_id`, upsert `song_stat`,
append `play_history`), prune once at the end. Returns `min(count,
available)` (0 if no playlist songs). Faithful to `recordPlay` so
`song_stat` can't drift.

## View / view-model

- `RecentlyPlayedService` (`@MainActor @Observable`, on `MusicController`
  alongside `detailService`): keyset pager. `rows`/`isLoading`/`loadError`
  /`hasMore` observable; `cursor`/`loadTask`/`pageSize`(50)/
  `prefetchDistance`(10)/`loadGeneration` `@ObservationIgnored`. **Not**
  coupled to the 0.5 s now-playing tick (never reads `playback`). A
  **monotonic `loadGeneration`** makes cancel-and-replace safe — a
  superseded in-flight page can't clobber the replacement's
  `loadTask`/`isLoading` (mirrors `PlaylistDetailService`'s
  `revisionCounter`). `loadMoreIfNeeded` checks only `rows.suffix(
  prefetchDistance)` (O(constant) per appearing row — not an O(rows)
  scan, so a long scroll isn't O(n²)).
- `RecentlyPlayedView` + `RecentlyPlayedRow`: native `List`
  (`.bordered(alternatesRowBackgrounds:)`, like the track table),
  44 pt `ArtworkThumbnail` + title/`artist • album`/relative last-played
  — **zero new type roles** (reuses `PlaylistHeaderView` /
  `TrackTableView` tiers). Loading / error+Retry / "No Recently Played"
  empty states. Lazy via each row's `.onAppear` →
  `loadMoreIfNeeded`. `.task` loads page 1 **only when empty** — returning
  from a playlist must not reset scroll/paging; a real data change
  re-shows via the explicit `reload()` path (seed).
- `PlaylistDetailView`: the no-selection branch (and the unreachable
  fallback) render `RecentlyPlayedView()`; loading/error/selected/empty
  branches unchanged.

## Playback

`MusicController.playRecentlyPlayed(startAt:)` reuses the **app-playlist**
resolution path (`resolver.resolveAppPlaylist` over `recentlyPlayed.rows`)
through a new shared private `startResolvedQueue(_:contextID:beforePlay:)`
— `resolveAndPlay` was refactored onto the same helper rather than
duplicating the **load-bearing ordering invariant** (no `await` between
the atomic `ActivePlayContext` set+Phase-4 seed and the synchronous
`player.queue` swap). `recordPlayStart` split into a shared core +
playlist wrapper (the wrapper still refreshes detail stats). Playing from
this surface itself records plays (Phases 1–4), so the list dogfoods
itself. No Apple id is ever a key (architecture principle).

## Debug

`CommandMenu("Debug")` → "Seed 500 Random Plays" →
`MusicController.seedSyntheticHistory(count:)` →
`store.seedRandomPlayHistory` then `recentlyPlayed.reload()`. Not
`#if DEBUG`-gated (the user's `make` build is debug-config and wants the
button); clearly labeled under "Debug".

## Status

Code-complete; `swift build` clean, **107 tests / 19 suites** green
(`RecentlyPlayedTests`: distinct/newest-first, cross-boundary keyset,
re-float, empty, seeder member-only/min-count/zero/accumulate+cap),
`swiftformat`/`swiftlint` 0. Cleanup gate (R6 + swiftui-pro/macos-design/
typography) applied: fixed a `loadTask` teardown race (→ generation
token), an O(n²) scroll scan (→ tail check), and a `.task`
reload-on-reappear that lost scroll position; the `resolveAndPlay`
refactor's invariant was independently verified to still hold. Live
computer-use validation: see PROGRESS.md.
