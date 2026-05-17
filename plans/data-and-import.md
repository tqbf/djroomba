# Data layer & import pipeline

Local-first. SQLite via **GRDB** is the source of truth. Apple Music is a
one-way import source + the playback engine. No write-back to Apple.

## Why GRDB

Mature, SQLite-native (real SQL + schema migrations), value-type records
(`FetchableRecord`/`PersistableRecord`/`Codable`), `DatabaseQueue`/`Pool` with
async APIs and Swift-6 concurrency support, `ValueObservation` for live UI.
Chosen over: SQLite.swift (thinner, less migration tooling), raw `sqlite3`
(too much boilerplate), SwiftData (hides SQL — wrong fit for "I own the DB").

Added as a SwiftPM dependency in `Package.swift` (see
[build-system.md](build-system.md) — there is no XcodeGen anymore):

```swift
dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
],
// in the DJRoomba target's dependencies:
//   .product(name: "GRDB", package: "GRDB.swift"),
```

DB file: `Application Support/DJRoomba/library.sqlite` (sandbox-safe;
`URL.applicationSupportDirectory`). Schema versioned with
`DatabaseMigrator`; every change is a new named migration (never edit old).

## Schema (as built — Phase 2, `v1.initialSchema`)

Finalized and shipped as the GRDB `DatabaseMigrator` registration
`v1.initialSchema` (see `DJRoomba/Persistence/Database/LibraryMigrator.swift`).
Foreign keys are **enforced** (`Configuration.foreignKeysEnabled = true` in
`AppDatabase`). Codable record types live one-per-file in
`DJRoomba/Persistence/Records/`; the async API is `LibraryStore`. Dates are
GRDB `.datetime` (text, ms precision). Bools are `.boolean` (INTEGER 0/1).

Identifiers: store the MusicKit `MusicItemID` raw string **and** its
namespace (`library` vs `catalog`) so `PlaybackResolver` knows how to
re-fetch. Never assume the two id spaces are interchangeable. The app's
**stable** identity is `song.id` (a minted UUID) — *not* the MusicKit id —
so FK references survive Apple re-issuing ids and re-import is
non-destructive.

```
song(
  id TEXT PRIMARY KEY,            -- app-minted UUID (stable; FK target)
  music_item_id TEXT NOT NULL,    -- MusicItemID rawValue
  id_namespace TEXT NOT NULL,     -- 'library' | 'catalog'
  title TEXT NOT NULL,
  artist_name TEXT NOT NULL,
  album_title TEXT,
  duration REAL,                  -- seconds, nullable
  is_explicit INTEGER NOT NULL DEFAULT 0,
  artwork_url TEXT,               -- resolved/cached, nullable
  imported_at DATETIME NOT NULL,
  UNIQUE(music_item_id, id_namespace)            -- import dedupe key
)

apple_playlist(                   -- read-only snapshot of an Apple list
  id TEXT PRIMARY KEY,            -- Apple library MusicItemID rawValue
  name TEXT NOT NULL,
  artwork_url TEXT,
  curator TEXT,
  last_imported_at DATETIME NOT NULL
)
apple_playlist_track(
  apple_playlist_id TEXT NOT NULL REFERENCES apple_playlist ON DELETE CASCADE,
  song_id          TEXT NOT NULL REFERENCES song          ON DELETE RESTRICT,
  position         INTEGER NOT NULL,
  PRIMARY KEY(apple_playlist_id, position))
INDEX idx_apple_playlist_track_song (song_id)

app_playlist(                     -- user-created, SQLite-only, never to Apple
  id TEXT PRIMARY KEY,            -- app-minted UUID
  name TEXT NOT NULL,
  created_at DATETIME NOT NULL,
  updated_at DATETIME NOT NULL,
  sort_index INTEGER NOT NULL)
INDEX idx_app_playlist_sort_index (sort_index)
app_playlist_track(
  app_playlist_id TEXT NOT NULL REFERENCES app_playlist ON DELETE CASCADE,
  song_id         TEXT NOT NULL REFERENCES song         ON DELETE RESTRICT,
  position        INTEGER NOT NULL,
  PRIMARY KEY(app_playlist_id, position))
INDEX idx_app_playlist_track_song (song_id)

play_event(                       -- append-only history, one row per play
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  song_id   TEXT NOT NULL REFERENCES song ON DELETE RESTRICT,
  played_at DATETIME NOT NULL)
INDEX idx_play_event_song_played_at (song_id, played_at)

song_stat(                        -- denormalized rollup for sort/UI
  song_id        TEXT PRIMARY KEY REFERENCES song ON DELETE CASCADE,
  play_count     INTEGER NOT NULL DEFAULT 0,
  last_played_at DATETIME)
INDEX idx_song_stat_last_played_at (last_played_at)
INDEX idx_song_stat_play_count     (play_count)

favorite_playlist(                -- replaces UserDefaults FavoritesStore
  playlist_id TEXT PRIMARY KEY,   -- apple library id OR app uuid
  source      TEXT NOT NULL)      -- 'apple' | 'app'  (no FK: 2 referents)
recent_playlist(                  -- replaces UserDefaults RecentlyPlayedStore
  playlist_id TEXT PRIMARY KEY,   -- one row/playlist; ordered+capped on read
  source      TEXT NOT NULL,
  played_at   DATETIME NOT NULL)
INDEX idx_recent_playlist_played_at (played_at)
```

