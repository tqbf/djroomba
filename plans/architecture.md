# Architecture

## Local-first pivot (post-M2)

The app became a local-first manager. **SQLite (GRDB) is the source of
truth.** Apple Music is read-only import + the playback engine. New layering:

```
Views ─observe─▶ MusicController (@Observable @MainActor)
                     │ owns
   ┌─────────────────┼───────────────────────────────────┐
   │ MusicAuthorizationService / MusicSubscriptionService │ ── MusicKit
   │ ImportService   (MusicKit read ─▶ upsert SQLite)     │ ──▶ Apple Music
   │ LibraryStore    (GRDB; reads/writes the DB)           │
   │ PlaybackService (ApplicationMusicPlayer)              │ ── MusicKit
   │ PlaybackResolver(MusicItemID ─▶ Song/Track at play)   │ ── MusicKit
   └───────────────────────────────────┬───────────────────┘
                                        ▼
                         SQLite (GRDB): imported snapshot,
                         app playlists, play counts, favorites,
                         recents, prefs  — the source of truth
```

Key changes vs M1/M2 (**realized in Phase 3 — code-complete**):
- `PlaylistLibraryService` **deleted**; sidebar reads SQLite via the new
  `LibraryReadService`. `PlaylistDetailService` rewritten to read
  `LibraryStore.songs(inApplePlaylist:)` (no live MusicKit). MusicKit reads
  now happen only in `ImportService`.
- Models no longer carry the live MusicKit object. `PlaylistSummary` /
  `PlaylistDetail` / `TrackRow` / `PlayerStateSnapshot` / `MusicContext` /
  `MusicCommand` are plain `Sendable` values carrying stored ids (`String`)
  + display fields + a computed `artworkRef`. `TrackRow` carries
  `musicItemID` + `namespace` (set by import **provenance**, `.library`);
  `PlaybackResolver` re-fetches `Song` by id via `MusicLibraryRequest`
  just before building the `ApplicationMusicPlayer.Queue` (the
  `MusicCatalogResourceRequest` branch is dormant — nothing
  catalog-namespace is imported; the two spaces are still not
  interchangeable, provenance decides which).
- `FavoritesStore`/`RecentlyPlayedStore` **deleted**; favorites/recents are
  SQLite-backed via `LibraryStore`, one-shot migrated by
  `LegacyPreferencesMigration` (no dual write). `UserPreferencesStore`
  (last selection) stays in UserDefaults by design.
- One-way only: **no write-back to Apple.** App playlists/play-counts never
  leave SQLite.

Phase 4 additions (code-complete, runtime-unverified):
- `AppPlaylistService` (`@MainActor @Observable`) — owns the user-owned
  "My Playlists": listing + create/rename/delete/add/remove/reorder, each a
  coarse `LibraryStore` batch op in one transaction, reloaded from SQLite
  after the write. The one-way isolation (app edits never touch
  `apple_playlist*`/song/stat/history) is enforced by the store and proven by
  `AppPlaylistCRUDTests`. **No schema change** — the Phase-2 `app_playlist*`
  tables + v1 cascade FK sufficed.
- `MusicController` now branches playback on `PlaylistDetail.isAppOwned`:
  imported Apple playlists → `PlaybackResolver.resolvePlaylist` (playlist-
  granularity, the proven path); app playlists → `resolveAppPlaylist`
  (per-id 1:1 `equalTo` re-resolve through a bounded `TaskGroup`, keyed by
  the stored id, tolerant). Both feed the **unchanged** `PlaybackService`.
