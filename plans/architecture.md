# Architecture

## Layers

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
Music/      MusicController, *Service, MusicContext, MusicCommand
Models/     PlaylistSummary, PlaylistDetail, TrackRow,
            PlayerStateSnapshot, UserPlaylistMetadata, PlaylistSource
Views/      RootView, AuthorizationView,
            Sidebar/  PlaylistSidebar, PlaylistSidebarRow
            Playlist/ PlaylistDetailView, PlaylistHeaderView, TrackTableView
            Player/   NowPlayingBar, TransportControls
            Extension/ ExtensionInspectorView
Persistence/ FavoritesStore, RecentlyPlayedStore, UserPreferencesStore,
             LocalLibraryCache (later)
```

## Model layer

UI-focused value types that wrap MusicKit entities but keep the underlying
`Song`/`Playlist` available for playback (avoid stringly-typed re-resolution).

- `PlaylistSummary` — sidebar row; `id: MusicItemID`, name, artwork, trackCount?,
  isEditable?, `source: PlaylistSource` (libraryUser / libraryCatalog / catalog),
  `isFavorite` (merged from local store).
- `PlaylistDetail` — lazy on selection; id, name, artwork, description, tracks.
- `TrackRow` — `Identifiable, Hashable`; title, artistName, albumTitle?,
  duration?, artwork?, and `musicItem: Song` retained for playback.
- `PlayerStateSnapshot` — derived from MusicKit player state, not app-invented:
  status, current entry title/artist/artwork, elapsed/duration, playlist context.
- `UserPlaylistMetadata` — local-only: isFavorite, lastPlayed, pinned (later).

## Services

- **MusicAuthorizationService** — wraps `MusicAuthorization`; exposes status
  and a `request()` that maps to the spec's auth states (notDetermined,
  authorized, denied/restricted, authorized-but-no-playback,
  authorized-but-empty-library is a controller-level concern).
- **MusicSubscriptionService** — observes `MusicSubscription.subscriptionUpdates`;
  surfaces canPlayCatalogContent / canBecomeSubscriber so play buttons can
  explain *why* they're disabled rather than silently failing.
- **PlaylistLibraryService** — `MusicLibraryRequest<Playlist>` (preferred on
  macOS 14) with pagination; normalizes to `[PlaylistSummary]`; merges favorites.
- **PlaylistDetailService** — loads a playlist's tracks lazily
  (`playlist.with([.tracks])` / detailed request), normalizes to `[TrackRow]`,
  in-memory cache keyed by playlist id, invalidated on refresh.
- **PlaybackService** — thin wrapper over `ApplicationMusicPlayer.shared`:
  set queue from playlist, set queue starting at a track, play/pause/skip,
  and an observable `PlayerStateSnapshot` driven by the player's
  `state`/`queue` (Observation, not a polling timer where avoidable).

## Extension boundary (Milestone 3, designed now so it isn't bolted on)

```swift
struct MusicContext {            // read-only projection
    var selectedPlaylistID: MusicItemID?
    var selectedSongID: MusicItemID?
    var nowPlayingSongID: MusicItemID?
    var queuePlaylistID: MusicItemID?
    var playbackStatus: MusicPlayer.PlaybackStatus
}

enum MusicCommand {              // the only way extensions act
    case playPlaylist(MusicItemID)
    case playTrack(MusicItemID, playlistID: MusicItemID?)
    case pause, resume, skipNext, skipPrevious
}
```

Extensions observe `MusicContext` and submit `MusicCommand`s to the controller.
They never import or touch `ApplicationMusicPlayer`. Extension code stays out of
the MusicKit service classes.

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
