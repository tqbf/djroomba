# Milestone 1 — Play a library playlist

## Definition of done (from spec)

- App launches.
- Requests MusicKit authorization.
- Loads the user's library playlists.
- Displays playlists in a sidebar.
- Selecting a playlist loads its tracks.
- Pressing Play starts playback with `ApplicationMusicPlayer`.
- Double-clicking a track starts playback at that track.
- Now-playing bar reflects playback status.

No catalog search, no playlist editing, no queue editor.

## Implementation order (spec steps 1–12)

1. XcodeGen project + plist usage string + entitlements.  ← project-setup.md
2. `AuthorizationView` + `MusicAuthorizationService`.
3. `MusicController.bootstrap()` — auth → subscription → load playlists.
4. `PlaylistLibraryService` fetch (paginated) → `[PlaylistSummary]`.
5. `PlaylistSidebar` + `PlaylistSidebarRow`, sorted by name.
6. Persist + restore selected playlist id (`UserPreferencesStore`).
7. `PlaylistDetailService` lazy track fetch → `[TrackRow]`, in-memory cache.
8. `PlaylistDetailView` + `TrackTableView` (native `Table`).
9. Play playlist (`PlaybackService.play(playlist:)`).
10. Play from selected track (`PlaybackService.play(playlist:startingAt:)`).
11. `NowPlayingBar` bound to `PlayerStateSnapshot`.
12. `TransportControls` (play/pause, next, prev).

## View structure

`RootView` switches on auth status:

- `.notDetermined` → `AuthorizationView` (single primary CTA → request).
- `.denied`/`.restricted` → `AuthorizationView` in explain/Settings-link state.
- `.authorized` → main shell:
  - `NavigationSplitView { PlaylistSidebar } detail: { PlaylistDetailView }`
  - `.safeAreaInset(edge: .bottom) { NowPlayingBar }` — always visible,
    never gated behind navigation state.
  - `.inspector(...)` placeholder reserved (built out in Milestone 3; keep
    hidden/collapsed now).
  - Toolbar: playlist filter field (wired in M2), Refresh (`⌘R`).

## States to handle now

- Authorized but no usable library playlists → `ContentUnavailableView`
  ("No playlists in your library") in the sidebar/detail.
- Authorized but cannot play catalog content → playlists still browse; Play
  buttons disabled with a short inline reason (not a modal).
- Empty playlist, playlist failed to load, track unplayable → inline.
- Playlist selected at launch no longer exists → clear selection silently.

## Keyboard (subset now; full set in M2)

- Space: play/pause. Return: play selected playlist/track. `⌘R`: refresh.
  (Full shortcut set + focus management is Milestone 2.)

## Out of scope for M1 (do not build yet)

Favorites/recents sections, filtering, full keyboard map, window-state
persistence, extension inspector contents, catalog search, any mutation.

## Verification

`xcodebuild ... build` clean. Then a `swiftui-pro` review pass over the new
Swift files; fix findings. Update PROGRESS.md. Manual run is signing-dependent
(see project-setup.md) — note runtime status honestly in PROGRESS.md rather
than claiming verified playback if it could not be exercised.
