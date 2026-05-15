# Progress

> Resume protocol: read `PLAN.md` (decisions + milestone index) then this
> file. `plans/roadmap.md` is the forward plan; `plans/risks-and-challenges.md`
> is the live risk register. Newest status on top.

## Current status: Phase 1 setup underway — Step 1 (Sync Library) DONE

Walking the user through Phase 1 prerequisites (see roadmap.md Phase 1).
Setup checklist:
- [x] **Step 1 — Apple Music + Sync Library on this Mac.** User confirmed
  done (2026-05-15): signed into Apple Music, Sync Library enabled, cloud
  playlists visible in Music.app's own sidebar. (Music.app is blocked from
  computer-use by policy, so this is by user confirmation; not yet observed
  *in DJ Roomba* — that needs Steps 2–3 + a signed build.)
- [ ] **Step 2 — Apple ID in Xcode** (Settings → Accounts). Pending.
- [ ] **Step 3 — MusicKit App Service enabled for `org.sockpuppet.djroomba`**
  + flip `project.yml` to automatic signing (team KK7E9G89GW). Pending.
- [ ] **Then:** signed build → run the Phase 1 validation chain (auth → real
  playlists in DJ Roomba → tracks → in-app playback → id round-trip).

"Seeing music in the app itself" status: **NOT yet** — the library is now on
this Mac, but DJ Roomba can't read it until it's a MusicKit-entitled *signed*
build (Steps 2–3). Expected playlist count to sanity-check against: _(ask
user / fill in)_.

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