**FK cascade vs restrict — deliberate choices (documented in the migrator):**

- Deleting an `apple_playlist` / `app_playlist` **cascades** its
  `*_playlist_track` rows: a playlist owns its membership.
- Deleting a `song` is **RESTRICTed** while it's referenced by any playlist
  track or `play_event`. Listening history must never be silently destroyed
  as a side effect of an import edge case; pruning a song is an explicit,
  separate operation. (This is also why the snapshot-replace transaction is
  atomic: a bad `song_id` makes the whole replace roll back to the prior
  snapshot — tested.)
- `song_stat` **cascades** with its `song` (a stat is meaningless without
  the song; history in `play_event` is the durable record).
- `favorite_playlist` / `recent_playlist` have **no DB FK**: the referent
  is in one of two tables chosen by `source`. Integrity is enforced in app
  code; stale rows are harmless (filtered at merge time).

`play_count`/`last_played_at` are maintained **in the write that records a
play** (`LibraryStore.recordPlay`, one transaction) — deliberately *not* a
SQL trigger, so the rollup logic is visible and unit-tested.
`last_played_at` only ever advances (a backfilled older event won't move it
backward). Favorites/recents replace the UserDefaults stores.

## Migration-extensibility rules (enforced; do not violate)

The schema **will** grow (tags, ratings, smart playlists, multi-source sync
state, artwork variants, artist/album entities, soft-delete). The migrator
is built so that is painless. These rules are also stated in a comment block
at the top of `LibraryMigrator.swift` — the code is the source of truth:

1. **Never edit a shipped migration.** Once `v1.initialSchema` (or any later
   one) has run on a real DB, its closure is frozen forever. Every change is
   a **new** `migrator.registerMigration("vN.<change>") { ... }` appended
   below the previous one. Editing a shipped migration silently diverges
   installed databases.
2. **`eraseDatabaseOnSchemaChange` MUST stay `false`.** The DB is the source
   of truth (local-first pivot) — never auto-wipe user data.
3. Migrations run in registration order, each exactly once, in a
   transaction. Re-running the migrator on an up-to-date DB is a **no-op**
   (idempotent — tested).
4. The migrator is a standalone `static var` with no app/MusicKit deps, so
   migration tests don't need the app to run.
5. Adding a nullable column or a new table = one new migration + one record
   file + (maybe) one `LibraryStore` method. The coarse, intent-named store
   API and Codable records keep it a localized change, never a refactor.

## ImportService (MusicKit → SQLite, one-way) — as built (Phase 3)

`DJRoomba/Music/ImportService.swift`, `@MainActor @Observable` (MusicKit
request/response types are main-actor-friendly and volumes are modest). It
`await`s the `Sendable`, off-main `LibraryStore`; only `Sendable` values
(`Song`, `ApplePlaylist`, ids) cross that boundary.

- Read library playlists via `MusicLibraryRequest<Playlist>` (paged, the
  proven M1 loop, capped `maxPlaylistBatches`).