- Play tracking fires on the player's confirmed `.playing` transition
  (`PlaybackService.play` returns `Bool`; `confirmPlaybackStarted` polls the
  player's own status), recording the resolver-reported stored `song.id` —
  fixing the Phase-3 stale-snapshot bug.
- `selectedPlaylistID` / selection-restore / favorites / recents now span
  `allSummaries` (imported + app). Track rows are `Transferable`
  (`SongDragItem`, app-scoped exported UTI) for drag-into-playlist.

Phase 4 UI corrective (view/reactivity-only; data layer/playback/schema
untouched):
- **Inline rename focus timing** — *SUPERSEDED by the Phase-4 D1 robustness
  fix below; kept for audit history.* `AppPlaylistSidebarRow` requested
  `@FocusState` only **after** `await Task.yield()` inside `.task(id:
  isRenaming)`, so the conditionally-inserted `TextField`'s `.focused`
  binding was registered before focus was assigned (setting it in the same
  pass was a no-op). Select-all on focus-gain via the key window's field
  editor (`@MainActor` AppKit; macOS 14 has no SwiftUI text-selection API).
  Double-click started rename via `.simultaneousGesture(TapGesture(count:
  2))` on `AppPlaylistRowItem` (alongside the context-menu "Rename").
  *This still failed the signed stickler bar:* the double-click collided
  with the `List`'s double-click/Return "play this playlist" (M2), and the
  `@FocusState` blur-commit inside a conditionally-swapped `TextField` in a
  `List(selection:)` was timing-fragile (the List competes for first
  responder), so commit was inconsistent across triggers.

Phase 4 D1 robustness fix (replaces the inline rename above;
view/presentation-only; playback/data layer/schema/D2/D3/D4 untouched):
- **Rename is now a modal sheet, context-menu-triggered.** The
  double-click `.simultaneousGesture` is removed (double-click on a
  My-Playlists row now does only what it does on every sidebar row —
  select/play; no collision). Rename opens `RenamePlaylistSheet` via
  `AppPlaylistSidebarSection`'s `sheet(item: $renameRequest)` (a
  `PlaylistRenameRequest` `Identifiable` value). A sheet's `TextField` is
  the sole first responder so focus + the AppKit field-editor select-all
  are deterministic (no `List` competition — the old fragility's root
  cause), and commit is an explicit, identical Rename (default button /
  Return) or Cancel (Esc / Cancel) **every time, trigger-independent**.
  `AppPlaylistSidebarRow` reverted to a plain non-editing row.
  `MusicController.renameAppPlaylist` (→ `AppPlaylistService.rename` →
  `LibraryStore.renameAppPlaylist`) is the unchanged, still-tested commit
  path. The new-playlist flow still drops into rename (create → the row
  lands in `summaries` → the sheet opens via `.onChange(of: summaries)`,
  deterministic against the async store reload).
- **`PlaylistSummary` equality** now compares `id` + `isFavorite` +
  `trackCount` + `name` (was id + favorite only). The omitted fields made
  SwiftUI's `ForEach` diff a count/name-only change as "unchanged" so the
  reloaded "My Playlists" row never re-rendered — the stale-count defect.
  Hash stays **id-only** (Hashable contract: `==` still implies equal `id`;
  no `Set`/dictionary-key usage of the type).
- **`PlaylistDetailService.refreshStats(for:)`** — re-runs the single
  `songsWithStats` LEFT JOIN once and splices the fresh `playCount`/
  `lastPlayedAt` into the cached rows (membership/order unchanged). Driven
  by **discrete events only**: `MusicController.recordPlayStart` after
  `store.recordPlay`, and `select()` on a cache hit (serve cached rows
  instantly, then one background stats refresh). No refresh loop, no per-
  tick / per-row re-query; the now-playing 0.5 s snapshot poll is untouched.
  A failed stats refresh is non-fatal (rows stay; no error for a count
  update).

Schema, import pipeline, and playback resolution detail live in
`plans/data-and-import.md`.

## Layers (original M1/M2 — being re-pointed at SQLite)

