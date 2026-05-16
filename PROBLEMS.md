# PROBLEMS — every outstanding issue we're aware of

Snapshot of all known open issues as of 2026-05-15, after Phases 2–5 were
implemented and runtime-verified on a signed build. This is the actionable
distillation; the narrative history + how each was diagnosed lives in
`plans/risks-and-challenges.md` and `PROGRESS.md`. Severity: 🔴 blocking ·
🟠 significant · 🟡 manageable · ⚪ noise. "Owner" = who must act.

Nothing here is a known *regression* or a broken verified feature — the
signed-build gates confirmed import, imported-playlist + app-playlist
playback (real audio), play-count tracking, CRUD, favorites/recents
migration, the extension inspector, and the smarter empty-state logic all
work. These are the *remaining* gaps, accepted costs, and unverifiable-by-
agent items.

---

## 1. Needs a USER action (cannot be done by the agent)

### 1.1 🟠 Distribution: notarize a Developer ID build — USER
The validated builds are **Apple Development**-signed (device-locked to the
developer's machines); they will not launch on a stranger's Mac. Shipping
needs a Developer ID-signed + Apple-notarized build. The `make dist`
pipeline is fully wired and was reviewed internally consistent (Phase 5),
but notarization is interactive and credentialed — the agent must not and
did not run it. **Remaining USER steps to ship:**
1. `make notary-setup` once (interactive; stores the `djroomba-notary`
   keychain profile). The Makefile intentionally refuses non-interactive
   shells.
2. `git tag vX.Y.Z` then `make dist` (→ sign → notarize → staple → zip →
   checksum → verify).
3. `make github-release` (or upload `dist/*.zip` + `.sha256` manually).

### 1.2 🟡 MusicKit App Service for the notarized build — USER, conditional
Analyzed (Phase 5) as **most likely NOT required**: the entire shipping
path is library-namespace (`MusicAuthorization` + `MusicLibraryRequest` +
`ApplicationMusicPlayer`); the MusicKit App Service / `com.apple.developer.
musickit` entitlement gates *catalog* APIs + the web-token flow, neither of
which we use. Not yet proven for the Developer-ID/notarized cert chain.
**If** the notarized build fails to read the library: enable the MusicKit
App Service for App ID `org.sockpuppet.djroomba` in the Developer portal,
generate a `.provisionprofile`, and run
`make dist PROVISION_PROFILE=/path/to.profile` (build.sh embeds it; no code
or signing-identity change). Pre-wired escape valve.

### 1.3 🟡 Each end user needs Apple Music + Sync Library — END USER
Per-user, unavoidable, by design (Option A: native MusicKit = the Mac's
system Apple Account). The app sees each user's own system-account library
and needs an active subscription to play full tracks. The Phase-5 empty
states explain this in-app ("Library Not Synced…", subscription-needed).

---

## 2. Verified in code, but the agent could not exercise the runtime path

These are NOT known-broken — they are correct-by-construction + unit-tested
where deterministic, but the conditions can't be created by the agent (no
second Apple account, can't un-sync the dev Mac, can't notarize). They are
the honest "claimed, not personally watched run" set.

- **🟡 Empty-state cause branches.** `.libraryNotSynced` /
  `.subscriptionNeeded` logic is pure + unit-tested (`LibrarySidebarState`),
  but this Mac is synced & subscribed, so only the `.populated` /
  `.noImportedPlaylists` / `.loading` paths were seen live. The
  not-synced / no-subscription `ContentUnavailableView`s are unwatched.
- **🟡 Developer-ID/notarized runtime** (see 1.1/1.2) — only the
  Apple-Development signature was runtime-proven.
- **🟡 Auto-start polish edge.** Fixed and verified for the common case
  (Play → audio starts immediately, play_event records). The
  `confirmPlaybackStarted` re-issue path for "macOS queue still loading"
  is bounded/idempotent but only the fast path was observed live.

---

## 3. Accepted limitations / costs (decided, not bugs)

- **🟡 First-import is ~90–135 s (MusicKit-bound).** Measured on the signed
  build across three runs (88 / 119 / 134 s). Dominated by MusicKit's own
  per-playlist `playlist.with([.tracks])` + paging on macOS — CPU-bound and
  internally serialized; one ~5000-track library playlist alone is an
  indivisible long task. **Not** SQLite (batch idioms are correct + tested)
  and **not** fixable by app-side parallelism: a bounded-parallel TaskGroup
  was tried, measured no better (slightly worse + less stable), and
  reverted to the simple serial loop. Mitigated only by the "Importing N of
  M…" progress UI; it's one-time / Refresh-only. Accepted v1 cost. (A prior
  unmeasured "20–35 s" estimate was wrong and has been struck everywhere.)
