# MusicKit on macOS — notes & gotchas

Target: macOS 14.0+. MusicKit's `ApplicationMusicPlayer`, `MusicAuthorization`,
`MusicSubscription`, and `MusicLibraryRequest` are all macOS 14+ available.

## Authorization

- `MusicAuthorization.currentStatus` → `.notDetermined | .denied | .restricted
  | .authorized`.
- `await MusicAuthorization.request()` triggers the system prompt; needs
  `NSAppleMusicUsageDescription` in Info.plist or it crashes.
- Authorized ≠ can play. Catalog playback also needs an active subscription.

## Subscription / capability

- `for await subscription in MusicSubscription.subscriptionUpdates { ... }`.
- `subscription.canPlayCatalogContent` — gate catalog playback / explain
  disabled Play buttons.
- `subscription.canBecomeSubscriber` — offer/explain, do not nag.
- Library browsing can still work without catalog playback.

## Loading library playlists

- Prefer `MusicLibraryRequest<Playlist>` (library-scoped) over a generic
  `MusicCatalogResourceRequest` so we get the *user's* playlists, not catalog.
- Pagination: request has `limit`/`offset`-style chunking; loop until the
  returned collection is exhausted. Handle empty collection explicitly.
- `Playlist` fields can be nil: `artwork`, `tracks` (not loaded until detailed),
  `lastModifiedDate`, `isEditable`. Treat all as optional in the UI.
- Keep stable `playlist.id` (`MusicItemID`) as the app-local key for selection,
  favorites, recents.

### Playlist *folders* — no discriminator (signed probe, 2026-05-17)

`MusicLibraryRequest<Playlist>` returns Music.app **playlist folders**
(hierarchical containers, e.g. "AAA ME") as ordinary `Playlist` values,
**indistinguishable from real playlists**. Throwaway signed
`PlaylistFolderProbe` over the real 270-playlist library (reverted; only
this finding kept — the `GenreProbe` precedent):

- For **all 270**: `kind` nil, `curatorName` nil, `lastModifiedDate` nil,
  `hasArtwork` true. `Mirror` children are only `id` +
  `propertyProvider` (opaque `LegacySectionedCollectionBackedProperty‑
  Provider`). `String(reflecting:)` yields only
  `Playlist(id, name, isChart: false)`. The folder "AAA ME" is
  **byte-for-byte identical** to the neighbouring real playlist.
- ⇒ There is **no MusicKit-public folder/parent/`isFolder`/kind signal**
  — not in the API, the `Mirror`, or the debug description. Folder
  detection cannot be done from MusicKit; it needs an external source
  (iTunesLibrary.framework `ITLibPlaylist.kind == .folder` / `parentID`,
  or ScriptingBridge) or a content heuristic.
- A folder's `playlist.with([.entries])` (and likely deep `.tracks`)
  **hangs the MainActor** in the probe — so folders must be excluded
  *before* the per-playlist fetch, not filtered after.
- Side finding: `lastModifiedDate` is nil for **all 270** → the
  incremental-import change token is always nil on this macOS library;
  incremental import silently degrades to full re-import here (the
  caveat in `data-and-import.md` "Incremental import" — now empirically
  confirmed, not a regression).
- **Resolution (Option A, `plans/playlist-folders.md`):** detect folders
  out-of-band via iTunesLibrary.framework `ITLibPlaylist.kind == .folder`,
  joined to the MusicKit `Playlist.id` by the `String(Int64(bitPattern:
  persistentID))` decimal id mapping, gated by the
  `com.apple.security.assets.music.read-only` entitlement; folders are
  skipped before the per-playlist fetch and existing snapshots converged.

## Loading playlist tracks (lazy, on selection)

- `try await playlist.with([.tracks])` (or `.entries`) returns a detailed
  playlist; iterate `detailed.tracks`. Some entries may be unavailable —
  tolerate nil song/metadata.
- Cache the resulting `[TrackRow]` in memory keyed by playlist id; invalidate
  on manual refresh. Do **not** prefetch tracks for all playlists at startup.

## Playback

- `ApplicationMusicPlayer.shared` (singleton; queue + transport).
- Play whole playlist: set `player.queue = [playlist]` (or
  `ApplicationMusicPlayer.Queue(for: playlist)`), then `try await player.play()`.
- Play from a specific track: construct the queue from the playlist's tracks
  with `startingAt:` the chosen entry so playlist context is preserved.
- Transport: `play()`, `pause()`, `stop()`, `skipToNextEntry()`,
  `skipToPreviousEntry()`. Seeking: `player.playbackTime` — treat as best-effort.
- State: `player.state` (`playbackStatus`) and `player.queue.currentEntry` are
  `@Observable`-friendly; bind UI to them rather than inventing app playback
  state. `player.state` is observable; prefer observation over a polling timer,
  but elapsed time may still need a light timer (acceptable, keep it simple).

## Identity & metadata risks

- Library playlist IDs and catalog playlist IDs are different namespaces — do
  not treat as interchangeable. Prefer user-library when ambiguous.
- A playlist present at last launch may be gone — handle "playlist disappeared"
  when restoring persisted selection.
- Region/catalog-unavailable songs: show an indicator, don't crash the queue.

## Known macOS-specific rough edges

- Many MusicKit code samples are iOS-first; API *shapes* match but availability
  and some artwork/URL helpers differ. Verify each API against macOS 14 at use
  site rather than trusting iOS examples.
- Artwork: use `ArtworkImage` (MusicKit's SwiftUI view) where possible; it
  handles the `Artwork` → image resolution. Falls back gracefully when nil.