- Per playlist: `playlist.with([.tracks])` then page `detailed.tracks`
  (capped `maxTrackBatches`). Per-playlist failures are tolerated (collected
  into `lastError`) so one bad playlist never aborts the whole import.
- **`v4` "free" track metadata.** `song(from:)` also reads the direct
  properties already present on the `.song(let s)` payload that
  `playlist.with([.tracks])` ALREADY returns — `trackNumber`,
  `discNumber`, `genreNames`, `releaseDate`, `composerName`, `isrc`,
  `hasLyrics`, `workName`, `movementName` — into nullable `song` columns
  (migration `v4.songMetadata`; `genre_names` is a JSON array string).
  **Zero extra requests, no per-item/catalog fan-out, no rate-limit
  exposure** (Bucket 1 only — Bucket 3 catalog enrichment stays out by
  design / lacks the entitlement). Sparse by nature: a macOS library
  `Song` may not populate every field — NULL just means "not provided",
  harmless. All mutable (the UPSERT `DO UPDATE`s them, like `title`).
  Empirically-observed population on the real library: see PROGRESS.md.
- **Genre lives on the library `Album`, not the `Song`** (signed probe,
  2026-05-17): `Song.genreNames` 0/40 (library `Song` has no `.genres`
  relationship to even request), `Artist.genreNames` 0/40,
  **`Album.genreNames` ~17/40** with real user tags
  (`["Alt/Goth/Industrial"]`, `["Pop/Rock/60s-70s/Classic"]`). The free
  path to genre = a bulk `MusicLibraryRequest<Album>` (paged, no
  per-item/catalog, no rate limit — a new request *type*, not an option
  on the existing playlist fetch) → attribute each album's genre to its
  tracks. **Open design wrinkle:** in that bulk Album request
  `album.title`/`artistName` came back EMPTY, so album→song attribution
  cannot naively join on the stored `album_title` — it needs a reliable
  album↔track key (the `Album.id`/`.tracks` relationship, or requesting
  more Album properties). Album-granular by nature (a compilation gets
  one genre) and partial coverage (~58% of sampled albums carry no genre
  tag — singles/podcasts/untagged).
- **IMPLEMENTED (v5, 2026-05-17).** `GenreImportService` pages
  `MusicLibraryRequest<Album>`, skips empty-`genreNames` albums *before*
  the per-album `album.with([.tracks])` fetch, unwraps each track via the
  shared `ImportService.underlyingItemID(of:)` (== our
  `song.music_item_id`), and `LibraryStore.applyAlbumGenres` batch-writes
  (`CASE … WHEN ? THEN ? … WHERE music_item_id IN (…) AND
  id_namespace='library'`, chunked ≤997 vars) onto `song.genre_names` —
  **no album entity/table, no migration** (the v4 column). Runs **only**
  on full import (Reimport Everything ⇧⌘R) / first import, never on the
  fast incremental Refresh. The album→track id-join sidesteps the
  empty-`album.title` wrinkle (we never needed the title). **Signed
  verification on the real library:** `genre_names` 0 → **6362/8229
  (77.3%)**, correctly attributed (Pearl Jam→Alternative, The Cars→Rock,
  Underworld→Electronic), user hierarchical tags preserved ("Alt/Indie",
  "Alt/Punk/Pixies-Related"); the ~23% blank are untagged-album tracks
  (singles/podcasts/loose), as predicted.
- Map `Track`→`Song`; dedupe per playlist on the import key
  `(music_item_id, id_namespace)` while preserving full playlist order
  (a song twice in a list keeps both positions). `upsertSongs` (store
  preserves the stable `song.id`), then ONE batched id lookup
  (`songIDsByKey`), then `replaceApplePlaylistSnapshot` (transactional).
  Only `song` + `apple_playlist*` are written — the store guarantees
  app-owned tables are untouched (Phase 2 test still green).
