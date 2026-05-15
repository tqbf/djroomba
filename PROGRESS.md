# Progress

> Resume protocol: read `PLAN.md` (decisions + milestone index) then this
> file. `plans/roadmap.md` is the forward plan; `plans/risks-and-challenges.md`
> is the live risk register. Newest status on top.

## Current status: ✅ PHASE 1 PASSED (2026-05-15) — core viability proven

Ran a properly **Apple Development-signed** build (team KK7E9G89GW, App ID
`org.sockpuppet.djroomba`) and observed the full chain working live:

- ✅ Authorization (granted, no re-prompt).
- ✅ **Real library playlists** load with artwork — large set ('80s Hits
  Essentials, 2-Tone, 4AD Records: The '80s, 70's Protest Music, 91X
  Top 91 of 1992/93/94, …).
- ✅ **Tracks load** for a selected playlist with full metadata
  ("Backpacking", 52 tracks: ATCQ, De La Soul, The Pharcyde, The Roots…).
- ✅ **In-app playback works** — pressed Play, "Go Ahead In The Rain — A
  Tribe Called Quest" streamed in-process (elapsed ticked 0:09 → 0:41),
  pause works, macOS now-playing indicator lit.
- ✅ **M2 features verified live**: "Recently Played → Backpacking" section
  appeared after playing; sidebar/detail/now-playing/filter UI all correct.

Setup checklist (final):
- [x] Step 1 — Apple Music + Sync Library on this Mac (user, confirmed).
- [x] Step 2 — Apple ID in Xcode → Accounts (user). Verified: Xcode created
  the **"Apple Development: Thomas Ptacek (7F2QE7P59D)"** cert + provisioning;
  `-allowProvisioningUpdates` signed build SUCCEEDED.
- [x] Step 3 — **NOT required for library read/playback on macOS.** A real
  Apple Development signature + `NSAppleMusicUsageDescription` + system
  account + synced library was sufficient. (Enabling the MusicKit App
  Service for the App ID may still matter for Apple Music *catalog* API
  / re-resolving catalog-namespace ids / distribution — treat as open,
  validate when PlaybackResolver hits catalog ids in Phase 2/3.)

`project.yml` already had `CODE_SIGN_STYLE: Automatic` + team KK7E9G89GW
since M1 — no "signing flip" was needed; ad-hoc was only ever a CLI override.

Earlier "empty library" fully explained: ad-hoc unsigned build **and**
unsynced library. Both fixed. The 🔴 access/signing/library risks are retired.

**Still to validate (carried to Phase 2 — lower risk now):** the explicit
*store id → discard object → re-resolve by id → play* round trip, especially
for catalog-namespace ids. Playback from a live playlist's tracks is proven;
the id-only resolution path is the remaining unknown for the SQLite design.

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

## Open user actions (remaining — block Phase 1 runtime)

1. ✅ ~~Apple Music + Sync Library on this Mac~~ — done 2026-05-15.
2. Add Apple ID in Xcode → Settings → Accounts. ← next, handholding
3. Confirm/enable MusicKit App Service for `org.sockpuppet.djroomba`, then
   flip `project.yml` to automatic signing + signed build.

## Process notes

- Committed to `main`: `ff3294f` (M1), `4f0a7f9` (M2 + local-first pivot
  planning docs). Not pushed. Working tree clean.
- Build (agent, signing-disabled): `xcodegen generate && xcodebuild -project
  DJRoomba.xcodeproj -scheme DJRoomba -configuration Debug -destination
  'platform=macOS' CODE_SIGNING_ALLOWED=NO build`.
- Will not commit/push without being asked; **never merge to `main`**
  (CLAUDE.md).