```
Views  ──observe──▶  MusicController (@Observable @MainActor)
                          │ owns
                          ▼
        ┌──────────────── services ────────────────┐
        │ MusicAuthorizationService                 │
        │ MusicSubscriptionService                  │
        │ PlaylistLibraryService   ── MusicKit ──▶  │  Apple Music
        │ PlaylistDetailService                     │
        │ PlaybackService (ApplicationMusicPlayer)   │
        └───────────────────────────────────────────┘
                          │ uses
                          ▼
        Persistence (UserDefaults-backed stores: favorites,
        recents, last selection, prefs) — app state only
```

`MusicController` is the single root `@Observable` model. It owns service
instances and the app-level state the UI binds to (auth status, capabilities,
playlist summaries, selected playlist + its detail, now-playing snapshot,
loading/error states). It coordinates startup (`bootstrap()`) but delegates
fetching to services — it is a coordinator, not a god object.

## Data flow rules (from swiftui-pro)

- All shared state is `@Observable` classes, `@MainActor`-annotated.
- Root view owns `MusicController` via `@State private`; passed down via
  `.environment(...)` and read with `@Environment(MusicController.self)`.
- No `ObservableObject` / `@Published` / `@StateObject` / `@ObservedObject`.
- No `@AppStorage` inside `@Observable` classes — persistence stores read/write
  `UserDefaults` explicitly and expose plain properties the controller mirrors.
- Bindings come from `@State`/`@Bindable`; no `Binding(get:set:)` in bodies.
- Logic lives in methods, not inline in `body`.

## Concurrency

- Swift 6 strict concurrency. Services are `@MainActor` (MusicKit types are
  largely main-actor-friendly and our data volumes are small); heavy paging
  loops use `async` and yield, not background queues.
- `async`/`await` only. No `DispatchQueue`. No `Task.detached` without cause.
- `Task.sleep(for:)` never the nanoseconds form.

## Module / file layout

Mirrors the spec. One type per file (swiftui-pro hygiene rule).

```
App/        PlaylistPlayerApp.swift, AppState (folded into MusicController)
Music/      MusicController, MusicAuthorizationService,
            MusicSubscriptionService, ImportService, LibraryReadService,
            AppPlaylistService, PlaylistDetailService, PlaybackResolver,
            PlaybackService, MusicContext, MusicCommand
Models/     PlaylistSummary, PlaylistDetail, TrackRow, SongDragItem,
            PlaylistRenameRequest, PlayerStateSnapshot,
            UserPlaylistMetadata, PlaylistSource,
            LibrarySidebarState (Phase 5 — empty/error cause inference)
Views/      RootView, AuthorizationView, ArtworkThumbnail,
            ArtworkProvider, MainShellView,
            ExtensionInspectorView (Phase 5 — the .inspector() surface),
            (ArtworkImageLoader deleted in the Phase 3 corrective —
             superseded by ArtworkProvider + MusicKit ArtworkImage)
            Sidebar/  PlaylistSidebar(+List/Section/Row),
                      AppPlaylistSidebarSection/RowItem/Row (Phase 4),
                      RenamePlaylistSheet (Phase-4 D1: modal rename),
                      SidebarUnavailableView (Phase 5 — cause-specific
                      empty/error ContentUnavailableView)
            Playlist/ PlaylistDetailView, PlaylistHeaderView, TrackTableView,
                      TrackContextMenu (Phase 4)
            Player/   NowPlayingBar, TransportControls
Persistence/ LibraryStore, LegacyPreferencesMigration,
             UserPreferencesStore, Database/(AppDatabase, LibraryMigrator),
             Records/(one Codable record per table)
             (FavoritesStore / RecentlyPlayedStore deleted in Phase 3 —
              superseded by SQLite + LegacyPreferencesMigration)
```

## Model layer (Phase 3 — de-MusicKit'd, local-first)