- **Underlying-item id + provenance namespace (the D1 corrective —
  supersedes the deleted string classifier).** A MusicKit `Track` is an
  enum (`.song(Song)` / `.musicVideo(MusicVideo)`); its own `track.id` is an
  opaque library `MusicItemID` that does **not** round-trip. `song(from:)`
  unwraps the case and stores the **underlying item's** id
  (`song.id.rawValue` / `musicVideo.id.rawValue`). Because every track here
  comes from a *library* playlist, `id_namespace` is fixed by **provenance**
  to `.library` — never inferred from the id's shape. The old
  `namespace(forRawID:)` heuristic (`i.`→library / bare-numeric→catalog)
  is **deleted**: it degenerated to integer sign on real macOS library
  ids and broke the round trip (caught by the signed gate). Library vs
  catalog id spaces are still NOT interchangeable — provenance, not
  string-sniffing, decides which.
- Wired to the Refresh affordance (⌘R / toolbar) via
  `MusicController.refreshLibrary()`, and run on first authorized launch
  when `store.songCount() == 0`. Full re-import is the v1 cost
  (**~90–120 s for a ~270-playlist / ~8200-track library — dominated by
  MusicKit's per-playlist track resolution on macOS, NOT SQLite and NOT
  fixable by app-side parallelism**; the loop is strictly serial after a
  bounded-parallel attempt was measured ineffective and reverted in the
  Phase-5 corrective — see `architecture.md` → "Import performance shape").
  Pure import — never deletes app playlists or play stats. **Incremental
  by default since 2026-05-16** (see next section); `force` re-fetches all.

## Incremental import (2026-05-16 — the profiling lever)

`plans/profiling.md` proved the ~90–120 s is ≈99% MusicKit's per-playlist
`playlist.with([.tracks])`; the app-side write path is ~1 s. The only lever
is **not fetching tracks for playlists that didn't change** — structural,
not a hotspot fix.

- **Cheap signal:** the playlist *list* fetch (`MusicLibraryRequest<Playlist>`,
  already done, cheap) carries `Playlist.lastModifiedDate`. Stored per
  snapshot as `apple_playlist.change_token` =
  `Int(lastModifiedDate.timeIntervalSince1970)` (migration
  `v2.applePlaylistChangeToken`; integer seconds so it survives GRDB's ms
  date round-trip under exact `==`). `nil` when MusicKit gave no date.
- **Decision** (`ImportService.importDecision`, pure / `nonisolated` /
  unit-tested, no MusicKit): `.skipUnchanged` **only** when a snapshot
  exists AND stored & current tokens both exist AND are equal; every
  uncertainty (`force`, nil current, no snapshot, nil stored) →`.fetch`.
  Conservative by construction: worst case a redundant fetch, **never a
  stale skip**. Skip path = `touchApplePlaylistImportDate` (no track
  fetch, no membership rewrite).
- **Deletions:** the list fetch gives the full live id set, so
  `pruneApplePlaylists(keeping:)` drops vanished snapshots; FK cascade
  removes only their membership — one-way isolation preserved (tested:
  app playlists / stats / favorites / recents untouched).
- **Escape hatch:** ⇧⌘R "Reimport Everything" →
  `MusicController.reimportEverything()` → `runImport(force: true)`. This
  is the recovery for the one real risk — a **smart/auto playlist whose
  contents change server-side without bumping `lastModifiedDate`** (also
  the profiling vehicle, and what `ImportPerfBench` exercises at scale).
- **Effectiveness caveat (honest):** the *mechanism* is correct & safe
  regardless. Its *speedup* depends on macOS MusicKit actually populating
  `lastModifiedDate` on library playlists — which `musickit-notes` flags
  as often-nil. Verifiable only on a signed run; when nil, it simply
  degrades to today's full import (no regression). Measured payoff TBD on
  a signed Refresh; the worst case is unchanged from before.

## PlaybackResolver (SQLite id → playable MusicKit item) — as built

`DJRoomba/Music/PlaybackResolver.swift`, `@MainActor @Observable`. At play
time, take the selected playlist's stored `TrackRow`s:

1. `groupByNamespace` (pure, unit-tested) splits + de-dupes ids per
   namespace.
2. Library ids → `MusicLibraryRequest<MusicKit.Song>().filter(matching:
   \.id, memberOf: ids)` — the **live, dev-signed path Phase 1 proved**
   (no catalog/MusicKit-App-Service entitlement). Since import is now
   provenance-`.library` for everything, this branch carries the whole
   queue. The catalog branch (`MusicCatalogResourceRequest<Song>`) is
   wired but **dormant**: it receives nothing today (no catalog-namespace
   ids are imported) and is kept only for a future catalog-import feature;
   it must only ever get genuinely catalog ids. The two re-fetches are
   independent: a catalog failure keeps the library resolutions.
