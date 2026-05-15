# Progress

> Read `PLAN.md` then this file to get up to speed. Newest entries on top.

## Status: Milestone 1 — code complete, build-verified, runtime unverified

### Done
- Planning docs: `PLAN.md`, `plans/architecture.md`, `plans/project-setup.md`,
  `plans/musickit-notes.md`, `plans/milestone-1.md`, `plans/typography.md`.
- Skills consulted: `swiftui-pro` (pre + post code review), `macos-design`,
  `typography-designer`. Decisions captured in `plans/`.
- XcodeGen project (`project.yml`), Info.plist (`NSAppleMusicUsageDescription`),
  entitlements (sandbox + network client), `.gitignore`. Scaffold built clean.
- Milestone 1 implemented end to end:
  - Models: PlaylistSource, PlaylistSummary, PlaylistDetail, TrackRow,
    PlayerStateSnapshot, UserPlaylistMetadata.
  - Music: MusicAuthorizationService, MusicSubscriptionService,
    PlaylistLibraryService (paginated), PlaylistDetailService (lazy + cached),
    PlaybackService (thin ApplicationMusicPlayer wrapper), MusicController
    coordinator, MusicContext + MusicCommand (M3 boundary scaffolded).
  - Persistence: UserPreferencesStore (last-selected playlist).
  - Views: RootView, AuthorizationView, MainShellView (NavigationSplitView +
    bottom NowPlayingBar), PlaylistSidebar/Row, PlaylistDetailView,
    PlaylistHeaderView, TrackTableView (native Table, double-click/Return →
    play from track), NowPlayingBar, TransportControls, ArtworkThumbnail.
- **Build verified**: `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` →
  BUILD SUCCEEDED, no errors or Swift warnings (Swift 6 strict concurrency).
- `swiftui-pro` post-code pass applied: extracted duplicated artwork into a
  reusable `ArtworkThumbnail` struct; moved button logic out of view bodies
  into methods (AuthorizationView, PlaylistDetailView). Re-verified clean.

### Known caveats / NOT verified
- **Runtime playback is unverified.** CLI builds disable code signing (only a
  "Developer ID Application" cert exists; no Mac Development cert). Actually
  running the app + exercising MusicKit auth/library/playback requires running
  from Xcode signed into the Apple ID **and** the `org.sockpuppet.djroomba`
  App ID having MusicKit enabled. See `plans/project-setup.md`. The First
  Milestone "definition of done" is met in code; live playback has not been
  exercised here and should not be claimed as verified.
- `nonisolated(unsafe)` on `ApplicationMusicPlayer.shared` in PlaybackService:
  MusicKit isn't Sendable-audited and its async transport is `nonisolated`;
  all our access is MainActor-serialized so this is sound (see
  `plans/musickit-notes.md`). Revisit when MusicKit gains Sendable.
- `PlaylistSummary.trackCount` and `isEditable` are `nil` (a library request
  doesn't load tracks; editability isn't cleanly exposed on macOS 14). The
  sidebar tolerates this; counts show in the detail header instead.
- Playlist `description` not surfaced yet (API shape uncertainty) — left nil.
- SourceKit shows stale "cannot find type" diagnostics across files; ignore —
  every real `swiftc` build passes. They clear with a fresh index.
- No unit tests yet (swiftui-pro hygiene gap) — candidate for M2.

### Next (Milestone 2 — "Make it pleasant")
- Favorites + Recently Played sections; FavoritesStore/RecentlyPlayedStore.
- Playlist filtering + in-playlist track filtering (⌘F).
- Persist window/sidebar state; full keyboard map + focus management.
- Improve empty/loading/error polish; add `#Preview`s; add a test target.

### Process notes
- No commits yet (repo had no history). Will not commit/push or merge without
  being asked; **never merge to `main`** (CLAUDE.md). Build with:
  `xcodegen generate && xcodebuild -project DJRoomba.xcodeproj -scheme DJRoomba
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