Plain `Sendable` value types read from SQLite. They carry **no** live
MusicKit object (the post-pivot rule); playback re-resolves ids via
`PlaybackResolver` and artwork via `ArtworkProvider` at use time. Id-based
re-resolution is the *intended* design — SQLite owns identity, Apple is
re-queried on demand; the id stored is the underlying item's **library**
id (provenance), the Phase 3 corrective that fixed the broken round trip.

After the Phase 3 corrective, artwork is **not** a stored URL on any model
— each exposes a computed `artworkRef: ArtworkRef?` (the stored
`MusicItemID` + namespace + owning kind) which `ArtworkProvider` re-resolves
to a live `MusicKit.Artwork` for `ArtworkImage` (D2).

- `PlaylistSummary` — sidebar row; `id: String` (apple_playlist/app id),
  name, trackCount?, isEditable?, `source`, `isFavorite`, computed
  `artworkRef` (`.playlist(id)` for an imported Apple list). Equality by id
  (+ favorite so the star re-renders).
- `PlaylistDetail` — lazy on selection; id, name, `isAppleLibraryPlaylist`,
  description, tracks, computed `artworkRef`. Built from
  `LibraryStore.songs(inApplePlaylist:)`.
- `TrackRow` — `Identifiable, Hashable`; `songID` (FK target for
  `recordPlay`), `musicItemID` + `namespace` (for re-resolve), title,
  artistName, albumTitle?, duration?, isExplicit, **`playCount` +
  `lastPlayedAt`** (Phase 4, from the `songsWithStats` LEFT JOIN — the
  sortable Table columns) + non-optional `*SortKey` keys for the native
  header sort, computed `artworkRef` (`.song(musicItemID, namespace:)`).
  `id` is `"<position>-<songID>"` so a doubled song still has unique row
  identity.
- `PlaylistDetail`/`PlaylistSummary` carry a `PlaylistSource`;
  `.appPlaylist` (Phase 4) marks a user-owned, SQLite-only, editable list
  (`isAppOwned`) whose playback uses the per-song path.
- `SongDragItem` — `Transferable` carrying just `song.id`, over a private
  app-scoped exported UTI (`org.sockpuppet.djroomba.song`) so a dragged
  track lands in a "My Playlists" row and nowhere else.
- `PlayerStateSnapshot` — derived from MusicKit player state but stored as a
  plain value: status, title/artist, elapsed/duration, playlist context id
  + now-playing id (both `String`), computed `artworkRef` from the
  now-playing id.
- `UserPlaylistMetadata` — local-only: isFavorite, lastPlayed, pinned (later).

## Services

- **MusicAuthorizationService** — wraps `MusicAuthorization`; exposes status
  and a `request()` that maps to the spec's auth states (notDetermined,
  authorized, denied/restricted, authorized-but-no-playback,
  authorized-but-empty-library is a controller-level concern).
- **MusicSubscriptionService** — observes `MusicSubscription.subscriptionUpdates`;
  surfaces canPlayCatalogContent / canBecomeSubscriber so play buttons can
  explain *why* they're disabled rather than silently failing.
- **ImportService** (Phase 3) — the *only* place MusicKit library reads
  happen now. Paged `MusicLibraryRequest<Playlist>` + per-playlist
  `with([.tracks])` paging → one-way upsert into SQLite. (Replaces M1's
  `PlaylistLibraryService`, which was deleted.)
- **LibraryReadService** (Phase 3) — reads the sidebar's imported
  `[PlaylistSummary]` from `LibraryStore.applePlaylists()` (NOT MusicKit).
- **AppPlaylistService** (Phase 4) — owns the user-owned "My Playlists":
  the SQLite-only `[PlaylistSummary]` listing + create/rename/delete/add/
  remove/reorder CRUD (all batch, one-way isolated). Awaits the off-main
  store; reloads from SQLite after each write.