3. `reassemble` (pure, unit-tested) rebuilds the queue in original row
   order, **dropping unresolvable rows and reporting them**
   (`unresolvedMusicItemIDs`) — one bad/region-removed/user-upload id never
   breaks the queue (risk register). The start song falls back to the first
   resolved row if the requested start dropped.
4. Hand the resolved `[MusicKit.Song]` to the **unchanged** M1
   `PlaybackService` (it now takes resolved songs, builds
   `ApplicationMusicPlayer.Queue(for:)` / `(for:startingAt:)` exactly as
   before). `MusicController` records a `play_event` (`store.recordPlay`,
   which also rolls `song_stat`) for the track that actually started.

Pure grouping/reassembly are `nonisolated static` so they unit-test without
a live MusicKit session; the re-fetch itself is verified only on a signed
run (the 🔴 id round-trip — diagnosed + corrected, runtime re-verification
pending). A visible inline error surface (`MusicController.playbackProblem`,
rendered as a `.caption` `.orange`-glyph `Label` in the playlist header)
means a resolve/playback failure is no longer silent.

## Batch write idioms (the D3 corrective — user-flagged)

Row-by-row import pegged a core for ~90s. Reworked into SQLite batch
idioms, behavior identical (re-import still non-destructive, snapshot
replace still one atomic transaction, app-owned tables still never touched
— the existing tests stay green, new `BatchImportTests` add coverage):

- `LibraryStore.upsertSongs` = ONE `write` of chunked multi-row
  `INSERT … VALUES (…),(…),… ON CONFLICT(music_item_id, id_namespace)
  DO UPDATE SET col = excluded.col …`. The `DO UPDATE` deliberately
  **omits `id`** so an existing row keeps its stable PK (and every
  playlist/history FK) while metadata refreshes — this *is* the
  non-destructive-re-import guarantee, now enforced by the UPSERT itself.
- `LibraryStore.songIDsByKey(_:)` resolves every import key → stored
  `song.id` in ONE chunked `WHERE (music_item_id, id_namespace) IN
  (VALUES …)` read, replacing `ImportService`'s per-song N-await loop.
- `replaceApplePlaylistSnapshot` membership insert is chunked multi-row.
- All multi-row statements chunk via `Array.chunked(into:)` so a single
  statement never exceeds SQLite's 999 bound-parameter cap, regardless of
  library size. `SongKey` lives on `LibraryStore` (the import key type).

## App-playlist CRUD (Phase 4 — SQLite-only, never to Apple)

User-owned playlists are the product. They live **only** in
`app_playlist` / `app_playlist_track` (the Phase-2 tables; **no schema
change was needed** — the v1 cascade FK already drops membership on delete,
v1 stays frozen). `AppPlaylistService` (`@MainActor @Observable`) owns the
listing + CRUD; it `await`s the off-main store and reloads from SQLite after
every write (no dual store). The `LibraryStore` additions, all single
transactions, all batch idioms (never an N-await per-row loop), all proven
by `AppPlaylistCRUDTests` to leave `apple_playlist*`/song/stat/history
untouched (the one-way-isolation invariant for Phase 4):

- `createAppPlaylist(named:)` — inserts with `sort_index = MAX(sort_index)+1`
  computed **inside the write** so two quick creates can't collide.
- `renameAppPlaylist` / `deleteAppPlaylist` — one UPDATE / one DELETE
  (membership cascades via the v1 FK; songs are delete-RESTRICTed so history
  survives).
- `addSongsToAppPlaylist` — append at tail; the next position is read once
  inside the txn; chunked multi-row INSERT (≤999-var cap). Duplicates allowed
  (a song may appear twice).
- `removeTracksFromAppPlaylist(positions:)` — chunked `IN` delete **then**
  dense renumber to `0..<count` (the composite PK `(playlist,position)` must
  stay gap-free), one atomic txn.
- `setAppPlaylistTracks` — bulk-delete + chunked multi-row re-insert; this is
  the full-membership replace used by drag-to-reorder.
