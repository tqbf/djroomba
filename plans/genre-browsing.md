# Genre browsing + top-pane navigation stack

Three linked navigation affordances over the existing genre graph + top
pane. Local-first / no MusicKit / no schema change (reuses the v4
`song.genre_names` JSON column and the existing detail/selection plumbing).

## What it does

1. **Select/center a genre → its tracks fill the top pane.** Clicking a
   genre node (or search-Return / neighbour-walk *commit* — the engine's
   *committed* selection, not a hover/preview) shows that genre's songs in
   the same Table the playlist detail uses, titled with the genre name.
2. **Click a playlist in the graph's associations card → go to it.** The
   corner card's rows are buttons; tapping one navigates the top pane to
   that imported/app playlist and highlights it in the sidebar.
3. **Back stack.** A per-session LIFO of top-pane destinations (playlist /
   genre). A leading toolbar `chevron.backward` (+ ⌘[) returns to the
   previous destination; disabled when empty.

## Design (as built)

### Store — `LibraryStore.songsWithStats(matchingGenre:)`

One `dbQueue.read`. Mirrors the private
`songsWithStats(joining:playlistColumn:_:)` SELECT + `SongWithStat`
mapping, and the `associatedPlaylists` genre-match idiom
(`json_each(s.genre_names)` + `json_valid` + `TRIM(je.value) = ?`). A
`LEFT JOIN song_stat` carries play-count/last-played; `EXISTS` over
`json_each` so a song is returned **once** even with multiple genres;
`ORDER BY title COLLATE NOCASE, artist_name COLLATE NOCASE` (a genre has
no intrinsic order, unlike a playlist's `position`). **No migration** —
`genre_names` is the existing v4 column.

### Detail — synthetic genre `PlaylistDetail`

`PlaylistDetail` gains a defaulted `var isGenre = false` (non-breaking).
`PlaylistDetailService.selectGenre(_:)` mirrors `select`'s task/cancel and
`load`'s mapping, producing `PlaylistDetail(id: "genre:<name>",
name: <genre>, isAppleLibraryPlaylist: false, source: <app-owned>,
isEditable: false, tracks:…, isGenre: true)`. App-owned `source` routes
playback through the proven per-song `resolveAppPlaylist` path (a genre is
an arbitrary song set with no backing Apple playlist — same shape as an
app playlist for resolution). It is **not** LRU-cached (the cache is keyed
for real playlists; a `genre:` id must not collide), **not** favoritable
or editable, and its `artworkRef` stays nil (native placeholder).

### Navigation — `DetailNavStack` + the `selectedPlaylistID` choke point

`DetailNavStack` (pure, `Equatable`, unit-tested in isolation because the
`@MainActor @Observable` controller can't be built in a unit test):
`DetailDestination` = `.playlist(String)` | `.genre(String)`; `push`
ignores nil (the Recently-Played landing is *absence*, never a case) and a
no-op repeat, caps at 50 (oldest dropped); `pop` is LIFO, underflow → nil.

`MusicController` keeps `selectedPlaylistID` **stored** (least-risk — many
call sites + persistence + restore + play depend on its `didSet`). The
`didSet` is the single integration point: on a *user* change
(`!suppressNavRecording`) it pushes the **pre-change** destination
(`selectedGenre`→`.genre` else `oldValue`→`.playlist`) and clears
`selectedGenre` (a playlist pick exits a genre). `showGenre` / `goBack` /
`restoreSelection` wrap their `selectedPlaylistID` writes in
`suppressNavRecording = true/false` so Back and launch-restore replay
record no phantom history and don't re-clear genre. `currentDestination`
= genre-then-playlist projection. The stack is **in-memory only** — never
persisted; history is per launch. `handleSelectionChange` (hence
`preferences.lastSelectedPlaylistID` + `detailService.select`) runs
unchanged for every assignment, so persistence/restore are untouched.

`openAssociatedPlaylist(id:)` is just an ordinary playlist navigation
(sets `selectedPlaylistID`, or re-drives if already selected). Genre
playback skips the recents bump (`recordRecentlyPlayed` gated by
`!detail.isGenre`) so the `genre:` sentinel never enters `recent_playlist`;
song play-stats (`recordPlayStart`) still count.

### Views

- `GenreGraphContent`: `.onChange(of: selectedGenre)` (the **committed**
  `ForceGraphView(selection:)` binding — not `onFocusChange`/preview) →
  `controller.showGenre`. Card gets an `onOpen` closure →
  `controller.openAssociatedPlaylist`.
- `GenreAssociationsCard`: each row a `Button(.plain)` with a full-row
  `.contentShape`; container `.contain` (was `.combine`) so rows stay
  individually VoiceOver-focusable. Layout/typography unchanged.
- `PlaylistDetailView`: the Recently-Played landing shows only when
  `selectedPlaylistID == nil && selectedGenre == nil`; a genre falls
  through to the existing loading/error/detail rendering. "Try Again"
  re-runs `selectGenre` for a genre.
- `PlaylistHeaderView`: `isGenre` → genre-name title, reused
  `^[n track](inflect:)` subtitle, genre placeholder glyph, Play kept,
  favorite/edit affordances absent. No new type styles (semantic scale
  reused).
- `MainShellView`: leading `.navigation` `Button(chevron.backward)`,
  `.keyboardShortcut("[", .command)`, `.disabled(!controller.canGoBack)`,
  help/aXLabel "Back".

## Tests

- `GenreSongsQueryTests` (×5): exact-match-once-ordered, dedup across
  multiple genre entries, play-stat join, invalid/NULL `genre_names`
  ignored, unknown genre → empty.
- `DetailNavStackTests` (×6): push/pop LIFO, nil never recorded, repeat of
  top not recorded, pop underflow nil, cap-at-capacity drops oldest.

166 tests / 27 suites green; build clean; lint 0. Live signed-build
computer-use verified all three behaviors + sidebar/restore regression +
no PATCH-5 regression. **Not committed.**

## Follow-on: a playlist's genres in its header

The inverse of (1): when a *playlist* is shown, its header surfaces the
distinct genres of its tracks as a quiet, tappable capsule strip (between
the "N tracks" subtitle and Play). Derived — **no new store query, no
schema change**: `PlaylistDetail.genreTally(_ songs:)` (pure,
unit-tested — trim/drop-empty/dedupe-within-song, sort by count desc then
localized case-insensitive name) runs in `PlaylistDetailService.load` over
the already-fetched `withStats.map(\.song)`; `refreshStats` carries it
over (membership unchanged); a genre detail gets `[]`. Stored as the
defaulted `PlaylistDetail.genres`. `PlaylistHeaderView.genreStrip` is a
single hidden-indicator horizontal `ScrollView` of `.caption`/`.secondary`
`.quaternary`-capsule `.plain` buttons (matches `GenreAssociationsCard`,
no new type styles, header never grows); each chip →
`controller.showGenre`, reusing the Back-stack nav above. Tests:
`PlaylistGenresTests` ×8. Live-verified (2-Tone → chips → Reggae → Back).

## Non-goals

No forward stack (the request was Back only). Genre browsing is not
persisted across launch (only the last *playlist* selection is, as
before). Genre membership is the literal `genre_names` tag match (same
semantics the genre graph already uses) — no fuzzy/related expansion.