- **PlaylistDetailService** (Phase 3, rewritten; Phase 4 + corrective) —
  loads a playlist's `[TrackRow]` from `LibraryStore.songsWithStats(in…)`
  (stats joined in the one query); in-memory cache keyed by playlist id,
  invalidated on import/refresh and on any app-playlist membership mutation.
  `refreshStats(for:)` re-runs the join on the discrete play-recorded /
  (re)selection events and splices fresh `playCount`/`lastPlayedAt` into the
  cached rows so the table's Plays/Last Played stay current (no tick loop).
- **PlaybackResolver** (Phase 3 D1-corrected; Phase 4 extended) — two
  paths: `resolvePlaylist` re-resolves an imported Apple playlist at
  **playlist granularity** by its stored library id (the proven path);
  `resolveAppPlaylist` (Phase 4) re-resolves an arbitrary user playlist
  **per-song 1:1** via `MusicLibraryRequest<Song>.filter(\.id, equalTo:)`
  one id at a time through a bounded `TaskGroup`, keyed by the stored id.
  Both tolerate unresolvable tracks (inline `playbackProblem`) and report
  the started track's stored `song.id` for play recording. The catalog
  request stays dormant (no catalog imports).
- **ArtworkProvider** (Phase 3, D2 corrective) — `actor` that re-resolves a
  live `MusicKit.Artwork` from a stored id (cached, deduped, negative-
  cached) for `ArtworkThumbnail`'s `ArtworkImage`. Replaced the deleted
  `ArtworkImageLoader` (the unfetchable private-URL path).
- **PlaybackService** — thin wrapper over `ApplicationMusicPlayer.shared`,
  **unchanged from M1** except it now takes resolved `MusicKit.Song`s from
  the resolver: set queue, set queue starting at a song, play/pause/skip,
  observable `PlayerStateSnapshot` from the player's `state`/`queue`.

## Extension boundary (Milestone 3, designed now so it isn't bolted on)

Phase 3 note: the boundary now carries **`String` ids** (not
`MusicItemID`) — local-first, no live MusicKit identity types leak across
it. Shape:

```swift
struct MusicContext {            // read-only projection
    var selectedPlaylistID: String?
    var selectedSongID: String?
    var nowPlayingSongID: String?
    var queuePlaylistID: String?
    var playbackStatus: PlayerStateSnapshot.Status
}

enum MusicCommand {              // the only way extensions act
    case playPlaylist(String)
    case playTrack(String, playlistID: String?)
    case pause, resume, skipNext, skipPrevious
}
```

Extensions observe `MusicContext` and submit `MusicCommand`s to the controller.
They never import or touch `ApplicationMusicPlayer`. Extension code stays out of
the MusicKit service classes.

### Phase 5 — the boundary realized as a collapsible `.inspector()`

The M3 boundary is no longer just a scaffold — `ExtensionInspectorView` is a
real native macOS-14 `.inspector(isPresented:)` panel on `MainShellView`,
**collapsed by default** (`@SceneStorage "inspectorPresented" = false`,
per-scene persisted) and toggled from a trailing toolbar button
(`sidebar.trailing` — the standard inspector idiom). It is the **reference
implementation of the extension contract**: a `Form`/`Section`/
`LabeledContent` surface that *only* reads `controller.musicContext` (the
read-only projection) and *only* acts by `controller.handle(_:)` with a
`MusicCommand`. It imports no MusicKit, never references
`ApplicationMusicPlayer`/`PlaybackService`/`LibraryStore` — a future
extension bolts on by doing exactly this.

`MusicContext` was enriched (Phase 5) with display fields
(`selectedPlaylistName`, `nowPlayingTitle`, `nowPlayingArtist`) + an
`isPlaying` convenience and made `Equatable`, so a consumer renders something
human-readable without re-querying across the boundary — still **plain
`Sendable` `String?`s + the local `Status` enum, zero MusicKit identity
types** (`PlayerStateSnapshot.Status` is now `Equatable`). The command set
stays the closed `MusicCommand` enum (the only way to act). Boundary value
semantics are unit-tested (`MusicContextBoundaryTests`).