- `reorderAppPlaylists(orderedIDs:)` — one chunked `UPDATE … SET sort_index =
  CASE id WHEN ? THEN ? … END WHERE id IN (…)` per chunk; never a per-row
  statement loop.
- `appPlaylistTrackCounts()` — one grouped `COUNT(*)` for the sidebar counts.
- `songsWithStats(in{App,Apple}Playlist:)` — one indexed LEFT JOIN of the
  ordered membership against `song_stat` so the track table's play-count /
  last-played columns populate in a single query (no per-song stat fetch;
  stays fast for large playlists). Membership table/column are interpolated
  from a fixed allow-list, never user input.

## App-playlist playback re-resolution (Phase 4 — per-song, 1:1)

Imported Apple playlists re-resolve at **playlist granularity** (above).
App playlists are arbitrary song collections with **no backing Apple
playlist**, so that path doesn't apply. The Phase-3 probe established the
shape that *does* round-trip: a stored `music_item_id` (the underlying
library `Song`'s id, captured by import provenance) re-resolves **1:1** via
`MusicLibraryRequest<MusicKit.Song>.filter(matching:\.id, equalTo: storedID)`
when queried **one id at a time** — only batch `memberOf` loses the
query→result correspondence (the returned `Song.id` differs).

`PlaybackResolver.resolveAppPlaylist(rows:startAt:)`:
1. `groupByNamespace` (pure, unit-tested) → unique library ids (catalog
   branch dormant, no catalog imports).
2. `resolveLibrarySongsIndividually` — one `equalTo` request per **unique**
   id, issued through a **bounded** `TaskGroup` (sliding window of 8;
   structured concurrency, no GCD, doesn't flood MusicKit on a large list),
   each task swallowing its own error and yielding nil (one miss never
   aborts the rest), the result map keyed by the **stored** id.
3. `reassemble` (pure, unit-tested) — rebuild in playlist order, duplicates
   re-expanded, misses dropped + reported (`unresolvedMusicItemIDs` →
   inline `playbackProblem`), and `Resolution.startSongID` set to the
   started track's **stored `song.id`** (the FK target for play recording —
   the resolved `Song.id` ≠ the stored id, so id-matching back to a row is
   unreliable; this carries the right id directly).
4. Hand the `[MusicKit.Song]` to the **unchanged** `PlaybackService`.

The disproven Phase-3 batch-`memberOf` `resolve(rows:startAt:)` (+ its
`fetchLibrarySongs` helper) was **removed** — it keyed by the resolved
`Song.id` while `reassemble` looked up by the stored id (zero matches, the
documented gate failure). The pure helpers it shared are kept and now back
the working per-id path. The per-id re-fetch itself is signed-run
verification (no live MusicKit session in tests).

## Play tracking (Phase 4 — fires on the *real* start)

`recordPlay`/`song_stat` (Phase 2) is unchanged. The Phase-3 follow-up bug
— the `if playback.snapshot.isPlaying` guard read the 0.5 s-polled snapshot
too early so a play was never recorded — is fixed at the trigger:
`PlaybackService.play` now returns `Bool`; after `player.play()`,
`confirmPlaybackStarted()` polls the player's **own** `state.playbackStatus`
on a short bounded loop (50 ms / ≤2.5 s, `Task.sleep(for:)` only) until
`.playing`. `MusicController` records the play **only on a confirmed start**,
for `Resolution.startSongID` (the stored `song.id` the resolver attributes
the start to — deterministic for both the imported and app-playlist paths).

## Artwork (the D2 corrective)

Phase 3 stored `Artwork.url(...)`, which for *library* items on macOS is a
private `musicKit://…` scheme `URLSession` cannot fetch — every thumbnail
regressed to the placeholder. Phase 1 showed real art by handing a live
`MusicKit.Artwork` to MusicKit's own `ArtworkImage` view (it fetches +
caches the bitmap itself, private scheme included); `plans/musickit-notes.md`
already recommends `ArtworkImage`. Restored exactly that, staying
local-first (only the id is stored):

