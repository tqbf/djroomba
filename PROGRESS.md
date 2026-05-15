# Progress

> Resume protocol: read `PLAN.md` (decisions + milestone index) then this
> file. `plans/roadmap.md` is the forward plan; `plans/risks-and-challenges.md`
> is the live risk register. Newest status on top.

## Current status: planning consolidated — Phase 1 (access validation) is next

The project pivoted to **local-first** (SQLite-owned library, native MusicKit
as import + playback only). All planning docs are written and consolidated.
No Phase-1+ code started yet — by design, Phase 1 is a validation gate.

## Decisions locked

- **Identity:** native MusicKit, system Apple Account ("Option A"). No in-app
  login. User has an ADC membership and has used MusicKit before.
- **Local store:** SQLite via **GRDB** (SPM through XcodeGen).
- **Data ownership:** app owns playlists, play counts, favorites, recents,
  metadata in SQLite. One-way import from Apple. **No write-back to Apple.**
- **Playback:** native `ApplicationMusicPlayer`, in-process; stored
  `MusicItemID`s re-resolved at play time. Requires active subscription.
- **Tooling/identity:** XcodeGen; macOS 14 min (built on Xcode 26.4 / Swift
  6.3); app "DJ Roomba" / `org.sockpuppet.djroomba` / team `KK7E9G89GW`.

## Done to date

**Scaffold & M1 ("Play a library playlist") — code complete.**
XcodeGen project, Info.plist (`NSAppleMusicUsageDescription`), sandbox+network
entitlements, `.gitignore`. Full model/service/view layer: authorization,
subscription, paginated library load, lazy+cached detail, thin
`ApplicationMusicPlayer` wrapper, `MusicController` coordinator,
`MusicContext`/`MusicCommand` boundary scaffold; SwiftUI shell
(NavigationSplitView + native Table + persistent now-playing bar +
transport), reusable `ArtworkThumbnail`. Build verified clean (Swift 6 strict
concurrency). `swiftui-pro` pre/post review applied. **Committed to `main`
as `ff3294f`.**

**M2 ("Make it pleasant") — code complete, build-verified, NOT committed.**
`FavoritesStore`/`RecentlyPlayedStore` (UserDefaults; observable mirrors on
the controller), sidebar refactored into router + list + section + row,
Favorites / Recently Played / Library sections, favorite toggle + star,
`.searchable` playlist & track filtering (⌘F), Return-to-play on sidebar,
⌘L/⌘1 focus, `@SceneStorage` sidebar collapse. Build clean; `swiftui-pro`
pass applied. Held uncommitted intentionally before the pivot (can commit as
a checkpoint on request).

**Runtime evaluation (ad-hoc signed build, computer-use).**
- ✅ Auth flow verified end to end (AuthorizationView → Allow → system prompt
  → approved → authorized shell). M1 auth step is runtime-verified.
- ✅ Native layout, empty states, now-playing bar, window chrome, type
  hierarchy, Playback menu (Space/⌘→/⌘←/⌘R), View menu (⌘1/⌘L) — all good.
- ⚠️ `MusicLibraryRequest<Playlist>` returned **empty, no error** — the Mac
  had never synced the account's library + ad-hoc build lacks the MusicKit
  entitlement. Not a code bug. This is what Phase 1 must resolve/validate.

**Architecture pivot + planning (this stretch).**
Decisions resolved with the user; docs rewritten: `PLAN.md` (decisions +
recast milestones), `plans/architecture.md` (Local-first pivot section),
`plans/data-and-import.md` (GRDB rationale, schema, import, resolver),
`plans/roadmap.md` (end-to-end 5-phase plan, Phase 1 = access-validation
gate), `plans/risks-and-challenges.md` (live risk register). Memory updated:
`djroomba-local-first-pivot`, `djroomba-musickit-identity-reality`,
`user-prefers-prose-questions`.

## Verified vs NOT verified (be honest)

- Verified: builds (signing-disabled) clean through M1+M2; auth flow live;
  UI/states/menus/shortcuts live.
- NOT verified: real library read, playlist→track loading, actual audio
  playback, id round-trip, favorites/recents persistence at runtime — all
  gated on the Phase 1 signed build.

## Next

Execute **`plans/roadmap.md` Phase 1 (ACCESS VALIDATION)** — the hard gate.
Then Phases 2–5 (local store → import/UI-on-SQLite → app playlists+play
counts → polish/extension/hardening). M3 tasks (#11–16) map to Phases 2–3.

## Open user actions (block Phase 1 runtime, not planning/Phase-2 prep)

1. Add Apple ID in Xcode → Settings → Accounts.
2. Confirm MusicKit App Service enabled for `org.sockpuppet.djroomba`.
3. Sign into Apple Music + enable Sync Library on this Mac.

## Process notes

- M1 committed (`ff3294f`); M2 + pivot docs uncommitted (pending a commit
  decision). Build: `xcodegen generate && xcodebuild -project
  DJRoomba.xcodeproj -scheme DJRoomba -configuration Debug -destination
  'platform=macOS' CODE_SIGNING_ALLOWED=NO build`.
- Will not commit/push without being asked; **never merge to `main`**
  (CLAUDE.md).
