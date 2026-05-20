# Apple Touchpoints

Every Apple **music / iTunes** API surface DJ Roomba depends on, down to the
specific call. Basic Swift / SwiftUI / Foundation / GRDB is intentionally out
of scope — this is only the Apple-media integration boundary.

Provenance tags used below:
- **LIVE** — exercised and proven on the real dev-signed build (Phase 1 / M1).
- **GATED** — code-complete but only valid behind a signed runtime gate.
- **DORMANT** — wired but never reached on any current code path.
- **PORTAL/BUILD** — not a Swift call; an Apple-account / signing dependency.

> The thin-wrapper rule (PLAN.md): all MusicKit lives in `DJRoomba/Music/*`
> and `DJRoomba/Views/Artwork*`. `MusicController` orchestrates these
> services and itself imports **no** MusicKit. SQLite is the source of
> truth; Apple is import-source + playback-engine only, never written back.

---

## 0. Frameworks linked

| Framework | Where | Purpose |
|---|---|---|
| `MusicKit` | 9 files (`Music/*`, `Views/Artwork*`, `Views/RootView`) | Auth, subscription, library read, catalog (gated), playback, artwork |
| `iTunesLibrary` | `Music/PlaylistFolderSource.swift` only | The **only** way to discover playlist *folders* (MusicKit has no folder discriminator on macOS) |

No `MediaPlayer`, no `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter`, no
`AVFoundation` / `AVAudioSession` / `AVPlayer`, no `StoreKit` /
`SKCloudServiceController`, no Apple Music **REST** API, no MusicKit-JS, no
developer-token JWT signing. Deliberate — see §10.

---

## 1. PORTAL / BUILD touchpoints (no Swift call)

These gate whether the Swift calls below even function.

- **App ID `org.sockpuppet.djroomba`, Team `KK7E9G89GW`, explicit.**
  MusicKit does a strict App-ID match against the signed bundle id.
- **App Service: MusicKit** enabled on that App ID (developer portal →
  Identifiers → App Services). Required for **catalog**; the developer
  token MusicKit auto-vends for `MusicCatalogSearchRequest` /
  `MusicCatalogResourceRequest` is issued server-side from bundle-id +
  team + this service. **Not** required for library read/playback
  (Phase-1 fact). Empirically: registering the App ID + service is **not
  sufficient** on a profile-less dev build — catalog still fails
  `MusicTokenRequestError: "Failed to request developer token"` (see
  PROGRESS 2026-05-19); the embedded provisioning-profile path is the
  open follow-up. **PORTAL/BUILD.**