- `ArtworkProvider` (`actor`): given a stored `MusicItemID` + namespace +
  kind, lazily re-resolves the owning library item
  (`MusicLibraryRequest<Song>` / `<Playlist>` — an imported Apple
  playlist's own id is a library id) and returns its `Artwork`. Process-
  wide cache + in-flight de-dup + **negative caching** (a known-artless id
  isn't re-requested every scroll). No GCD; only `Sendable` values cross.
- `ArtworkThumbnail` renders `ArtworkImage(artwork, width:height:)`
  (Phase-1-identical) from a new `ArtworkRef`; same fixed frame / corner
  radius / `.quaternary`+SF-Symbol placeholder / 0.2s value-driven
  cross-fade / no layout shift. The unfetchable `artwork_url` column is
  retained but written `nil` — **no schema migration** (v1 stays frozen).
  `ArtworkImageLoader` (the URL loader) is deleted. Offline: a miss
  degrades to the same native placeholder; once shown, MusicKit's own
  on-disk artwork cache serves it again.

## Concurrency (as built)

- `LibraryStore` and `AppDatabase` are `Sendable` **value types**,
  intentionally **not `@MainActor`**. The only stored state is GRDB's
  internally-serialized, `Sendable` `DatabaseQueue`; there is no app-level
  shared mutable state and no external locking. All DB work runs off the
  main actor via `try await dbQueue.read/write { }`. `read` = snapshot
  read; `write` = a single transaction (commit on success, roll back on
  throw) — multi-step invariants (snapshot replace, play accounting) are
  done inside ONE `write` so they're atomic.
- `MusicController` stays `@MainActor @Observable`; it `await`s store calls
  and republishes results as observable state (the documented data-flow
  boundary). Phase 3 uses an explicit reload after import (`library.load()`
  then sidebar reads SQLite); `ValueObservation` for a live sidebar is a
  Phase 5 option if warranted.
- Phase 3 services `ImportService` / `PlaybackResolver` / `LibraryReadService`
  / `PlaylistDetailService` are `@MainActor @Observable` like the M1 MusicKit
  services and `await` the off-main store. Pure logic (resolver
  grouping/reassembly) is `nonisolated static` so it is testable without an
  actor hop or a live MusicKit session. (The string namespace classifier is
  gone — namespace is provenance, decided at import, not classified.)
- Artwork: `ArtworkProvider` is a process-wide `actor` (serialized cache +
  in-flight de-dup + negative cache; `MusicLibraryRequest` re-resolve via a
  `nonisolated static`). No GCD, no locks; only `Sendable` values cross
  actors (`MusicKit.Artwork` is `Sendable`). SQLite stores only the id;
  nothing live (`MusicKit.Artwork`) is persisted — it is re-derived on
  demand and `ArtworkImage` renders it.
- Strict Swift 6 concurrency retained and clean (`swift build` +
  `swift test` both green). Same `nonisolated(unsafe)` note for
  `ApplicationMusicPlayer` applies (see `plans/musickit-notes.md`); GRDB
  added no new concurrency friction.
- `swift test` (`.testTarget` `DJRoombaTests`) is the store/migration gate.
  `@testable import DJRoomba` of the `@main` executable target links and
  runs on the Swift 6.3 SwiftPM toolchain, so **no `@main` restructuring
  was needed** and app behavior is unchanged.

## Migration from M1/M2 — as built (Phase 3)

`DJRoomba/Persistence/LegacyPreferencesMigration.swift`. On first authorized
launch it reads the M2 UserDefaults keys `favoritePlaylistIDs` /
`recentlyPlayedPlaylistIDs` once and writes them into `favorite_playlist` /
`recent_playlist` (source `.apple` — every M2 favorite was an Apple library
playlist; app playlists are Phase 4). Recents are stamped oldest→newest so
reading back `ORDER BY played_at DESC` reproduces the legacy
most-recent-first list. A sentinel `legacyPrefsMigratedToSQLite_v1` gates
re-runs; after it is set the legacy keys are **never read or written again**
(no dual write — SQLite is the sole source of truth). The legacy keys are
left in place (cheap; avoids data loss on a hypothetical downgrade) but
inert. `FavoritesStore` / `RecentlyPlayedStore` were deleted;
`UserPreferencesStore` (last selection) deliberately stays in UserDefaults.
The pure `plan(...)` derivation is unit-tested; the one-shot run is tested
end-to-end against an in-memory store + an isolated `UserDefaults` suite.