## Empty/error-state cause inference (Phase 5)

`LibrarySidebarState` is a pure, `Sendable`, unit-tested classifier
(`resolve(...)`) that turns the signals `MusicController` already tracks
(summary counts, `isLibraryBusy`, `libraryProblem`, and the
`MusicSubscription` cross-check incl. `hasCloudLibraryEnabled`) into the
*cause* of an empty/error sidebar — `.libraryNotSynced` /
`.subscriptionNeeded` / `.noImportedPlaylists` / `.error` / `.loading` /
`.populated`. `controller.sidebarState` exposes it; `PlaylistSidebar` routes
on it; `SidebarUnavailableView` renders the matching native non-modal
`ContentUnavailableView` with the fixing action. The decision is out of the
view `body` (swiftui-pro) and testable without a live MusicKit session
(`LibrarySidebarStateTests`). This is why an unsynced library now reads
"Library Not Synced to This Mac" instead of a blanket "No Playlists".

## Import performance shape (Phase 5, corrected)

`ImportService.runImport` is a **strictly serial** structured-concurrency
loop: for each library playlist, page its tracks via the
`nonisolated static fetchTracks(...)` helper (MusicKit paging off the
`@MainActor`), then `writePlaylist(...)` maps + writes it on the batched
UPSERT + transactional `replaceApplePlaylistSnapshot` path, then advance the
progress count. One playlist in flight at a time.
`importedPlaylistCount`/`totalPlaylistCount` drive the sidebar's "Importing
N of M playlists…" affordance.

**Honest measured performance finding (the Phase-5 corrective).** A
bounded-parallel `TaskGroup` (sliding window of 6) over the per-playlist
fetches was tried and **measured ineffective** on the signed build: a full
re-import of a ~270-playlist / ~8200-track library ran **~90–120 s — no
improvement over the prior serial ~88 s, slightly worse**, and it added
instability (CPU past one core, a transient inconsistent read). The
bottleneck is **not** SQLite (the batch write idioms are correct and tested)
and **not** concurrency-limited: it is MusicKit's own per-playlist track
resolution on macOS (`playlist.with([.tracks])` + `nextBatch()` paging,
CPU-bound and internally serialized — one very large library playlist alone
is an indivisible long task, and concurrent `with([.tracks])` calls contend
on MusicKit's internal machinery rather than overlapping). App-side
parallelism cannot fix it, so the `TaskGroup` was **reverted to the simple
serial loop**, keeping only the harmless progress affordance. The ~90–120 s
full re-import is **accepted as the v1 cost** — it is a one-time /
Refresh-only operation, mitigated only by the progress UI. (Any earlier
"~88 s → ~20–35 s" estimate was unmeasured and is wrong; struck everywhere.)
The one-way isolation guarantees (`AppPlaylistCRUDTests`/`SnapshotReplace
Tests`/`BatchImportTests`) are not regressed — the write path is byte-for-
byte unchanged. Incremental import was investigated (`Playlist.
lastModifiedDate` exists but is macOS-14-unreliable) and deliberately
deferred — faking that signal would risk a stale snapshot.

## Error handling

Surface inline (not modal alerts) for routine MusicKit failures: auth denied,
no catalog playback, network down, playlist disappeared/unloadable, track
unplayable, queue failed to start, empty playlist, partial metadata. Use
`ContentUnavailableView` for empty/error content states (macOS 14).

## Risks (carry forward)

- **Library vs catalog identity mismatch** — never assume IDs interchangeable;
  prefer user-library playlists when ambiguous.
- **Partial metadata** — every displayed field must tolerate `nil`.
- **Playback capability ambiguity** — authorized ≠ playable; always check
  subscription + handle play failures.
- **Queue drift** — MusicKit owns the queue; app context is advisory until
  confirmed by player state.
- **macOS-specific rough edges** — many MusicKit samples are iOS-first.