- **`Info.plist` → `NSAppleMusicUsageDescription`**
  (`DJRoomba/Info.plist:35`). Without it, `MusicAuthorization.request()`
  crashes the app. Literal value (no `$(…)` build vars — SwiftPM doesn't
  expand them and a literal would break MusicKit's App-ID match).
- **Entitlements** (`DJRoomba/DJRoomba.entitlements`):
  - `com.apple.security.app-sandbox` — sandboxed.
  - `com.apple.security.network.client` — MusicKit/iTunes network + the
    artwork bitmap fetch.
  - `com.apple.security.assets.music.read-only` — **required to
    instantiate `ITLibrary`** in a sandboxed signed build without a user
    prompt (Phase-1 A2 finding). MusicKit itself needs no dedicated
    entitlement key (there is none for native MusicKit).
- **Signing identity**: `Apple Development: Thomas Ptacek (7F2QE7P59D)`
  (`build.sh:29,76`). **Ad-hoc signing is forbidden** — an ad-hoc build
  gets an *empty* MusicKit library at runtime (proven Phase 1). `make
  dist` re-signs `Developer ID Application` + hardened runtime + notarize.
- **`PROVISION_PROFILE` hook** (`build.sh:69–73`, `Makefile:52,118,121`):
  copies a `.provisionprofile` to `Contents/embedded.provisionprofile`
  before codesign. Currently empty (no-op). The pre-wired answer to the
  catalog developer-token question. **PORTAL/BUILD.**

---

## 2. MusicKit — Authorization  (LIVE)

`Music/MusicAuthorizationService.swift` — thin wrapper over
`MusicAuthorization`.

- `MusicAuthorization.currentStatus` → `MusicAuthorization.Status`
  (`:10` initial, `:13` in `refresh()`). Synchronous snapshot.
- `await MusicAuthorization.request()` → `MusicAuthorization.Status`
  (`:17`). Triggers the system Apple Music consent prompt (needs the
  Info.plist usage string). Called from `MusicController.requestAccess`
  (`MusicController.swift:351`).
- `MusicAuthorization.Status` cases consumed in `RootView.swift:8–17`:
  `.authorized` → `MainShellView`; `.notDetermined` / `.denied` /
  `.restricted` / `@unknown default` → `AuthorizationView`.

## 3. MusicKit — Subscription  (LIVE)

`Music/MusicSubscriptionService.swift`.

- `for await subscription in MusicSubscription.subscriptionUpdates`
  (`:28`) — async stream of `MusicSubscription`. Started in a retained
  `Task` (`startMonitoring` ← `MusicController.bootstrap` `:729`),
  cancelled in `stop()`.
- Per update reads: `subscription.canPlayCatalogContent` (`:30`),
  `.canBecomeSubscriber` (`:31`), `.hasCloudLibraryEnabled` (`:32`).
- Consumed by `MusicController`: `canPlayCatalogContent`
  (`MusicController.swift:245,268,272`), `hasCloudLibraryEnabled`
  (`:247`, distinguishes "library not synced to this Mac" vs "synced but
  empty" in `LibrarySidebarState`). Treated as a thin safety net only —
  the app *assumes* an active subscription (PLAN.md / catalog-playlists).

## 4. MusicKit — Library read requests  (LIVE)

The core import path. All `MusicLibraryRequest<…>`; pages with a hard cap.

- **Playlists** — `MusicLibraryRequest<Playlist>`
  (`ImportService.swift:363`), `request.limit = 100` (`:364`),
  `try await request.response()` (`:365`), then the paging loop:
  `response.items` → `MusicItemCollection<Playlist>`, `current.hasNextBatch`
  (`:373`), `try await current.nextBatch()` (`:374`), capped at
  `maxPlaylistBatches = 1000` (`:331`).
- **Albums** — `MusicLibraryRequest<Album>`
  (`GenreImportService.swift:281`), same `limit`/paging shape, cap
  `maxAlbumBatches = 1000` (`:236`).
- **Songs (by id)** — `MusicLibraryRequest<MusicKit.Song>`:
  - `.filter(matching: \.id, equalTo: id)` + `request.limit = 1`
    (`PlaybackResolver.swift:494–496`) — the **verified 1:1 round-trip**
    for app-playlist re-resolution. Issued one id at a time, bounded
    `TaskGroup` (`maxConcurrentResolves = 8`, `:470`).
  - `.filter(matching: \.id, memberOf: [id])`
    (`ArtworkProvider.swift:114`) — artwork re-resolve by song id.
- **Playlists (by id)** — `MusicLibraryRequest<MusicKit.Playlist>`:
  - `.filter(matching: \.id, equalTo: MusicItemID(libraryPlaylistID))`
    (`PlaybackResolver.swift:310–311`) — re-resolve an imported Apple
    playlist for playback, then read its **live** `.tracks` (the proven
    playback path; sidesteps the Track-id≠Song-id problem).
  - `.filter(matching: \.id, memberOf: [id])`
    (`ArtworkProvider.swift:119–121`) — playlist artwork re-resolve.

### Relationship hydration `.with([…])`  (LIVE)

A list request returns a *partial projection*; `.with([…])` fetches more.

- `try await playlist.with([.tracks])` (`ImportService.swift:345`) — the
  per-playlist track fetch. **The measured import bottleneck**
  (CPU-heavy, MusicKit-internally-serialized on macOS; app-side
  parallelism proven ineffective — see the long header comment
  `ImportService.swift:20–36`). Then page `detailed.tracks` →
  `MusicItemCollection<Track>` with `.hasNextBatch`/`.nextBatch()`, cap
  `maxTrackBatches = 5000`.
- `try await livePlaylist.with([.tracks])` (`PlaybackResolver.swift:320`)
  — same, on the playback path.
- `try await album.with([.tracks])` (`GenreImportService.swift:263`) —
  per-album track fetch for genre attribution.
- `try await album.with([.genres])` (`GenreImportService.swift:181`) —
  **macOS-14.4 fallback**: the bulk `Album` projection omits
  `genreNames` there, so genre is re-resolved per album. Reads
  `detailed.genres?.map(\.name)` (`:182`) and `detailed.genreNames`
  (`:186`). Genre-resolution precedence is pure/unit-tested
  (`resolvedGenres`, `:113`).

### Library model fields read

- **`Track`** (an enum) — `.song(MusicKit.Song)` / `.musicVideo(...)` /
  `@unknown default`. Unwrapped in
  `ImportService.underlyingItemID(of:)` (`:91–102`) and `song(from:)`
  (`:104–152`). Display fields off `Track` directly: `.title`,
  `.artistName`, `.albumTitle`, `.duration`, `.contentRating`
  (`== .explicit`, `:131`).
- **`MusicKit.Song`** "free v4 metadata" (only when `Track` is `.song`,
  zero extra calls — already in the `.with([.tracks])` payload):
  `.trackNumber`, `.discNumber`, `.genreNames`, `.releaseDate`,
  `.composerName`, `.isrc`, `.hasLyrics`, `.workName`, `.movementName`
  (`ImportService.swift:142–150`); plus `.id.rawValue`,
  `.artwork` (`ArtworkProvider.swift:116,122`).
- **`Album`** — `.genreNames` (`GenreImportService.swift:170`),
  `.genres` relationship (`:182`), `.title` (`:188`).
- **`Playlist`** — `.id.rawValue` (`ImportService.swift:259`),
  `.name` (`:301,431`), `.curatorName` (`:431`),
  `.lastModifiedDate` → incremental-import change token
  `Int(timeIntervalSince1970)` (`:182`; `nil` on macOS is common →
  conservative re-fetch).
- **`MusicItemID`** — `MusicItemID(String)` (`PlaybackResolver.swift:117`,
  `ArtworkProvider.swift:109`), `.rawValue` everywhere ids are stored.
  Library ids do **not** round-trip through a re-fetch (the D1 saga);
  catalog ids are globally stable.
- **`MusicItemCollection<T>`** — `.hasNextBatch`, `.nextBatch()`,
  iterated by `contentsOf:` in every paging loop.

## 5. MusicKit — Catalog requests  (LIVE / DORMANT)

Native, in-process — **no REST, no developer-token JWT** (see §10).

- `MusicCatalogSearchRequest(term:types:[MusicKit.Song.self])`, used by
  TWO sites with different page shapes:
  - `CatalogProbeService.swift` — `searchProbe()`: `request.limit = 5`,
    one-shot `try await request.response()`, `response.songs` →
    `first.title` / `.artistName` / `.id.rawValue`. **LIVE** — Phase-0
    access probe proven end-to-end (search + playback) on the dev-
    signed, profile-embedded build (2026-05-20 PROGRESS entry).
  - `CatalogSearchService.swift` — `search(_:)` + `loadMore()`:
    `request.limit = 25`, `try await request.response()`, then **paged
    via `MusicItemCollection<Song>.hasNextBatch` / `.nextBatch()`**
    with `maxSearchBatches = 20` (≈ 500-result ceiling) — same M1-
    style capped page-loop shape `ImportService` uses
    (`§4`). **LIVE** — Phase-2 (2026-05-20 entry) live-verified: typed
    "queen", paged catalog response returned 6 Queen tracks with
    `hasNextBatch == true` (Load-more affordance visible), one result
    ingested through to a SQLite `id_namespace='catalog'` row + an
    app-playlist FK.
  Requires the App ID's MusicKit App Service enabled *and* an embedded
  provisioning profile asserting it; library (`§4`) needs neither.
- `MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, memberOf:
  ids)`, `.response().items` — used by TWO sites now:
  - `PlaybackResolver.swift`, `fetchCatalogSongs` (called from
    `resolveAppPlaylist`) for playback.
  - `ArtworkProvider.swift`, the `(.catalog, .song)` arm of `resolve`
    for catalog cover-art re-resolution (Phase 4 of
    `plans/catalog-playlists.md`).
  **LIVE (with caveat)** — Phase-3 (2026-05-20 entry) live-verified for
  pure-catalog playback queues; Phase-4 (2026-05-20 entry) live-verified
  for catalog artwork on search-result rows AND the now-playing thumbnail
  (Queen "Greatest Hits I, II & III" cover at 40×40 in both surfaces).
  **Caveat:** when the resolved queue mixes library and catalog
  `MusicKit.Song`s, `ApplicationMusicPlayer.Queue(for: [Song])` /
  `try await player.play()` fails with
  `MPMusicPlayerControllerErrorDomain` error 6 (`requestTimedOut`) —
  see the Phase-3 PROGRESS entry F1 follow-up.

### Catalog `MusicKit.Song` fields consumed by `CatalogIngestService` (Phase 1)

Informational — purely a SQLite write path, not a new Apple API surface
(the `MusicCatalogSearchRequest` that *returns* the `Song`s above is
already LIVE). `CatalogIngestService.song(fromCatalog:)` reads, from each
`MusicKit.Song` produced by Phase-2 search: `.id.rawValue` (catalog id),
`.title`, `.artistName`, `.albumTitle`, `.duration`, `.contentRating`
(`== .explicit`), plus the nine "free" v4 metadata fields already in the
catalog payload — `.trackNumber`, `.discNumber`, `.genreNames`,
`.releaseDate`, `.composerName`, `.isrc`, `.hasLyrics`, `.workName`,
`.movementName`. Mints `idNamespace: .catalog` by provenance — the mirror
of `ImportService.song(from:)`'s `.library` rule. Artwork is *not* read
here; Phase 4 owns artwork re-resolution.

## 6. MusicKit — Playback  (GATED)

`Music/PlaybackService.swift` — thin wrapper over
`ApplicationMusicPlayer.shared`.

- `ApplicationMusicPlayer.shared` (`:146`) — held
  `nonisolated(unsafe)` (not Sendable-audited; access serialized on
  MainActor — see `plans/musickit-notes.md`).
- Queue construction:
  `ApplicationMusicPlayer.Queue(for: songs, startingAt: start)` (`:191`)
  / `ApplicationMusicPlayer.Queue(for: songs)` (`:193`).
  **F1a (2026-05-20 followup):** in `PlaybackService.play(resolution:
  playlistContextID:)`, the queue is constructed **per chunk**
  (sequential homogeneous-namespace sub-queues). Each chunk gets its
  own `ApplicationMusicPlayer.Queue(for: chunkSongs)`; the 0.5 s
  monitor tick detects natural end-of-chunk (`player.queue.currentEntry
  == nil` AND `currentChunkIndex + 1 < pendingChunks.count`) and swaps
  to the next chunk via the same `Queue(for:)` constructor. A
  `Next`-button press at the tail of a chunk triggers the same swap
  directly (Apple's player loops within a queue on `skipToNextEntry()`
  at tail — see gotcha #10).
- Transport: `try await player.play()` (`:81,195,207`), `player.pause()`
  (`:78` inside `togglePlayPause()`, plus the dedicated idempotent
  `pause()` added for the Phase-0 catalog probe playback half),
  `try await player.skipToNextEntry()` (`:120`),
  `try await player.skipToPreviousEntry()` (`:129`).
- State reads: `player.state.playbackStatus`
  (`:77,234,245,252` → mapped from `MusicPlayer.PlaybackStatus`
  `.playing/.paused/.stopped/.interrupted/.seekingForward/.seekingBackward/@unknown`,
  `:166–178`), `player.playbackTime` (`:111,253`),
  `player.queue.currentEntry` (`:112,256`),
  `player.queue.entries` + `Entry.id` for the structural queue index
  (`:266–267` — index keys on the queue Entry's own id, **never** an
  Apple content id), `ApplicationMusicPlayer.Queue.Entry`:
  `.title`, `.subtitle`, `.item` → `.song(Song)` / `.musicVideo(...)` /
  `.none` / `@unknown` with `.duration` and `.id.rawValue`
  (`:155–164,256–282`).
- Snapshot is polled on a ~0.5 s structured-concurrency loop
  (`startMonitoring`, `:40–48`); a separate bounded poll
  `confirmPlaybackStarted` (`:227–248`) waits for the engine to truly
  reach `.playing` (macOS: `play()` can resolve while still loading), and
  one bounded `play()` re-issue (`:206–209`) is the auto-start fix.

## 7. MusicKit — Artwork  (LIVE — library + catalog)

- `MusicKit.Artwork` — re-resolved by id (never stored: a library
  artwork URL is a private `musicKit://` scheme `URLSession` cannot
  fetch — the D2 finding). `ArtworkProvider` (an `actor`, FIFO-capped at
  1024) branches inside `nonisolated static resolve(musicItemID:
  namespace:kind:)` by `(namespace, kind)` (Phase 4 of
  `plans/catalog-playlists.md`):
  - `(.library, .song)` / `(.library, .playlist)` →
    `MusicLibraryRequest<Song>` / `<Playlist>.filter(matching: \.id,
    memberOf: [id])` → `response.items.first?.artwork` — the D2 path
    (`ArtworkProvider.swift`, the library arms of the switch). Library
    artwork URLs are the private `musicKit://` scheme — only
    `ArtworkImage` can render them.
  - `(.catalog, .song)` → `MusicCatalogResourceRequest<Song>(matching:
    \.id, memberOf: [id])` → `response.items.first?.artwork` (same
    shape as `PlaybackResolver.fetchCatalogSongs`). Catalog `Artwork
    .url(...)` is a public HTTPS URL; we still hand the `Artwork` to
    `ArtworkImage` so the renderer is one path for both namespaces.
  - `(.catalog, .playlist)` → `nil` by design (deliberate non-goal:
    we don't import catalog playlists, only catalog songs through
    the catalog-search surface; documented in the switch).
- `ArtworkImage(artwork, width:height:)` (`ArtworkThumbnail.swift`) —
  MusicKit's own SwiftUI view; it fetches + on-disk-caches the bitmap
  itself, including the private scheme (the only thing that renders
  library art) and the public catalog URL (transport picked internally).
  Re-resolution driven by `.task(id: ref)`. `PlayerStateSnapshot
  .nowPlayingNamespace` (Phase 4, populated by `PlaybackService
  .refreshSnapshot` from the active chunk's namespace) tags the
  now-playing id so a catalog song's thumbnail re-resolves through the
  catalog branch instead of mis-routing through library.

## 8. iTunesLibrary.framework  (LIVE)

`Music/PlaylistFolderSource.swift` — the single isolated bridge; the
**only** non-Sendable Apple type touched, and it never escapes the
closure (returns `Set<String>`).

- `try ITLibrary(apiVersion: "1.1")` (`:53`) — throwing init; on any
  failure logs and returns `[]` (graceful degradation — folder exclusion
  is a correctness nicety, never fatal). Runs on `Task.detached` so the
  whole-library DB parse never stalls the MainActor.
- `library.allPlaylists` iterated; `playlist.kind == .folder` (`:62`) is
  the folder discriminator MusicKit lacks.
- `playlist.persistentID.uint64Value` (`:68`) — `NSNumber` → raw 64-bit;
  `PlaylistFolderClassifier.folderIDString(persistentID:)` reinterprets
  it as the signed-decimal string MusicKit uses for
  `MusicItemID.rawValue`, so folders match the ids `ImportService`
  already fetched. Consumed at `ImportService.swift:232,269` to exclude
  folders **before** any `.with([.tracks])` (a folder's track fetch
  hangs the MainActor — Phase-0 corollary).

## 9. Profiling shim (build-only, not media)

`apple/swift-profile-recorder` (`ProfileRecorderServer`) is started only
behind `#if DEBUG || PROFILE_RECORDER` (`PlaylistPlayerApp.swift:3,16`)
and dormant unless `PROFILE_RECORDER_SERVER_URL_PATTERN` is set. Used to
profile the import hot path (`plans/profiling.md`). Not an Apple-media
API; listed for completeness of Apple-origin deps.

## 10. Deliberately NOT used

- **Apple Music REST API / `api.music.apple.com`** — native MusicKit
  does search + fetch + playback in-process; the REST path is the
  MusicKit-JS/web model.
- **Developer-token JWT / `.p8` key / Media ID / Key ID** — only needed
  for JS/REST. Native auto-vends the token from the App-ID service.
- **`MediaPlayer` / now-playing center / remote command center** — full
  playback goes through Apple's `ApplicationMusicPlayer`; no system
  now-playing integration is built.
- **`AVFoundation` / raw audio / `StoreKit`** — no local audio engine,
  no protected-stream decode, no in-app purchase/subscription UI (the
  app assumes an existing subscription).
- **Any Apple-library mutation** — strictly one-way; nothing is written
  back to Apple Music / Music.app.

---

### macOS-specific gotchas captured above (quick index)

1. Ad-hoc signing → empty MusicKit library (must use Apple Development).
2. Library `MusicItemID`s don't round-trip; re-resolve playlists by id
   and read live tracks, or songs one-at-a-time with `equalTo`.
3. Library artwork URL = private `musicKit://`; only `ArtworkImage`
   renders it.
4. macOS 14.4 bulk `Album` projection omits `genreNames` → per-album
   `.with([.genres])` fallback.
5. `Playlist.lastModifiedDate` often `nil` on macOS → conservative
   re-fetch.
6. `playlist.with([.tracks])` is the import bottleneck and is **not**
   app-parallelizable.
7. Playlist **folders** are indistinguishable in MusicKit → iTunesLibrary
   is the only source, and they must be excluded before any track fetch.
8. `player.play()` may resolve before the engine is `.playing` → bounded
   confirm-poll + one re-issue.
9. Catalog needs the App-ID MusicKit service **and** an embedded
   provisioning profile asserting it (confirmed 2026-05-20: profile-less
   dev build → `MusicTokenRequestError`; same build with embedded
   profile → catalog search returns results); library needs neither.
10. **A mixed library + catalog `ApplicationMusicPlayer.Queue` is rejected
    on macOS** with `MPMusicPlayerControllerErrorDomain` error 6
    (`requestTimedOut`) — confirmed 2026-05-20 on the Phase-3 live test
    with a deterministic 3-element queue (2 catalog + 1 library); both
    pure-library and pure-catalog queues play fine; only the mix fails.
    **Workaround (F1a, 2026-05-20 followup):** `PlaybackService.play
    (resolution:playlistContextID:)` splits the resolved queue into
    homogeneous-namespace **chunks** (`Resolution.chunkBoundaries`) and
    plays them one at a time, swapping `player.queue` at each namespace
    boundary. Single-chunk resolutions (library-only OR catalog-only —
    the common case) hit the fast path identical to a single-queue play.
    See PROGRESS 2026-05-20 F1a entry.
11. **`ApplicationMusicPlayer.skipToNextEntry()` at the tail of a queue
    wraps to the queue head on macOS** rather than emptying / failing
    — confirmed 2026-05-20 on the F1a live test (Bohemian → Dancing →
    Bohemian → Dancing … indefinitely, no `currentEntry == nil` ever).
    Consequence: end-of-chunk detection cannot rely on the natural-end
    `currentEntry == nil` signal when the user presses Next at the
    tail. F1a special-cases `PlaybackService.skipNext()` to detect
    "current entry == queue's last entry AND a next chunk exists" and
    perform the chunk swap directly instead of calling
    `skipToNextEntry()`. The natural end-of-song path (auto-advance
    through to song completion) is unchanged: when a song actually
    finishes, the queue empties → `currentEntry == nil` → the monitor
    tick detector swaps.