- **🟠 No in-app login / single system account.** Cannot target an
  arbitrary Apple ID (web/token model rejected — Option A). By design.
- **🟠 Full-track playback only via Apple's player.** No raw streams
  (spec-forbidden); needs a subscription; catalog/region gating can make
  individual tracks unplayable — tolerated per-track, surfaced inline via
  `MusicController.playbackProblem`, never breaks the queue.
- **🟡 Imported-snapshot staleness window.** Import is full re-import on
  Refresh (correct, non-stale). Incremental import was investigated and
  deliberately deferred — `Playlist.lastModifiedDate` is unreliable (often
  nil) on the macOS-14 library; trusting it would silently ship stale
  snapshots. Staleness only until the next Refresh; acceptable.
- **🟡 Dormant catalog path.** `PlaybackResolver`'s
  `MusicCatalogResourceRequest` branch is wired but unused (nothing
  catalog-namespace is imported). Kept for a future catalog-import feature;
  must only ever receive genuine catalog ids. Optional catalog *search*
  (import affordance) was deliberately deferred (would activate this +
  the distribution-entitlement question).

---

## 4. Known minor / polish (non-blocking, future)

- **🟡 Now-playing elapsed time uses a ~0.5 s polling task.** MusicKit
  player state isn't cleanly Observation-bridgeable. Deliberate simplicity
  tradeoff. Play-recording and auto-start no longer depend on this lagged
  poll (they wait on the player's own `state.playbackStatus`), but the
  elapsed-time readout itself still ticks on the 0.5 s poll. Acceptable;
  revisit if it causes churn.
- **🟡 Seek reliability uncertain on macOS MusicKit.** Treated best-effort;
  not exercised hard.
- **🟡 Partial / missing MusicKit metadata.** `trackCount` (sidebar),
  `isEditable`, playlist `description`, some artwork are frequently nil on
  macOS 14. UI tolerates nil (shows "—" / placeholder). Imported-playlist
  sidebar rows intentionally show no track count (matches the M1/M2 look;
  app-playlist rows do show counts).
- **🟡 Large-library UI virtualization** not specifically stress-profiled
  beyond functional use (270 playlists / 8229 songs rendered fine; a
  multi-thousand-track single playlist table wasn't perf-profiled). SwiftUI
  `Table`/`List` virtualize by default; flagged only as untested-at-extreme.
- **⚪ SourceKit stale-index noise.** The editor recurrently shows false
  "cannot find type" / "'main' attribute" / "No such module" diagnostics
  after multi-file edits / `Package.swift` changes. Not real — every
  `make check` / `swift test` passed. Trust `make check`, not the index.

---

## 5. Process / coverage gaps

- **🟠 Agent cannot fully verify runtime.** Inherent: no live second Apple
  account, can't notarize, can't un-sync. Mitigation already in practice —
  PROGRESS.md states exactly what was vs wasn't exercised; never claims
  watched-runtime it didn't observe. The end-of-phase signed-build
  computer-use gates covered the critical paths (and caught the 🔴
  round-trip + the P4/P5 UI defects).
- **🟡 Test coverage: MusicKit-session parts untested.** 67 tests / 14
  suites cover store/migrations/CRUD/one-way-isolation/import-provenance/
  resolver-reassembly/legacy-migration/empty-state-logic/edge-hardening —
  i.e. all the deterministic logic. The live MusicKit calls (library read,
  re-fetch, audio) are NOT unit-tested and cannot be without a live account
  (faking MusicKit was disallowed); they are signed-run verification, not a
  fillable unit-test gap. Filtering/UI-logic coverage could still be
  broadened.
- **🟡 Spec divergence.** The local-first pivot supersedes parts of the
  original spec ("no DB early", extension-point-first). Mitigated: PLAN.md
  states the pivot up front; milestone-1/2 docs marked historical;
  roadmap.md is the forward source of truth.

---

## 6. Repo state

- All Phase 2–5 work is committed on branch
  **`phases-2-5-local-first-sqlite`** (off `main` @ `112e1b3`). **Not
  merged to `main`** (CLAUDE.md forbids the agent merging to main) and
  **not pushed** (no PR opened unless asked).
- To resume: read `PLAN.md` then `PROGRESS.md`; this file is the open-issue
  index; `plans/risks-and-challenges.md` has the full narrative.
