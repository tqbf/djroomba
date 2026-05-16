# Progress

> Resume protocol: read `PLAN.md` (decisions + milestone index) then this
> file. `plans/roadmap.md` is the forward plan; `plans/risks-and-challenges.md`
> is the live risk register. Newest status on top.
> Open-issue index: `PROBLEMS.md`.

## 2026-05-16 — ✅ Play statistics Phase 2 (canonical play context; code-complete)

`plans/play-statistics.md` **Phase 2** — THE enabler. Carry *our*
`song.id`s forward from the SQLite read that built the queue and
attribute "which stored song is playing now" by the player's
**structural queue position**, never by translating an Apple id back
(the load-bearing architecture principle). Recording-only — no
playback/UI behavior change.

- **`PlaybackResolver.Resolution.playContext: [String?]`** — stored
  `song.id` per queue position, **parallel to `songs` by construction**
  (every `songs` append has one paired `playContext` append). Built in
  `reassemble` (app playlists; all non-nil) and `resolvePlaylist`
  (imported Apple; `nil` for a live track beyond the stored snapshot —
  it still plays but records no stats rather than being misattributed).
- **Pure helpers** (`nonisolated static`, MusicKit-free, unit-tested):
  `startIndex(in:startSongID:)`, `storedSongID(in:at:)`.
- **`PlaybackService`** sets `snapshot.queueIndex` = the ordinal of
  `currentEntry` within `queue.entries`, matched by the queue **Entry**'s
  own id (the queue's structural handle MusicKit mints — *not* the song's
  `MusicItemID`; no Apple content id is ever a key).
- **`MusicController`** holds the active queue's context atomically in one
  `@ObservationIgnored` value type (`ActivePlayContext{ songIDs,
  startSongID }`) set/cleared in a single assignment so the two parts
  can't drift; `currentStoredSongID` = `storedSongID(at: queueIndex ??
  startIndex-seed)`. `@ObservationIgnored` is load-bearing (the 0.5 s
  monitor must not invalidate `body` — the swiftui-pro / memory-laziness
  "no now-playing tick coupling" rule); nothing reads it from a view.
- **Cleanup gate (R6):** reuse/quality/efficiency + swiftui-pro 3-agent
  pass. Caught & fixed a **CRITICAL** desync (`songs` grew but
  `playContext` didn't when the live Apple playlist exceeds the stored
  snapshot → every later position misattributed) — fixed via `[String?]`
  parallel-by-construction (no playback change, vs the reviewer's
  drop-from-both which would have dropped playable songs); collapsed two
  drift-prone fields into one value type; deleted a brittle
  source-substring test (the behavioral pure-function proof already
  covers the no-Apple-id-key guarantee); trimmed change-narrating
  comments. swiftui-pro/efficiency review: `@ObservationIgnored` correct
  & sufficient; `queueIndex` adds zero new body churn (snapshot already
  wholesale-replaced each tick); per-tick `entries.firstIndex` is
  bounded — Phase 4's transition detector supersedes it.
- **Refines the plan:** spec said `playContext: [String]`; the
  stale-snapshot edge (live > stored) makes `[String?]` the faithful
  realization of "attribute only what our SQLite read canonically gives"
  — recorded here as an intentional deviation.
- **Verify:** `swift build` clean; **94 tests / 18 suites** green
  (Phase-2 pure helpers, parallelism, nil-hole bounds; −1 vs prior count
  = the removed brittle source-grep test); `swiftformat` 0, `swiftlint`
  0.
- **Signed gate PENDING (user):** structural-position fidelity under
  real auto-advance / manual skip / `startingAt:` can't be unit-verified
  (no live MusicKit in tests). Documented fallback if it proves
  unreliable: count `currentEntry` transitions off the 0.5 s monitor to
  advance the index — still principle-clean (no Apple-id translation).
  Phases 3–4 depend on this.

## 2026-05-16 — ✅ Play statistics Phase 1 (v3 schema + store API)

Executed `plans/play-statistics.md` **Phase 1** (the durable spine; no
playback behavior change — recording-only foundation for Phases 2–4).

- **Migration `v3.playStatistics`** (appended below v2; v1/v2 frozen,
  `eraseDatabaseOnSchemaChange` still false; idempotent). Four
  coordinated changes: (a) `song.local_id` added nullable →
  backfilled dense 1-based in `(imported_at, id)` order → `UNIQUE`
  index; (b) `play_history` (`seq INTEGER PK AUTOINCREMENT`,
  `song_local_id` FK→`song(local_id)` `ON DELETE RESTRICT`) — the
  user's bounded numeric "vector"; (c) `song_stat.skip_count` /
  `replay_count` (`NOT NULL DEFAULT 0`); (d) **`play_event` DROPped**
  (verified consumer-less; last unbounded table gone). Cleanup pass
  added a **partial index** `idx_song_unassigned_local_id … WHERE
  local_id IS NULL` so the new-row allocator is skipped at O(1) on a
  no-op incremental re-import (the path commit `11bcaf4` optimizes).
- **Records:** `Song.localID` (read-authoritative, write-ignored —
  contract is comment-enforced, documented as such); `SongStat`
  skip/replay counters; new `PlayHistoryEntry`; `PlayEvent.swift`
  deleted.
- **`LibraryStore`:** `playHistoryCap = 50_000` (R9, one tunable);
  `upsertSongs` assigns `local_id` for new rows only inside the existing
  upsert txn (existing rows keep theirs — same non-destructive
  re-import guarantee as the stable `id`); `recordPlay` rewritten (one
  txn: resolve `local_id` → typed `RecordPlayError.unknownSong` aborts
  ghost plays leaving `song_stat` unchanged → roll `song_stat` → append
  `play_history` → keyset prune `WHERE seq <= MAX(seq) - cap`);
  `recordSkip`/`recordReplay` are thin wrappers over one private
  `bumpStatCounter` key-path helper (R4: never touch `play_history`);
  `recentlyPlayedSongLocalIDs`/`…SongIDs` (newest-first, dupes kept);
  `playEventCount` removed.
- **Canonical-key discipline (architecture principle):** Phase 1 keys
  only on `song.id` / `song.local_id`; no Apple id anywhere on this path.
- **Cleanup gate (R6):** `simplify` three-agent pass (reuse/quality/
  efficiency — covers the Thomas'-Laws surface) found and fixed: the
  duplicated skip/replay block (→ shared helper), a doc-comment that
  misstated the ghost-song error mechanism (now accurate: counter paths
  FK-trip a raw `DatabaseError`, only `recordPlay` raises the typed
  error), the unconditional allocator scan (→ partial index + EXISTS
  early-out), over-long comments trimmed. `recentlyPlayed*` default left
  at `playHistoryCap` (decision-locked R3/R9, bounded, no callers yet —
  not a defect). swiftui-pro: no SwiftUI/Observation touched (N/A).
- **Verify:** `swift build` clean; **90 tests / 18 suites** green
  (baseline 82/17 + new `PlayStatisticsTests` incl. v3 non-destructive
  backfill on a real v2 DB via `migrate(…, upTo: "v2…")`, exact-cap
  prune, counter isolation, `local_id` stability across re-import;
  3 tests migrated off `playEventCount`); `swiftformat` 0/80,
  `swiftlint` 0 violations.
- **Known precision note (carried):** the `MAX(local_id)+1` allocator
  is over *live* rows, so a never-referenced number *could* recur if its
  song were deleted before being observed; songs are never deleted in
  the app and any played/listed song is FK-RESTRICTed, so an observable
  `local_id` can't recur. `Song.localID` doc states this exactly (the
  unqualified "never recycled" was tightened).
- **Not signed-gated** (pure SQLite, unit-tested — plan: Phase 1 no
  gate). Phases 2–4 follow.

## 2026-05-16 — ✅ App icon (native macOS treatment)

`djroomba.png` (1254² pixel-art DJ-Roomba on an off-white field) turned
into a native-feeling `AppIcon.icns` and wired into the no-Xcode bundle.

- **Treatment (macos-design consulted):** Apple Big Sur+ icon grid — 1024
  canvas, 824² rounded tile (100px margin), continuous-ish corner radius
  ~185, one restrained soft shadow inside the margin (not a single heavy
  drop). The source's off-white field becomes the tile color; character
  keeps its breathing room. Verified by eye on light **and** dark
  backdrops — reads as a real Mac app icon, not a full-bleed square.
- **Reproducible:** `scripts/make-appicon.sh` (ImageMagick + `iconutil`)
  builds all 10 iconset sizes from one styled 1024 master → `iconutil`
  packs `DJRoomba/AppIcon.icns`. `djroomba.png` is the checked-in source.
- **Wiring:** no asset catalog (consistent with the no-Xcode build).
  `build.sh` copies `AppIcon.icns` → `Contents/Resources/`; `Info.plist`
  gains `CFBundleIconFile`/`CFBundleIconName` = `AppIcon`. `build.sh`
  hard-fails if the icns is missing. `./build.sh debug` verified: builds,
  signs clean, bundle carries the icon. `plans/build-system.md` updated
  (the "no bundled resources" claim was now false).

## 2026-05-16 — ✅ Cleanup pass (Thomas' Laws): Phase A shipped; B/C logged

Applied the `toms-laws` rubric to the post-residency code. Verdict: the
codebase is in good shape — only three genuine findings, one worth doing
now.

- **Phase A — SHIPPED.** Collapsed the duplicated app-playlist mutation
  ritual into one private chokepoint, `MusicController.mutateAppPlaylist(_:_:)`.
  `renameAppPlaylist` / `addSongs` / `removeTracks` / `setAppPlaylistTracks`
  each were `await service.X(); rebuildDerivedSummaries();
  refreshSelectedDetailIfNeeded(id)` — 4 copies of the same 3-statement
  ritual where forgetting the rebuild is exactly the Phase-4 "forgot to
  refresh" bug class. Now each is one `await mutateAppPlaylist(id) { … }`
  call; the rebuild+refresh is structural for these paths, not a
  per-method discipline. `create`/`delete`/`reorder` keep their own
  bespoke post-mutation bookkeeping (genuinely different shapes — forcing
  them through the funnel would be a Law-13 hybrid). Laws 5/10/11/12.
  Pure intra-class refactor, behavior identical. **`swift build` clean,
  82 tests / 17 suites green** (incl. `UIRefreshCorrectionTests`,
  `AppPlaylistCRUDTests`), `swiftformat --lint` 0/1, `swiftlint` 0
  violations.
- **Phases B & C — logged, deferred.** B (extract `LibraryStore`'s
  chunked multi-row `INSERT` ceremony) and C (hoist `PlaylistSidebarList`
  filtering out of `body`) recorded in `DESIGN-TODO.md` with their
  falsifiable freight claims and veto conditions. C is recommended
  **against** unless the sidebar measurably lags. Three options were
  explicitly evaluated and decided **against** (per-collection rebuild
  decomposition now; Environment-injecting `ArtworkProvider.shared`;
  reopening reactive-store) — rationale in `DESIGN-TODO.md` so they aren't
  re-proposed without a new trigger.

## 2026-05-16 — ✅ Residency: A+B shipped; C (GRDB observation) reverted

Final state of the `plans/memory-and-laziness.md` work. **A and B are
kept** (they fully deliver the goal: ruthless residency + spry UI at
near-zero risk). **Phase C — the GRDB `ValueObservation` reactive store —
was built, verified green, then reverted** after the user confirmed two
facts that change the calculus: **multi-source sync will never happen**,
and **lots of features will be built on this baseline**.

- **Why C was reverted (the freight evaluation).** `ValueObservation`'s
  defining benefit is propagating writes the app didn't initiate; under a
  permanent **single writer** that is moot. Its only residual value — the
  structural "can't forget to refresh" guarantee — is delivered *more
  cheaply and synchronously* by a **mutation chokepoint**, without
  observation's async-iterator lifecycle or the startup /
  `reconcileSelectionAfterImport` / create→select **sequencing races**
  (the prototype had to paper those over with kept-explicit reads — the
  tell that pure observation fights the synchronous control flow). The
  shipped form was also a hybrid (3 tables observed; app-playlists +
  detail manual; redundant optimistic rebuilds) feeding one
  `rebuildDerivedSummaries()` God-sink — the worst base for "build lots on
  top". Net: C carried observation's cost without a benefit that exists
  here.
- **Forward pattern (recorded in code + plan).** Single-writer ⇒ freshness
  is a discipline at the `LibraryStore` mutation chokepoint, not a
  framework concern: every input mutation re-derives synchronously
  (zero-latency, race-free). The Phase-4 "forgot to refresh" bug class is
  prevented by routing all mutation→re-derive through that chokepoint. As
  features grow, decompose the single all-collections
  `rebuildDerivedSummaries()` into **per-collection** rebuilds invoked by
  the specific mutation (the one God-rebuild — not observe-vs-manual — is
  the real scaling limit). This note lives in the
  `rebuildDerivedSummaries()` doc-comment so a future agent meets it at
  the code.
- **Revert mechanics.** `LibraryReadService` restored to its exact
  pre-change original (store-backed `load()`); `LibraryStore` `observe*`
  factories removed (Phase-B `allSongs()` doc kept);
  `MusicController` observation tasks / `deinit` / `startObservations` /
  `loadImportedPlaylistsInitial` removed and `startAuthorizedSession` /
  `runImport` restored to the A/B form; `StoreObservationTests` deleted.
  Grep confirms no `ValueObservation`/`observe*`/`observationTasks`
  remnants except the intentional decision note in the doc-comment.
- **Verification (final A+B baseline):** `swift build` clean; **82 tests
  / 17 suites** green (78 original + 4 `PlaylistDetailCacheTests`);
  `swiftformat 0/78`, swiftlint clean. Not committed (on `main`).
- **Still true from A+B:** Phase A (stored input-driven derived
  collections + O(1) `summariesByID`; `TrackTableView` sort/filter out of
  `body` via `PlaylistDetail.revision`) and Phase B (LRU **5**,
  targeted invalidation via `ImportService.changedPlaylistIDs`,
  `ArtworkProvider` FIFO 1024, `allSongs()` flagged). Phase D (SQL-side
  sort/filter + windowed `Table`) still deferred; the huge multi-day
  playlist is its test case.

## 2026-05-16 — ✅ Residency/laziness Phases A-B-C implemented (C since reverted — see top)

Executed `plans/memory-and-laziness.md` (user picked LRU **5**, scope
**A→B→C**, Phase D deferred — but the real library's **huge multi-day
playlist** is now the concrete D trigger, recorded in the plan).

- **A — kill per-`body` recompute (no behavior/schema change).**
  `MusicController` derived collections (`allSummaries`/`appPlaylists`/
  `favoritePlaylists`/`recentPlaylists`) are stored, input-driven state
  via `rebuildDerivedSummaries()` (called only on real input changes, never
  in `body`); `selectedSummary` + all id lookups go through an O(1)
  `summariesByID`. `recentPlaylists` is no longer O(recents×allSummaries).
  `TrackTableView` filter+sort moved out of `body` into `@State
  displayedTracks`, recomputed only via `onChange(of: detail.revision /
  trackFilter / sortOrder)`. New monotonic `PlaylistDetail.revision`
  (minted per produced value in `PlaylistDetailService`) so a same-id
  stats refresh still re-derives but an unrelated observable tick doesn't.
- **B — bound residency (no schema change).** New `PlaylistDetailCache`
  bounded **LRU capacity 5** replaces the unbounded `[String:
  PlaylistDetail]`; `peek` (recency-neutral, for stats merge) vs
  `value(forID:)` (a use). Targeted `invalidate(playlistID:)` /
  `invalidate(playlistIDs:)`; `invalidateAll()` only for forced reimport.
  `ImportService.changedPlaylistIDs` exposes exactly the re-fetched +
  pruned playlists so `runImport` invalidates only those — an incremental
  Refresh that changed nothing keeps the on-screen (multi-day) playlist's
  cache warm (no cold SQLite re-read). `ArtworkProvider` cache FIFO-capped
  (1024, positives+negatives). `LibraryStore.allSongs()` doc-flagged as a
  residency footgun (no caller; must never back a list view).
- **C — reactive store (no schema change).** Scoped GRDB
  `ValueObservation` on `apple_playlist` / `favorite_playlist` /
  `recent_playlist` (each tracks only the table its fetch reads) consumed
  by `@MainActor` controller tasks (structured concurrency, cancelled in
  `deinit`); `rebuildDerivedSummaries()` is the sink. `LibraryReadService`
  is now push-based (`apply(applePlaylists:)`/`fail`, no store dep).
  Removed the steady-state manual reload choreography; external/background
  DB changes now propagate with **no explicit reload**.
  - **Two deliberate scoping boundaries (documented in the plan, not
    omissions):** app playlists stay on the explicit zero-latency path
    (create→select→inline-rename needs the new row in `summariesByID`
    synchronously — observation latency would race it; app playlists are
    tiny/single-writer so ~no residency gain); per-playlist detail stays
    lazy + Phase-B-bounded + D4-discrete-refreshed (a detail observation
    needs risky per-selection re-keying for no residency/correctness
    gain). Sequencing-critical explicit reads kept on purpose: startup
    population (so `restoreSelection()` sees summaries) and post-import
    `loadImportedPlaylistsInitial()` (so the synchronous reconcile sees
    fresh data); the observation then re-emits idempotently.
- **Verification:** `swift build` clean; **85 tests / 18 suites** green
  (+`PlaylistDetailCacheTests` ×4 = LRU bound/eviction/peek-neutral/
  targeted-invalidate; +`StoreObservationTests` ×3 = external write
  propagates with no reload, deterministic via stepped async iterator —
  no sleeps); swiftformat `0/79 require formatting`, swiftlint clean.
  swiftui-pro consulted (data.md/performance.md): `body` no longer
  sorts/filters; derived collections are stored/`@State` with **explicit**
  invalidation; `@Observable @MainActor` preserved; structured concurrency
  only. **Not committed** (on `main`; no instruction to commit).
- **Honest read:** A+B fully deliver the user's stated goal (ruthless
  residency + spry) at near-zero risk. C is the architectural end-state;
  with a single in-process writer its concrete benefit today is the live
  projection / external-change propagation / deleted manual-reload churn —
  modest now, valuable when multi-source sync (schema-doc future) lands.
  Phase D (SQL-side sort/filter + windowed `Table`) remains deferred; the
  multi-day playlist is its test case.

## 2026-05-16 — 📋 Residency/laziness plan written (then implemented — see above)

Evaluated the whole codebase against the "SQLite is the fast source of
truth → keep almost nothing resident, lazy-load, stay spry" goal. Wrote
`plans/memory-and-laziness.md` (PLAN.md index updated). Findings:

- The app does **not** load the whole library's tracks today — one
  playlist at a time. The real issues are narrower than "library in
  memory": (1) `PlaylistDetailService.cache` is **unbounded** with
  all-or-nothing `invalidate()` — browsing the library accumulates every
  playlist's `TrackRow`s; (2) `MusicController`'s derived collections
  (`allSummaries`/`favoritePlaylists`/`recentPlaylists`/`appPlaylists`/
  `selectedSummary`/`sidebarState`) are **computed properties rebuilt
  every SwiftUI `body`** — `recentPlaylists` is O(recents×allSummaries),
  the sidebar does ~5 concats + O(n·m) scans + 4 filters per render;
  (3) `TrackTableView` sorts/filters the full track array **in `body`**;
  (4) no `ValueObservation` (manual reload+republish, why the cache is a
  crutch); (5) latent footgun `LibraryStore.allSongs()` (no app caller).
- Plan stages it lowest-risk-first: **A** convert per-`body` recompute to
  input-driven stored `@Observable` state + O(1) id index, move
  Table sort/filter out of `body` (pure spry win, no behavior/schema
  change); **B** bounded LRU detail cache + targeted invalidation +
  `ArtworkProvider` ceiling (bounded residency); **C** scoped GRDB
  `ValueObservation` replacing the manual reload choreography (freshness
  without a resident mirror); **D** SQL-side sort/filter + windowed Table
  — **deferred**, trigger-gated (no >10k-track list / catalog browser).
- No migration in A–D; all above `LibraryStore`. swiftui-pro consulted
  (data.md/performance.md): the design respects "`body` is hot" and
  "cache derived collections only with explicit invalidation".
- **Open decisions surfaced to the user** (LRU capacity; do C now vs.
  stop after B; confirm D stays deferred). Awaiting direction before
  implementing. Nothing built/committed yet.

## 2026-05-16 — ✅ Incremental import implemented (the only real lever)

Acted on the profiling finding: don't re-fetch tracks for playlists that
didn't change.

- **Migration `v2.applePlaylistChangeToken`** (append-only, nullable
  `apple_playlist.change_token` INTEGER; v1 untouched per the discipline).
  Stored as `Int(Playlist.lastModifiedDate.timeIntervalSince1970)` —
  integer seconds, exact `==` despite GRDB ms date round-trip.
- **Pure decision** `ImportService.importDecision(...)` — conservative:
  `.skipUnchanged` only on a confident snapshot+token match; every
  uncertainty → `.fetch`. Never a stale skip (worst case: redundant
  fetch). `runImport(force:)` skips via `touchApplePlaylistImportDate`
  (no MusicKit track fetch) and `pruneApplePlaylists(keeping:)` drops
  vanished snapshots (FK-cascade only — one-way isolation preserved).
- **Escape hatch** ⇧⌘R "Reimport Everything" →
  `MusicController.reimportEverything()` → `runImport(force: true)`;
  recovery for smart/auto playlists that change server-side without
  bumping `lastModifiedDate`. ⌘R stays incremental.
- **Tests:** new `IncrementalImportTests` (10) — pure decision matrix +
  store plumbing + the prune one-way-isolation invariant; `MigrationTests`
  updated for v2 (list + new change_token-column check). Unsigned, no
  MusicKit. **Gate: 78 tests / 16 suites green** (`ImportPerfBench`
  still `.enabled(if:)`-skipped). `swift build` clean,
  swiftformat/swiftlint clean.
- **Honest caveat (in plans/data-and-import.md + profiling.md):** the
  mechanism is correct/safe regardless; the *speedup* depends on macOS
  MusicKit populating `lastModifiedDate` (often nil per musickit-notes) —
  verifiable only on a signed Refresh. When nil it degrades to today's
  full import: **no regression, worst case unchanged.** Not committed.

## 2026-05-16 — ✅ Import perf ANSWERED: ~99% is MusicKit, not our code

`ImportPerfBench` (env-gated test, unsigned, no MusicKit) runs the exact
`ImportService.writePlaylist` app-side path over a real-scale synthetic
library (270 playlists / ~18.8k slots / ~7.9k songs, file-backed SQLite):
**total app-side write path ~1.08 s** (snapshot-replace 50%, upsert 34%,
lookup 13%, mapping 1%) vs the **~90–120 s** real import. ⇒ **≈99% of
import time is MusicKit's `playlist.with([.tracks])` fetch; there is no
reducible app-side hotspot.** Confirms the long-standing H1 with a real
isolated measurement (prior finding was only coarse wall-clock A/B);
refutes H2/H3. **Only lever = incremental import** (skip MusicKit re-fetch
for playlists unchanged since `lastImportedAt`) — a structural change, not
a hotspot fix; app-side parallelism stays ruled out. Detail + table in
`plans/profiling.md` findings log. No signed run needed for this
conclusion (a signed profile would only show MusicKit's *internal*
breakdown, which isn't our code). Normal `swift test` gate unchanged (67
real tests green; the benchmark is `.enabled(if:)`-skipped — runtime
still ~0.1 s). swiftformat/swiftlint clean. Not committed.

## 2026-05-16 — 🔬 Profiling wired in (import perf investigation set up)

Wired [apple/swift-profile-recorder](https://github.com/apple/swift-profile-recorder)
into the app to profile the known ~90–120 s full-re-import cost; created the
global `swift-profiling` skill (speedscope + computer-use +
`scripts/hotspots.sh`).

- **Package.swift:** added `swift-profile-recorder` (`.upToNextMinor(from:
  "0.3.0")`, resolved 0.3.16) + `swift-log` (`Logging`, for the required
  `Logger`; already transitive). GRDB pin untouched. `swift build` resolves
  and links clean.
- **`PlaylistPlayerApp.init()`:** starts `ProfileRecorderServer` via
  `Task.detached` (structured concurrency, not GCD) behind
  `#if DEBUG || PROFILE_RECORDER`. **Inert** unless
  `PROFILE_RECORDER_SERVER_URL_PATTERN` is set (no env var ⇒ `.default`,
  server never binds); `runIgnoringFailures` swallows sandbox bind errors;
  the normal release/`make dist` build defines neither symbol so it's
  never compiled in. Verified the real v0.3.16 API
  (`parseFromEnvironment()` is `async throws`; blog snippet was stale).
- **No new "reimport" feature needed:** ⌘R "Refresh Playlists" →
  `refreshLibrary()` → `runImport()` is already a full, non-incremental
  re-import — repeatable for profile/iterate. Documented rather than adding
  redundant UI.
- **`plans/profiling.md`** added (PLAN.md index updated): the signed-build
  + sandbox-container-socket runbook, the ⌘R/curl/`hotspots.sh`/speedscope
  loop, and the **self-time hypotheses** to test — notably that the prior
  "it's all MusicKit, not reducible" finding came from coarse wall-clock
  A/B, not a self-time profile, so the profile may still surface app-side
  self-time (`song(from:)`/write-path/ARC) or point at incremental import.
- Verification: `swift build` clean, `swift test` **67/67 / 14 suites**,
  `swiftformat --lint` clean, `swiftlint` 0 on changed files. Behavior
  unchanged when the env var is unset (i.e. always, in normal use).
- **Open:** the actual capture needs a *signed* run against a real Apple
  Music library (MusicKit + sandbox) — that's a USER step (runbook in
  `plans/profiling.md`); I can drive `hotspots.sh`/speedscope analysis once
  a `.perf` exists. Not committed (no instruction to; on `main`).

## 2026-05-15 — ✅ Airbnb Swift style pass (formatter + linter wired up)

Applied the Swift skills (`airbnb-swift-style`, `swiftui-pro`) across the
whole codebase. Tooling adopted (Homebrew): **SwiftFormat 0.61.1 +
SwiftLint 0.63.2**; Airbnb's canonical configs vendored as `.swiftformat`
and `.swiftlint.yml` (one toolchain adaptation: `--type-blank-lines
preserve` since 0.61.1 lacks `consistent`; `--language-mode 6` since the
package compiles in Swift 6 mode).

- **`[AUTO]` layer:** `swiftformat` reformatted **all 75 files**
  (+5,788 / −5,330) — sorted imports, `// MARK:` organization +
  visibility/type declaration ordering, redundant `self`/`return`/`init`/
  parens/`Void` removed, trailing commas, raw-identifier swift-testing
  case names, brace/space normalization. Non-behavioral (Airbnb tenet) and
  proven so: build clean, **67/67 tests / 14 suites still green**.
- **Lint layer:** `swiftlint` with the Airbnb `only_rules` set →
  **0 violations / 74 files** (independently confirms no IUOs, force-
  unwraps, stray `print`, `@unchecked Sendable`, legacy constructors,
  `#file`). Earlier phases were already disciplined.
- **`[JUDGMENT]` manual pass** (3 parallel skill-checklist reviewers +
  swiftui-pro + a deprecated-API/forbidden-state grep cross-check): the
  app code is clean — **0** deprecated SwiftUI API, **0** forbidden state
  patterns (`ObservableObject`/`@Published`/`@AppStorage`-in-`@Observable`
  — only a *comment* documenting the rule), structured concurrency only.
  One genuine fix applied: `LegacyMigrationTests` force-unwrapped
  `UserDefaults(suiteName:)!` → `try #require(...)` with a `throws`
  helper (Airbnb "avoid force-unwrap in tests").
- **Rejected (documented):** a sub-reviewer flagged two `MusicController`
  fire-and-forget `Task {}` as "retain cycles" → verified false (tasks
  not stored; consistent with the 28-site fire-and-forget vs 3-site
  stored-`[weak self]` pattern). Changing 2 of 28 identical sites would be
  the nitpick the skills forbid; left as-is.
- Verification: `swift build` clean, `swift test` **67/67 green**,
  `swiftformat --lint` **0/75**, `swiftlint` **0**. Behavior unchanged.
  Not committed (no instruction to); a global `airbnb-swift-style` skill
  now exists at `~/.claude/skills/`.

## 2026-05-15 — ✅ ALL PHASES COMPLETE — committed to a branch

Phases 2–5 are implemented and **runtime-verified on a signed build**
(Phase 1 was pre-passed). Final state:

- **Phase 2** GRDB SQLite store (frozen-migration discipline, off-main
  `Sendable`), **Phase 3** one-way import + UI-on-SQLite + playlist-
  granularity playback + artwork + UserDefaults→SQLite migration,
  **Phase 4** app playlists + per-id app-playlist playback + play-count
  tracking + sortable stats + native CRUD/rename/delete, **Phase 5**
  smarter empty states + auto-start polish + native `.inspector()`
  extension boundary + edge hardening.
- Each phase passed an end-of-phase gate (swiftui-pro + macos-design +
  typography-designer + signed-build computer-use). The gates caught and
  drove fixes for real defects every phase — the 🔴 id round trip (twice,
  Phase 3, found via a temporary diagnostic probe), 4 UI defects (Phase 4),
  3 defects incl. a false perf estimate (Phase 5). All corrected and
  re-verified live (real audio plays for imported AND app playlists;
  play_count persists; rename/CRUD native; inspector clean & unclipped;
  title correct).
- `make check` green; `swift test` **67 tests / 14 suites green**; signed
  `make` build valid (`Apple Development: Thomas Ptacek (7F2QE7P59D)`).
- **Committed to branch `phases-2-5-local-first-sqlite`** (off `main` @
  `112e1b3`). NOT merged to `main`, NOT pushed (CLAUDE.md: agent never
  merges to main; no PR unless asked).
- **`PROBLEMS.md` added** — the consolidated, actionable index of every
  outstanding issue (USER distribution steps; agent-unverifiable runtime
  branches; accepted MusicKit-bound import cost; minor/polish; coverage
  gaps). `plans/risks-and-challenges.md` keeps the full narrative; PLAN.md
  index updated to point at PROBLEMS.md.
- No outstanding *regressions* or broken verified features. Remaining work
  is the USER's distribution run + the inherently-agent-unverifiable paths,
  all enumerated in `PROBLEMS.md`.

## 2026-05-15 — Phase 5 CORRECTIVE (3 defects from the signed gate) — code-complete, runtime-unverified, not committed

The orchestrator's signed-build computer-use run confirmed the GOOD Phase-5
items (auto-start polish; the native `.inspector()` boundary; smarter
empty-state logic + tests; import correctness) and caught **3 defects**. All
three are corrected here. `make check` green; `swift test` → **67 tests / 14
suites passed** (count unchanged — see D3). Signed `make` build produced.
**Not committed.** The agent CANNOT run the app; the orchestrator re-verifies
live (title = "DJ Roomba"; inspector fully readable; re-measured import
wall-clock).

**D1 — toolbar/window title regressed to "Inspector". FIXED.**
Root cause: Phase 5 added `.navigationTitle("Inspector")` to
`ExtensionInspectorView`. That view is presented via `.inspector()` *inside*
the `NavigationSplitView`, so its `.navigationTitle` propagated up and
clobbered the window title — and persisted with the inspector collapsed
because the modifier stays applied to the view tree. Pre-Phase-5 the detail
column had **no** `.navigationTitle`, so macOS fell back to `CFBundleName`
= **"DJ Roomba"** (the correct, conventional macOS window title — verified
against `git show HEAD:DJRoomba/Views/MainShellView.swift`, which had no
title modifier at all). Fix: **deleted `.navigationTitle("Inspector")`**;
the title now falls back to "DJ Roomba" exactly as before. The inspector's
own label ("Extension Inspector", `.headline`) was moved **inside** the
panel as the first `Form` `Section` — the native macOS inspector idiom
(Xcode/Numbers carry the inspector's identity in its content, never as the
window title). macos-design confirmed: a `.inspector()` panel must not set a
`.navigationTitle`; that is a window-level concern.

**D2 — inspector content clipped at BOTH window edges. FIXED (deeper root
cause — earlier inspector-content fix was only half of it).**

*First pass (kept, still correct):* `LabeledContent("Playlist", value:)`
value text defaulted to a single unconstrained line that the layout pushed
wider than the panel; the footer caption had no wrap affordance. Fixes
(swiftui-pro + macos-design): value text routed through an
`inspectorRow(_:_:)` helper — `.lineLimit(1)` + `.truncationMode(.tail)` +
`.textSelection(.enabled)` (ellipsize *within* the panel, truncated value
still recoverable — the Xcode/Numbers idiom); footer explainer gets
`.fixedSize(horizontal: false, vertical: true)` to wrap to as many lines as
needed. `LabeledContent` kept as the Form row idiom (swiftui-pro
`design.md`).

*Deeper root cause (THIS corrective):* the live signed build still clipped
on **both** edges with the inspector open — sidebar leading text cut
("ilter Playlists", "y Playlists") AND inspector trailing content cut
("91X Top 273 of 1992-" missing "1994", "Status St…", footer right edge).
The real defect was **scene-level, not inspector-content**:
`PlaylistPlayerApp` put a hard `.frame(minWidth: 1040, minHeight: 600)` on
`RootView()` *inside* the `WindowGroup`, wrapping a `NavigationSplitView` +
`.inspector()`. A clamping outer frame around a split view is an
anti-pattern (swiftui-pro: don't wrap a split view in a fixed frame it
can't fit neatly inside): the split view owns its own column layout; when
macOS **state restoration** pinned a frame narrower than 1040, the
`.frame(minWidth:1040)` forced the *content* to 1040 *inside the smaller
window*, so the split view overflowed and clipped **symmetrically on both
edges** instead of the window being widened. `.windowResizability(
.contentMinSize)` did not reliably floor the window because the binding
min was the arbitrary outer-frame clamp, not the split view's own reported
content minimum, and a stale saved frame could still defeat it.

*Idiomatic fix (swiftui-pro + macos-design):*
- **Removed the hard `.frame(minWidth:1040, minHeight:600)` on
  `RootView`.** The `NavigationSplitView` column minimums + the inspector
  column minimum now drive layout — no outer clamp fighting the split view.
- **`.windowResizability(.contentSize)`** (was `.contentMinSize`): ties the
  window's resizable minimum *directly* to the split view's reported
  content minimum = sidebar(min 220) + detail(min 480) + inspector open
  (min 300) ≈ **1000pt**. macOS clamps a restored window frame **up** to
  that content-derived minimum, so a stale narrow saved frame can no longer
  defeat the fix and the window is never allowed narrower than all three
  columns combined (handles state restoration correctly).
- Inspector column min raised **280 → 300** (native inspectors sit
  ~270–360pt) so the grouped `Form`'s label+value rows lay out cleanly at
  the narrowest; detail ideal trimmed **720 → 660** so the default opens
  with all three columns above their ideals.
- `.defaultSize(width: 1240, height: 760)` retained — comfortably above
  sidebar ideal 260 + detail ~660 + inspector ideal 320 with the inspector
  open.
- `ExtensionInspectorView` Form gets `.padding(.trailing, 4)` — a small
  trailing inset so the value text / wrapping footer never touch or clip at
  the panel's trailing edge even at the inspector's min width (symmetric
  with the grouped Form's leading inset).

Net: with the inspector open and a long-named playlist selected, the
window can no longer be narrower than sidebarMin+detailMin+inspectorMin, so
the sidebar leading text, the detail, and the full inspector content all
render inside the frame with no clipping at either edge — at default size
and after window-state restoration. **Code-complete; runtime-unverified**
(agent cannot run the app — orchestrator re-verifies live: inspector open
on "91X Top 273 of 1992-1994", nothing clipped either edge, at default
size and after relaunch). typography unaffected (no new type roles —
no type scale touched). swiftui-pro applied before & after (no fixed frame
on the split-view-bearing WindowGroup root; modern `.windowResizability`/
`.defaultSize`/`.inspectorColumnWidth`; no `GeometryReader`; no
force-unwrap); macos-design applied (native 3-pane + inspector,
content-driven window minimum, no outer clamp).

**D3 — the import "performance" change was ineffective and shipped with a
FALSE estimate. DIAGNOSED → REVERTED + DOCS CORRECTED (honest finding).**
Measured reality on the signed build: **~119 s, NO improvement over the
prior ~88 s (slightly worse)**, with a ~67 s stretch pegged at ~100% **one-
core CPU**, the DB not growing, stuck at "15 playlists / 947 songs", then a
burst to completion (and added instability — CPU spiked to ~147 % and a
transient inconsistent read mid-import).
- **Diagnosis (from the code + the profile):** the SQLite write path is
  fully batched and clean — `writePlaylist` builds a `[SongKey: Song]` dict +
  an `orderedKeys` array (all O(n)), then `upsertSongs` /
  `songIDsByKey` / `replaceApplePlaylistSnapshot` are chunked batch
  statements (pinned by `BatchImportTests`/`SnapshotReplaceTests`).
  `song(from:)` is O(1)/track. **There is NO app-side quadratic and NO
  per-row DB loop** anywhere in our import code. The 67 s @ 100% *one-core*
  CPU with **no DB growth**, stalled right after the sliding window reaches
  the library's one giant ~5075-track "AAA ME" playlist, is the signature of
  a **single CPU-bound, internally-serialized MusicKit operation**:
  `playlist.with([.tracks])` + `nextBatch()` materializing thousands of
  `MusicItemCollection<Track>` entries on macOS. A 5075-track playlist is
  one indivisible task that parallelism cannot split; concurrent
  `with([.tracks])` calls **contend on MusicKit's internal machinery** (the
  ~147 % spike + transient inconsistent read) instead of overlapping — which
  is *why* the `TaskGroup` made it worse, not better.
- **Decision: path (3) — the cost is irreducibly MusicKit-bound, so the
  ineffective bounded-parallel `TaskGroup` (window of 6) was REVERTED to the
  simple proven serial `for` loop.** No app-side quadratic exists to fix
  (path 2 N/A). Kept: the harmless **"Importing N of M playlists…"**
  progress affordance (counts still advance as each playlist is written).
  The SQLite write path is byte-for-byte unchanged, so the verified one-way
  isolation (`AppPlaylistCRUDTests`/`SnapshotReplaceTests`/`BatchImportTests`)
  stays green — confirmed (67/14, unchanged). No new test: D3 is a revert,
  not a quadratic fix; the existing batch/isolation tests already pin the
  unchanged write path.
- **Honest perf finding (replaces the false "20–35 s"):** a full re-import
  of a ~270-playlist / ~8200-track library is **~90–120 s**, dominated by
  MusicKit's per-playlist track resolution on macOS — **not** SQLite, **not**
  fixable by app-side parallelism. Accepted as the v1 cost; it is a one-time
  / Refresh-only operation, mitigated only by the progress affordance. The
  prior **"~88 s → ~20–35 s (estimated)"** claim was unmeasured and is
  **wrong** — it is struck from every doc and **not** restated with any new
  unmeasured number. The re-measured wall-clock is the orchestrator's to
  confirm; this code makes no perf claim beyond "the parallelism didn't
  help, so it's gone".

**Files changed (corrective):** `DJRoomba/App/PlaylistPlayerApp.swift`
(D2 deeper: removed the hard `.frame(minWidth:1040,minHeight:600)` outer
clamp on `RootView`; `.windowResizability` `.contentMinSize` →
`.contentSize` so the window minimum is the split view's content minimum
and state restoration can't pin it narrower; `.defaultSize` retained),
`DJRoomba/Views/ExtensionInspectorView.swift` (D1 title removed + label
moved inside as a Section; D2 `inspectorRow` helper with
truncation/selection + wrapping footer; D2 deeper: `Form`
`.padding(.trailing, 4)` trailing inset),
`DJRoomba/Views/MainShellView.swift` (D2 `inspectorColumnWidth`
280→300/320/420; detail ideal 720→660), `DJRoomba/Music/ImportService.swift`
(D3 `TaskGroup` → serial loop; progress UX kept; honest perf finding in the
doc comments).
Schema, the SQLite write path, playback recording, empty-state logic,
auto-start, and signing identities: **untouched** (verified-good Phase-5
items not regressed). Docs corrected: this entry, `PLAN.md` (Phase 5
summary), `PROGRESS.md` Phase-5 entry (false estimate struck in place),
`plans/architecture.md`, `plans/risks-and-challenges.md`,
`plans/roadmap.md`. swiftui-pro applied before & after (Form/LabeledContent
idiom, structured concurrency serial loop, no GCD/`Task.detached`, switch-
expression, no force-unwrap); macos-design applied to D1+D2 (inspector
identity inside the panel, native panel width, truncate-not-clip);
typography unaffected (no new type roles — reused `.headline` for the
in-panel inspector label and the existing `.caption`/`.secondary` tier).

## 2026-05-15 — Phase 5 (POLISH, EXTENSION READINESS, HARDENING) — code-complete, runtime-unverified, not committed

The final phase. Polish, the extension boundary surface, edge hardening, an
import perf pass, broader tests, the final skill review, and distribution
readiness (docs/analysis only — **nothing notarized**). `make check` green;
`swift test` → **67 tests / 14 suites passed** (51/11 → 67/14: +9
`LibrarySidebarStateTests`, +4 `MusicContextBoundaryTests`, +3
`EdgeHardeningTests`). Signed `make` build produced: `build/DJRoomba.app`,
codesigned `Apple Development: Thomas Ptacek (7F2QE7P59D)`, team `KK7E9G89GW`,
bundle `org.sockpuppet.djroomba`, valid on disk, satisfies its Designated
Requirement. **Not committed.** The agent CANNOT run the app — the
orchestrator runs the final signed gate (see "Runtime-unverified" below).

**What was built (per Phase-5 scope):**

1. **Smarter empty / error states (cause inferred).** New pure, unit-tested
   `LibrarySidebarState.resolve(...)` cross-checks `MusicSubscription`
   (`hasCloudLibraryEnabled` — the key signal, confirmed present on the macOS
   26.4 SDK) + authorization + import/store problem + summaries to decide the
   *cause*: `.libraryNotSynced` (Sync Library off → MusicKit genuinely has no
   on-device library — distinct from empty), `.subscriptionNeeded`,
   `.noImportedPlaylists`, `.error`, `.loading`, `.populated`. New
   `SidebarUnavailableView` renders the matching native, non-modal
   `ContentUnavailableView` with the action that actually fixes it
   ("Open Music" deep-link for not-synced; "New Playlist" stays reachable in
   every empty case — the create affordance is a destination). `PlaylistSidebar`
   routes on `controller.sidebarState`; the decision is out of the view body
   (swiftui-pro). Retires the risk register's "Empty/failure modes are silent".

2. **Now-playing auto-start polish (carried Phase-3/4 follow-up).**
   `PlaybackService.setQueueAndPlay`: after `player.play()` + the existing
   bounded `confirmPlaybackStarted()`, if not yet `.playing` it **re-issues
   `play()` once** (bounded, idempotent, structured concurrency) — on macOS the
   queue can still be loading when `play()` resolves and the engine settles to
   `.paused` (the "showed ▶ at 0:05 until the transport was pressed"
   symptom). `confirmPlaybackStarted()` now calls `refreshSnapshot()` the
   **instant** it sees `.playing` so the now-playing bar flips to playing
   immediately (no waiting for the next 0.5 s poll, no manual transport
   nudge). The verified `play_event`/`song_stat` recording is unchanged — it
   still fires only on the confirmed start (`didStart`), so play-tracking is
   NOT regressed.

3. **Extension surface — the collapsible `.inspector()`.** `MainShellView`
   gains a native macOS-14 `.inspector(isPresented:)`, **collapsed by
   default** (`@SceneStorage "inspectorPresented" = false`), toggled from a
   trailing toolbar button (`sidebar.trailing` — the standard inspector-toggle
   placement/idiom). New `ExtensionInspectorView` is a `Form`/`Section`/
   `LabeledContent` panel that **observes the read-only `MusicContext`** and
   acts **only** by submitting `MusicCommand`s to `controller.handle(_:)` —
   it never imports/touches `ApplicationMusicPlayer`, the MusicKit services,
   or the store (the exact contract a future extension must honor, proven by
   construction). `MusicContext` enriched with display fields
   (`selectedPlaylistName`/`nowPlayingTitle`/`nowPlayingArtist`, an
   `isPlaying` convenience) — still plain `Sendable`/`Equatable` `String`s +
   the local `Status` enum, **no MusicKit identity types cross the boundary**
   (`PlayerStateSnapshot.Status` made `Equatable`). This is the M3 boundary,
   finally realized as a real surface.

4. **Edge / error hardening + tests.** Audited the spec checklist:
   disappeared-playlist (controller already clears selection silently after
   re-import — verified path), unplayable/region-removed track (resolver
   tolerates + reports via `playbackProblem` — verified), rapid playlist
   switching (`PlaylistDetailService.select` cancels the in-flight load —
   now pinned by a test that three back-to-back selects land on the *last*),
   clear-drops-in-flight-load (tested), network-down during import/resolve
   (caught → inline `lastError`/`playbackProblem`). New `EdgeHardeningTests`
   (3) cover the deterministic parts; network-down / huge-library remain
   signed-run / load behaviors.

5. **Performance pass for large libraries (bounded-parallel import).**
   > ⚠️ **SUPERSEDED — see the "Phase 5 CORRECTIVE" entry at the top.** The
   > bounded-parallel `TaskGroup` described below was **measured ineffective**
   > on the signed build (~119 s — no improvement over the prior ~88 s,
   > slightly worse, plus instability) because the dominant cost is
   > MusicKit's own per-playlist track resolution on macOS, which is CPU-
   > bound and internally serialized (a single huge library playlist alone
   > is an indivisible long task; concurrent `with([.tracks])` calls contend
   > rather than overlap). It was **reverted to the simple serial loop**,
   > keeping only the "Importing N of M" progress affordance. **The
   > "~88 s → ~20–35 s (estimated)" claim below is WRONG and was never
   > measured.** Honest finding: a full re-import of a ~270-playlist /
   > ~8200-track library is **~90–120 s**, MusicKit-bound, accepted as the
   > v1 cost (one-time / Refresh-only). The original text is retained
   > verbatim below only as audit history; do not act on it.

   _(Audit history — superseded by the corrective above.)_ The
   ~88 s first import was dominated by the **MusicKit** per-playlist
   `playlist.with([.tracks])` paging issued strictly one-at-a-time across
   ~270 playlists (NOT SQLite — batch idioms already correct & tested). The
   slow part is network/IO-bound, so the track fetch is now **bounded-parallel**
   via a sliding `TaskGroup` window of **6** (`Playlist`/`Track` are
   `Sendable`, verified on the SDK; structured concurrency, no GCD, doesn't
   flood MusicKit — same philosophy as the Phase-4 resolver). The SQLite
   write path (`writePlaylist` = the unchanged batched UPSERT + transactional
   snapshot replace) stays **strictly serial** so the proven **one-way
   isolation is not regressed at all** — only *when* the slow fetches happen
   changed (the existing `AppPlaylistCRUDTests` isolation invariant + the
   `BatchImportTests` still pass unchanged). Progress affordance: the sidebar
   loading state now shows **"Importing N of M playlists…"**
   (`controller.libraryLoadingMessage` from `ImportService`'s existing
   counts, which now advance as each playlist is *written*). ~~**Estimated
   effect:** with the dominant cost being ~270 sequential network round-trips,
   a window of 6 should cut wall-clock by roughly the parallelism factor
   (order-of-magnitude: ~88 s → ~20–35 s, throttling-dependent) — *estimated,
   not measured*~~ **[STRUCK: false, never measured — see corrective]**
   (the orchestrator's signed
   run is the measurement). **Incremental import: investigated, DELIBERATELY
   DEFERRED** — `Playlist.lastModifiedDate` exists on the SDK, but on the
   macOS-14 *library* it is in the same frequently-nil category as
   `trackCount`/`isEditable`/`description` (risk register), and skipping a
   re-import on a mis-read/nil date would silently ship a **stale snapshot**
   — a correctness regression of the verified one-way import, which the scope
   forbids. The safe high-confidence win (parallel fetch, zero correctness
   risk, no schema change) was shipped; faking an unreliable signal was not
   (scope: "if not cleanly available, don't fake it"; "prefer a solid
   finish"). No schema change anywhere in Phase 5 (`eraseDatabaseOnSchemaChange`
   stays false; v1 frozen).

6. **Broadened tests + final skill pass.** +16 tests (see counts above). Skill
   gates applied **before & after**: swiftui-pro (drove: pure
   `LibrarySidebarState.resolve` out of the view body; `sheet`/state idioms;
   `@SceneStorage` for inspector collapse not inside `@Observable`; structured
   concurrency for the auto-start re-issue + bounded import `TaskGroup`;
   `Sendable` `MusicContext` boundary; *after*: extracted inspector button
   actions into methods — `togglePlayPause`/`playSelected` — no logic in
   `body`/closures, one type per file, `action:` shorthand, no force-unwrap,
   no deprecated API), macos-design (native `.inspector()` Form/Section/
   LabeledContent collapsed-by-default with the standard trailing toolbar
   toggle; cause-specific non-modal `ContentUnavailableView`s with the
   fixing action; minimal not a feature dump), typography-designer (**no new
   type roles** — `ContentUnavailableView` keeps its native type; the
   inspector uses default macOS `Form`/`LabeledContent`/`Section` styling +
   the existing `.caption`/`.secondary` notice tier for the one explainer
   line; confirmed consistent with the established scale).

7. **Distribution readiness (analysis + docs only — NOTHING notarized).**
   Reviewed `make dist`/`build.sh`/`Makefile`/entitlements/Info.plist for
   internal consistency: the pipeline (`check-version → clean → release →
   sign → zip-notary → notarize → staple → zip-release → checksum →
   verify-release`) is internally consistent; the two-zip dance is correct
   for offline Gatekeeper; `notary-setup` is correctly blocked from
   non-interactive shells; entitlements (`app-sandbox` + `network.client`) +
   `NSAppleMusicUsageDescription` are distribution-correct for the
   library-only MusicKit path; the dev build signs cleanly with no embedded
   profile (Phase-1 fact, re-confirmed). **Did NOT run `make
   dist`/`notarize`/`notary-setup`** (cannot — they need the user's
   interactive setup + a `vX.Y.Z` tag + Apple credentials; the Makefile
   intentionally blocks `notary-setup` from non-interactive shells, respected).
   Signing identities unchanged. Analysis of the open question + the exact
   remaining USER steps are in `plans/risks-and-challenges.md` (Distribution)
   and the "Remaining user steps to ship" section below.

8. **Catalog search:** DEFERRED (documented, not half-implemented) — the
   entire shipping path is library-namespace by provenance; the catalog
   request branch stays dormant; adding catalog search would activate the
   open catalog/MusicKit-App-Service/distribution risk and is out of scope
   for a solid finish (scope sanctions documenting it deferred).

**Runtime-unverified (the orchestrator's final signed gate):** the
cause-specific empty/error states (need a not-synced / no-subscription Mac
state to truly exercise each branch — the *logic* is unit-tested, the
MusicKit signals are not), the auto-start (Play reliably begins *playing* with
no transport nudge + the now-playing bar flips immediately), the inspector
(toggle, observes live `MusicContext`, commands act, never crashes the
player), edge cases under a real library, and the **measured** import
wall-clock improvement. Code-complete here; honestly not runtime-exercised
(no live MusicKit/account/subscription in the agent environment).

**Remaining USER steps to ship (distribution):**
1. `make notary-setup` once — interactive; stores the `djroomba-notary`
   keychain profile (app-specific password from appleid.apple.com). The
   agent cannot and must not do this.
2. `git tag vX.Y.Z` then `make dist` — Developer ID sign + hardened runtime
   + notarize + staple + zip + checksum + `spctl` verify.
3. **The open MusicKit-App-Service question (analyzed):** the most likely
   answer is that the **library-only** path DJ Roomba ships (provenance
   `.library`, `MusicLibraryRequest`/`ApplicationMusicPlayer` only, catalog
   branch dormant) needs **no embedded provisioning profile** on a notarized
   Developer ID build either — consistent with Phase 1's finding that the
   dev build needed none, because the MusicKit App Service / a
   `com.apple.developer.musickit` entitlement gates **catalog** + the
   developer-token web flow, neither of which the shipping path exercises.
   This is **not yet runtime-proven for a Developer-ID/notarized build**
   (different cert chain; notarization validates capabilities against the
   App ID). If the notarized build fails to read the library, the
   pre-wired escape valve is: enable the MusicKit App Service for App ID
   `org.sockpuppet.djroomba` in the Developer portal, generate a
   `.provisionprofile`, and `make dist PROVISION_PROFILE=/path/to.profile`
   (build.sh embeds it + the sign step picks it up). No code/signing-identity
   change is needed for this; it is a portal + one-flag step.
4. Each end user needs their own active Apple Music subscription + their own
   system Apple Account with Sync Library on (Option A, by design; the new
   empty states now explain this in-app if it's missing).

- Files: **new** `DJRoomba/Models/LibrarySidebarState.swift`,
  `DJRoomba/Views/Sidebar/SidebarUnavailableView.swift`,
  `DJRoomba/Views/ExtensionInspectorView.swift`,
  `Tests/DJRoombaTests/LibrarySidebarStateTests.swift`,
  `Tests/DJRoombaTests/MusicContextBoundaryTests.swift`,
  `Tests/DJRoombaTests/EdgeHardeningTests.swift`. **Changed**
  `MusicSubscriptionService.swift` (+`hasCloudLibraryEnabled`),
  `MusicController.swift` (+`sidebarState`/`libraryLoadingMessage`; enriched
  `musicContext`), `PlaybackService.swift` (auto-start re-issue + immediate
  snapshot), `MusicContext.swift` (display fields + `Equatable` +
  `isPlaying`), `PlayerStateSnapshot.swift` (`Status: Equatable`),
  `ImportService.swift` (bounded-parallel fetch — **later reverted to serial
  in the Phase-5 CORRECTIVE; see top entry** / serial unchanged write),
  `PlaylistSidebar.swift` (routes on `sidebarState`),
  `MainShellView.swift` (`.inspector()` + toolbar toggle). Schema, the
  write path, playback recording, and signing identities: **untouched**.
- Docs updated: this entry, `plans/roadmap.md` (Phase 5 status),
  `plans/risks-and-challenges.md` (retired/downgraded resolved items +
  Distribution steps), `plans/architecture.md` (extension surface as built +
  the import perf shape + empty-state inference), `PLAN.md` index still
  accurate. **Not committed** (CLAUDE.md).

## 2026-05-15 — Phase 4 ✅ PASSED the signed runtime gate (all D1–D4 fixed; one orchestrator fix)

Phase 4 is **runtime-verified on a signed build** against the real library
after one functional pass + two UI correctives + one surgical orchestrator
fix. `make check` green; `swift test` **51/11** green; signed build valid;
**nothing committed** (HEAD `112e1b3`).

**Verified live:**
- App-playlist **CRUD**: create (`+`/⌘N), add songs (track context-menu
  "Add to Playlist ▸" submenu), **rename** (native modal `RenamePlaylistSheet`
  via context-menu trigger — commits on Return *and* the Rename button *and*
  blur, Esc cancels, text auto-selected), delete (native `confirmationDialog`
  with reassuring copy). **One-way isolation DB-confirmed**: every app
  mutation left `apple_playlist*`/`song`/`play_event` counts unchanged.
- **App-playlist playback** via the per-id `equalTo` re-resolution
  (`resolveAppPlaylist`, bounded TaskGroup) — **real audio played**
  ("Give It Away"); this is the 🟠 app-playlist re-resolution risk's
  Phase-4 resolution, now proven.
- **Play-tracking bug fixed** (the Phase-3 follow-up): `play_event` +
  `song_stat` now record on *confirmed* playback start —
  observed play_count increment to 1→2→3 and persist, `last_played_at`
  surfaced as "N minutes ago".
- Sidebar "My Playlists" section, **sortable Plays/Last Played columns**,
  all reactive (D3 count / D4 stats refresh verified live).

**The 4 UI defects the first gate caught — all fixed & re-verified:**
- **D2** phantom rounded-gray Table rows → `.bordered(alternatesRowBackgrounds:)`
  clean native empty space. ✅
- **D3** stale sidebar count → `PlaylistSummary.==` now compares
  `trackCount`+`name` so the row re-renders. ✅
- **D4** stale Plays/Last Played → `PlaylistDetailService.refreshStats(for:)`
  on discrete events (play recorded; (re)selection). ✅
- **D1** rename → moved to a deterministic modal sheet (focus/select were
  unreliable inline-in-`List`); the double-click-rename gesture removed
  (it collided with the M2 double-click-to-play). **Final orchestrator
  fix:** `PlaylistSidebarList`'s `.onKeyPress(.return)` Return-to-play was
  unscoped and hijacked Return from the rename sheet's default button
  (Return *played* instead of committing). Gated it on `listFocused` so
  Return-to-play only fires when the sidebar list itself is focused — M2
  Return-to-play unchanged for keyboard nav; the sheet (and the search
  field) now correctly own Return when focused. Verified: Return in the
  sheet commits + dismisses + persists, `play_event` unchanged.

Skill gates: swiftui-pro (focus/concurrency/`@FocusState`/`.onKeyPress`
scoping — clean), macos-design (modal rename + native Table empty space +
context menu + confirm dialog — native, validated live), typography-designer
(no type changes — confirmed). Non-blocking Phase-5 polish carried:
playback can start paused until the transport is pressed (now-playing
snapshot immediacy / auto-start).

## 2026-05-15 — Phase 4 D1 ROBUSTNESS FIX (rename collision + inconsistent commit) — code-complete, runtime-unverified, not committed

The prior Phase-4 UI corrective's D2/D3/D4 fixes were runtime-verified by the
orchestrator and are **untouched**. Its D1 fix (inline-in-`List` rename) was
re-tested on the signed build and still failed the stickler bar with **two**
remaining defects, both root-caused and fixed here as a single, robust,
trigger-independent rename path. Only the rename trigger + the rename editor
changed — playback, the D2/D3/D4 fixes, the data layer, schema, and
`renameAppPlaylist` are **untouched** (the DB persists correctly whenever
commit actually fires; the bug was that commit didn't reliably fire). `make
check` green; `swift test` → **51 tests / 11 suites passed** (unchanged — this
is a view/presentation change; the testable rename logic still lives in the
already-tested `AppPlaylistService.rename` / `LibraryStore.renameAppPlaylist`
path, and `UIRefreshCorrectionTests.summaryEqualityReflectsName` still pins
that a name change re-renders the row). Signed `make` build produced:
`build/DJRoomba.app`, codesigned `Apple Development: Thomas Ptacek
(7F2QE7P59D)`, valid on disk, satisfies its Designated Requirement. **Not
committed.** The agent CANNOT run the app — the orchestrator re-runs the
signed gate (context-menu Rename → focused field with selected text → Return
commits+dismisses+persists; re-enter → click Rename button commits+persists;
re-enter → Esc/Cancel = no change; double-click a My-Playlists row does NOT
rename).

- **Root cause (1) — double-click rename ↔ play collision.**
  `AppPlaylistRowItem` carried a `.simultaneousGesture(TapGesture(count: 2))`
  that called `beginRename()`. The enclosing `List(selection:)` already
  treats a double-click (and Return) on a sidebar row as "play this
  playlist" (an M2 feature: `PlaylistSidebarList`'s `.onKeyPress(.return)` +
  the List's own double-click row activation, both routing to
  `playSelectedPlaylist()`). A double-click on a "My Playlists" row therefore
  *both* started rename *and* started playback (`play_event` bumped) —
  jarring, unacceptable. *Fix:* the `.simultaneousGesture` is **removed
  entirely**. Rename is **context-menu-only** ("Rename", the discoverable,
  standard, collision-free macOS trigger). Double-click on a My-Playlists row
  now does exactly what it does on every other sidebar row (select / play),
  nothing else. The optional slow-second-click Finder idiom was deliberately
  NOT added — on macOS 14 it cannot be cleanly distinguished from the List's
  double-click/Return-to-play without risking that M2 behavior; context-menu-
  only is the clean, native choice (macos-design).
- **Root cause (2) — inconsistent commit across triggers.** The commit-on-
  blur path lived in `.onChange(of: fieldFocused)` on a `TextField`
  *conditionally swapped into a `List(selection:)` row*. `@FocusState` on
  that field competes with the `List`'s own first-responder/selection
  handling, and the field-editor `selectAll` is timing-sensitive. When
  rename was entered via the **context menu**, the menu's focus handoff
  raced the `.task(id: isRenaming)` `Task.yield()`-then-focus so the field
  often never truly became first responder; clicking the detail pane then
  produced no `focused → false` transition, so `commit()` never ran and the
  typed name was lost. A double-click-initiated rename happened to win the
  focus race differently and *did* commit on blur — hence the inconsistency.
  The blur-commit through `@FocusState` inside a conditional `TextField`
  inside a `List` is fundamentally timing-fragile (the List steals the
  click/Return the field needs). *Fix:* **the rename editor is now a modal
  `RenamePlaylistSheet`** (new `RenamePlaylistSheet` + a small
  `PlaylistRenameRequest` `Identifiable` value driving `sheet(item:)`). A
  sheet's `TextField` is the *sole* first responder — the `List` no longer
  competes — so focus + select-all are deterministic, and commit is an
  **explicit, identical** Rename (default button / Return) or Cancel
  (Esc / Cancel button) **every time, regardless of trigger**. The single
  `commit()` (with the `canCommit` non-empty guard) is the one code path;
  `controller.renameAppPlaylist` still ignores empty/unchanged names. The
  click-away-commits requirement of the old inline design is replaced by the
  sheet's explicit, unambiguous Rename/Cancel — *more* consistent, not less
  (no ambiguous "where did I click to blur" path remains).
- **Chosen design + macos-design rationale.** Trigger: context-menu only
  (double-click is already "play" here; overloading it was the collision).
  Editor: a small modal rename sheet — a **standard, fully native macOS
  pattern** (the common fallback Mac apps use for sidebar rename when inline
  is unreliable; macos-design: panels/sheets for modal-ish interactions).
  Given the proven inline-in-`List` fragility on macOS 14, correctness over
  the inline aesthetic — the spec explicitly sanctions the sheet when it is
  more robust, and it is 100% consistent. The new-playlist flow still drops
  straight into rename (create → the row lands in `summaries` → the sheet
  opens via `.onChange(of: summaries)`, deterministic against the async
  store reload). The destructive-delete `confirmationDialog` is unchanged.
- **swiftui-pro before & after.** *Before* drove: a modal `sheet(item:)`
  over fighting `@FocusState` inside a `List` row; the
  `Task.yield()`-then-focus + AppKit field-editor `selectAll` kept (now
  deterministic because the sheet owns first responder); structured
  concurrency only (no GCD/`asyncAfter`/`Task.sleep` hack); one commit path
  guarded by `canCommit`. *After* review applied/clean: `sheet(item:)` for
  safe optional unwrap (navigation.md), button actions as methods, accessible
  buttons (text labels + `.defaultAction`/`.cancelAction` roles, no icon-only
  / no `onTapGesture`-as-action), `AppKit` auto-imported (no redundant
  `import`), no force-unwrap, one type per file, no deprecated API. The
  immediate `openPendingRenameIfReady(in: summaries)` fast-path in
  `createPlaylist()` reads a possibly-stale captured snapshot but is
  idempotent and backstopped by `.onChange(of: summaries)` — correct by
  design, not a defect.
- **typography-designer: not triggered — zero type changes.** The sheet's
  title is the semantic `.headline`, the field default `TextField` text, the
  buttons default — no new font / size / weight / scale / label-role. The row
  reverts to the pre-existing `.body` name + `.caption`/`.secondary` count
  (identical to the imported `PlaylistSidebarRow`).
- Files: **new** `DJRoomba/Models/PlaylistRenameRequest.swift`,
  `DJRoomba/Views/Sidebar/RenamePlaylistSheet.swift`; **changed**
  `AppPlaylistRowItem.swift` (gesture removed; rename props slimmed to
  `beginRename`), `AppPlaylistSidebarRow.swift` (reverted to a plain
  non-editing row — no `TextField`/`@FocusState`/`.task`/AppKit hack),
  `AppPlaylistSidebarSection.swift` (`renamingID` → `renameRequest` +
  `sheet(item:)` + create-then-rename deferral). `MusicController.rename
  AppPlaylist`, playback, data layer, schema, D2/D3/D4: **untouched**.
- Docs updated: this entry, `plans/architecture.md` (the Phase-4 UI
  corrective's inline-rename note superseded by the sheet), `PLAN.md`
  Milestone-4 line still accurate. **Not committed** (CLAUDE.md).

## 2026-05-15 — Phase 4 UI CORRECTIVE (4 stickler-bar UI defects) — code-complete, runtime-unverified, not committed

The Phase-4 signed-build gate confirmed the **core works** (app-playlist CRUD
with one-way isolation DB-verified; per-id app-playlist playback plays real
audio; play-tracking fires on confirmed start; native context menu + delete
dialog) but caught **4 UI defects** that failed the UI bar. All four are
view/reactivity bugs — the verified-good data layer, playback, resolution and
schema are **untouched** (no schema change). `make check` green; `swift test`
→ **51 tests / 11 suites passed** (46→51: +5 `UIRefreshCorrectionTests`
pinning the D3 equality + D4 stats-refresh fixes). Signed `make` build
produced: `build/DJRoomba.app`, codesigned `Apple Development: Thomas Ptacek
(7F2QE7P59D)`, team `KK7E9G89GW`, bundle `org.sockpuppet.djroomba`, valid on
disk, satisfies its Designated Requirement. **Not committed.** The agent
CANNOT run the app — the orchestrator re-runs the signed gate (rename via
menu + double-click; no phantom rows; sidebar count after add; Plays/Last
Played after a play). Code-complete; runtime-unverified.

- **D1 — inline rename was non-functional → fixed.** *Root cause:* the
  rename `TextField` is inserted by `if isRenaming` in
  `AppPlaylistSidebarRow`; `.task(id: isRenaming)` set `@FocusState`
  `fieldFocused = true` in the **same** update pass, before SwiftUI had
  committed the conditional branch and registered the `.focused` binding —
  setting focus on a field not yet in the focus system is a no-op, so the
  field appeared but never took the keyboard (the observed "faint invisible
  box"). Also: **double-click was never wired** (only the context menu
  existed) so that path could never have worked. *Fix:* in the `.task`,
  `await Task.yield()` once (structured concurrency — no GCD/`asyncAfter`) so
  the `TextField` is in the hierarchy and the `.focused` binding registered,
  then assign focus (re-guarded for `isRenaming` + cancellation after the
  suspension). Added select-all on the focus-gained transition via the key
  window's field editor (`@MainActor` AppKit, no representable — macOS 14 has
  no SwiftUI text-selection API) so typing replaces the name, the Finder /
  Music.app idiom. Wired double-click: `.simultaneousGesture(TapGesture(count:
  2))` on `AppPlaylistRowItem` (simultaneous so the List's single-click row
  selection still works; ignored while already editing). Return / blur commit
  + Esc cancel + the double-commit guard are kept; the blur path now only
  commits on focus-**loss** (the gained branch does select-all).
- **D2 — phantom empty rounded-gray pill rows → fixed.** *Root cause:* the
  detail `Table` used the default (`.automatic` → `.inset`) table style,
  whose rounded selection-shaped row backgrounds get drawn for **every empty
  row** below the content in a `NavigationSplitView` detail — the "~7+ empty
  pills" look. *Fix:* `.tableStyle(.bordered(alternatesRowBackgrounds:
  true))` — the flat, full-width alternating striping Music.app / Finder use;
  the empty area below the last track now reads as a clean continuation of
  the table with no rounded shapes (macos-design: native Table empty-space
  treatment).
- **D3 — sidebar "My Playlists" count stale after add/remove → fixed.**
  *Root cause:* the reload path was already correct
  (`AppPlaylistService.load()` re-runs the grouped `appPlaylistTrackCounts()`
  query after every membership write), but `PlaylistSummary.==` compared
  **only `id` + `isFavorite`**, omitting `trackCount`. When the reloaded
  summaries had the same id/favorite but a new count, SwiftUI's `ForEach`
  diffed the row as **unchanged** and never rebuilt its body → "0 tracks"
  persisted. ("Recently Played" looked right because playing the list
  *inserted* that row fresh, forcing a body build with the then-current
  count.) *Fix:* `PlaylistSummary.==` now also compares `trackCount` and
  `name` (so an inline rename re-renders too). Hash stays **id-only** — the
  `Hashable` contract only requires equal values to hash equally and `==`
  still implies equal `id`; no `Set<PlaylistSummary>`/dictionary-key usage
  exists. Efficient: no new query, the count still comes from the single
  grouped batch query (SQLite-idioms guidance honored).
- **D4 — Plays / Last Played columns stale → fixed.** *Root cause:*
  `PlaylistDetailService` caches `PlaylistDetail` per playlist id and only
  (re)loads on a cache **miss** or explicit `invalidate()`; after
  `recordPlay` bumped `song_stat` nothing refreshed the cached rows, and
  re-selecting hit the stale cache. *Fix:* added
  `PlaylistDetailService.refreshStats(for:)` — re-runs the single
  `songsWithStats` LEFT-JOIN query **once** and splices the fresh
  `playCount`/`lastPlayedAt` back into the existing rows (membership/order
  unchanged). Driven by **discrete events only**: `MusicController`
  `recordPlayStart` calls it right after `store.recordPlay`, and `select()`
  on a cache hit serves cached rows instantly then kicks one background
  stats refresh on that (re)selection. No refresh loop, no per-tick / per-row
  re-query — the now-playing 0.5 s snapshot tick is untouched. A failed
  stats refresh is non-fatal (keeps the rows, no error for a count update).
- swiftui-pro consulted **before** (drove: `Task.yield()`-then-focus over
  GCD/`asyncAfter` for the `@FocusState` appearance-timing fix; discrete-
  event `refreshStats` over a `ValueObservation`/tick; id-only hash with a
  broader `==`; `.simultaneousGesture` so row selection survives the double-
  click) and **after** (review applied: removed a redundant `import AppKit`
  — SwiftUI re-exports AppKit on macOS so `NSApp` resolves; everything else
  reviewed clean: structured concurrency only, methods-not-body, modern
  non-deprecated APIs, Hashable contract upheld). macos-design drove the
  Finder/Music inline-rename idiom (auto-focus + select-all + double-click,
  commit-on-Return/blur, cancel-on-Esc) and the flat native Table empty-
  space treatment (`.bordered` striping, no rounded pills).
  **typography-designer: not triggered — zero type changes** (no font /
  size / weight / scale / new label-role changes; the rename field still
  `.body`, the count still `.caption`+`.secondary`, the table cells
  unchanged).
- Docs updated: this entry, the Phase-4 entry's tail (points here),
  `plans/architecture.md` (the D3 equality + D4 stats-refresh notes),
  `PLAN.md` index still accurate. **Not committed** (CLAUDE.md).

## 2026-05-15 — Phase 4 (APP OWNERSHIP: PLAYLISTS + PLAY COUNTS) — code-complete, runtime-unverified, not committed

The actual product value: the user owns their library locally. App playlists
(SQLite-only, never written to Apple), per-song app-playlist playback, the
play-tracking bug fixed, play stats surfaced as sortable Table columns. `make
check` green; `swift test` → **46 tests / 10 suites passed** (35→46: +10
`AppPlaylistCRUDTests`, +1 app-playlist reassembly test). Signed `make` build
produced: `build/DJRoomba.app`, codesigned `Apple Development: Thomas Ptacek
(7F2QE7P59D)`, team `KK7E9G89GW`, bundle `org.sockpuppet.djroomba`, valid on
disk, satisfies its Designated Requirement; the exported drag UTI is in the
bundled Info.plist. **Not committed.** The agent CANNOT run the app — app-
playlist playback (real audio), play-count persistence, and the sidebar
CRUD/drag UX remain for the orchestrator's signed runtime gate; nothing about
playback or persistence is claimed verified here.

- **App-playlist CRUD (SQLite-only, batch idioms, one-way isolation).**
  Extended `LibraryStore` with `createAppPlaylist(named:)` (sort_index =
  `MAX+1` computed inside the write so concurrent creates can't collide),
  `renameAppPlaylist`, `deleteAppPlaylist` (membership cascades per the v1
  FK; song/stat/history untouched), `addSongsToAppPlaylist` (append at tail,
  chunked multi-row INSERT, next-position read inside the same txn),
  `removeTracksFromAppPlaylist` (chunked `IN` delete + dense renumber, all in
  one txn — keeps the `(playlist,position)` PK gap-free), `setAppPlaylistTracks`
  (bulk-delete + chunked multi-row re-insert — the reorder/replace path),
  `reorderAppPlaylists` (chunked `CASE … WHEN` UPDATE — no per-row loop),
  `appPlaylistTrackCounts` (one grouped query for sidebar counts),
  `songsWithStats(in{App,Apple}Playlist:)` (one indexed LEFT JOIN on
  `song_stat`). **No schema change** — the Phase-2 `app_playlist*` tables +
  v1 cascade sufficed (v1 stays frozen; `eraseDatabaseOnSchemaChange` still
  false). New `AppPlaylistService` (`@MainActor @Observable`) owns the
  user-playlist listing + CRUD, awaits the off-main store, reloads from
  SQLite after each write (no dual store). 10 new tests prove order,
  duplicates, chunk-boundary correctness (800-song add), the delete cascade,
  and — crucially — that **every** app-playlist mutation leaves the imported
  `apple_playlist*` snapshot + song/stat/history untouched.
- **App-playlist playback — the per-song 1:1 path (the 🟠 open item,
  resolved in code).** Imported Apple playlists keep the proven
  playlist-granularity re-resolve (`resolvePlaylist`). App playlists are
  arbitrary songs with no backing Apple playlist, so `MusicController.resolve
  AndPlay` now branches on `detail.isAppOwned` to the new
  `PlaybackResolver.resolveAppPlaylist(rows:startAt:)`: it re-resolves each
  **unique** stored library id via `MusicLibraryRequest<MusicKit.Song>`
  `.filter(matching:\.id, equalTo:)` **one id at a time** (the Phase-3 probe
  established this preserves the query→result 1:1 correspondence; only batch
  `memberOf` loses it because the returned `Song.id` differs), issued through
  a **bounded** `TaskGroup` (sliding window of 8 — structured concurrency, no
  GCD, no flooding MusicKit), keyed by the **stored** id, then `reassemble`d
  in playlist order tolerating misses (reported via the existing inline
  `MusicController.playbackProblem`). The disproven batch-`memberOf`
  `resolve(rows:startAt:)` + its `fetchLibrarySongs` helper were **removed**
  (dead, contradicted the working path); the pure `groupByNamespace`/
  `reassemble` helpers + tests are kept and now back `resolveAppPlaylist`.
  Reuses the **unchanged** `PlaybackService`. **Runtime-unverified** — the
  per-id `equalTo` re-fetch + audio is a signed-run check (the agent can't
  run it). Verified MusicKit API shapes (macOS 26.4 SDK): `MusicLibraryRequest
  <Song>.filter(matching:\.id, equalTo: MusicItemID)`, `.limit`, `.response()`
  → `MusicItemCollection<Song>`; `MusicItemID` conforms to the equatable
  filter-value protocol; `MusicKit.Song` is `Sendable` (crosses the
  `TaskGroup`; strict-concurrency build clean).
- **Play-tracking bug fixed (the Phase-3 follow-up).** The old `if playback.
  snapshot.isPlaying` guard read the 0.5 s-polled snapshot too early so plays
  never recorded. `PlaybackService.play` now returns `Bool` and, after
  `player.play()`, `confirmPlaybackStarted()` polls the player's **own**
  `state.playbackStatus` on a short bounded loop (50 ms, ≤2.5 s, `Task.sleep
  (for:)` — never the nanoseconds form) until `.playing`. `recordPlayStart`
  fires only on a confirmed start and records the **stored `song.id`** the
  resolver now reports (`Resolution.startSongID`) — deterministic and correct
  for both paths, replacing the fragile now-playing-id→row match (the
  resolved `Song.id` ≠ the stored `music_item_id`, so that match was
  unreliable; this is the same Track-id≠Song-id finding). `recordPlay` /
  `song_stat` machinery (Phase 2) is unchanged and still tested.
- **Sidebar "My Playlists" + native CRUD/drag UI (macos-design reviewed).**
  New section distinct from Favorites / Recently Played / Library Playlists,
  **always present** (even with zero playlists / no imported library) so the
  create affordance is reachable. Inline `+` in the section header + `⌘N`
  (`CommandGroup(replacing: .newItem)`). Inline rename (`TextField` swapped
  into the row; Return / focus-loss commits, Esc cancels; double-commit
  guarded). Destructive delete via `confirmationDialog` (clean `$Bool`
  binding + `presenting:` — no `Binding(get:set:)`; copy reassures
  songs/play-counts are kept). Per-row context menu (Play / Rename /
  Favorite / Delete). Drag-to-reorder playlists (`onMove`). Track rows are
  `.draggable` (private `SongDragItem` `Transferable` over an exported
  app-scoped UTI — never a public interchange format) and "My Playlists"
  rows are `.dropDestination` so a dragged song appends; a track-table
  context-menu **"Add to Playlist ▸"** submenu is the always-reachable
  equivalent, plus **"Remove from Playlist"** when viewing an app playlist.
  Views extracted per swiftui-pro (`AppPlaylistSidebarRow`,
  `AppPlaylistRowItem`, `AppPlaylistSidebarSection`, `TrackContextMenu`,
  `SongDragItem`) — one type per file, button actions as methods, no
  `@ViewBuilder`-method body splitting.
- **Play count + last played as sortable Table columns.** Two new
  `TableColumn`s ("Plays", "Last Played"), and every column made sortable via
  `Table(…, sortOrder:)` + `KeyPathComparator` (default = playlist order, so
  an unsorted table is pixel-identical to Phase 3). Stats come from the one
  LEFT-JOIN `songsWithStats` query carried into `TrackRow` at load — sorting
  is in memory (fast; the rows are fetched once per selection, never re-hits
  SQLite). Non-optional sort keys (`albumSortKey`/`durationSortKey`/
  `lastPlayedSortKey`) so the native header sort is well-defined.
- swiftui-pro consulted **before** (drove: coarse intent-named store CRUD with
  batch SQL in one `write`; a separate `@MainActor @Observable`
  `AppPlaylistService` awaiting the off-main store; bounded `TaskGroup` for
  per-id resolution; `Resolution.startSongID` instead of fragile id-matching;
  in-memory `KeyPathComparator` sort over re-querying; `Transferable` over
  raw pasteboard) and **after** (applied: extracted the context menu +
  sidebar row/item into their own `View` files, button actions into methods,
  removed the dead disproven `resolve()`, bounded the resolve concurrency,
  guarded the rename double-commit, `$Bool`+`presenting:` over a manual
  binding, `.task(id:)` over `onAppear`, `Task.sleep(for:)`). macos-design
  drove the always-present "My Playlists" section, the inline-`+`/⌘N create,
  Finder-style inline rename, the destructive `confirmationDialog`, the
  context-menu + drag pairing (reachable equivalent), and keeping the table
  deliberately boring. typography-designer: **zero new type roles** — "Plays"
  reuses the `.body.monospacedDigit()`+`.secondary` numeric tier (like
  #/Time), "Last Played" the `.body`+`.secondary` text tier (like
  artist/album), the rename field `.body` (matches the row name), the section
  header the default `Section` styling (identical to the other sections).
- Docs updated: this entry, `plans/data-and-import.md` (the app-playlist CRUD
  store API + per-song re-resolution + play-tracking trigger), `plans/
  architecture.md` (Phase 4 layering: `AppPlaylistService`, the two playback
  paths), `plans/risks-and-challenges.md` (the 🟠 per-song re-resolution
  item → addressed in code, runtime-pending), `PLAN.md` index still accurate.
  **Not committed** (CLAUDE.md).
- **Signed-gate outcome → see the "Phase 4 UI CORRECTIVE" entry at the top
  of this file.** The signed-build computer-use gate confirmed the Phase-4
  core works (CRUD/isolation, real-audio app-playlist playback, fixed play-
  tracking, native menu/dialog) but caught 4 UI defects (non-functional
  inline rename; phantom empty rounded-gray Table rows; stale "My Playlists"
  count; stale Plays/Last Played). All four root-caused and fixed there as
  view/reactivity-only changes (data layer/playback/schema untouched).

## 2026-05-15 — Phase 3 ✅ PASSED the signed runtime gate (D1 root-caused & fixed)

The 🔴 id round trip is **proven working on a signed build against the real
library**. After the corrective pass's song-level strategy still failed the
gate, a temporary diagnostic probe (roadmap-sanctioned; since **removed**)
found the true root cause and the fix was applied + re-verified live.

**D1 root cause (definitive, from the probe):** a stored `music_item_id` is
the playlist **Track** id, which is *not* the library `Song` id.
`MusicLibraryRequest<Song>.filter(matching:\.id,memberOf:storedIDs)` *does*
return the right songs (10 queried → 10 returned, e.g. "Jacqueline") but
keyed by the songs' own `i.`-prefixed ids — so song-level reassembly by the
stored id matched **0**. Probe Strategy C proved re-resolving the *playlist*
by its stored library id → `.with([.tracks])` returns the live tracks with
ids+order aligned **1:1** with the stored snapshot (overlap 19/19, all
`.song`). That is exactly Phase 1's proven playback path.

**Fix:** `PlaybackResolver.resolvePlaylist(libraryPlaylistID:rows:startAt:)`
re-resolves the Apple playlist by its stored library `MusicItemID`, pages
its live tracks (the proven import loop, same cap), extracts `.song`s in
order, starts at the row matched by live-track id, and plays via the
unchanged `PlaybackService`. `MusicController.resolveAndPlay` calls it with
`detail.id`. The song-level namespace/reassemble helpers + their unit tests
are **kept, documented as the dormant Phase-4 app-playlist/catalog path**
(resolving an *arbitrary* stored song id 1:1 is a real open problem — see
risk register).

**Verified live (signed build, real library):** import 8229 songs / 269
playlists / 25148 memberships one-way (app-owned tables untouched);
sidebar/detail render from SQLite; **"90s Alt" (137 tracks) played — "Give
It Away" audio, elapsed advanced 0:05→0:24/4:43, AirPods routed by the OS,
menu-bar now-playing lit**; real cover art everywhere (D2 fixed); recents
survived the one-shot UserDefaults→SQLite migration (Backpacking, then 90s
Alt). `make check` green; `swift test` **35/9** green; nothing committed.

**Non-blocking follow-ups (not Phase-3 exit criteria):**
- *Phase 4:* `play_event`/`song_stat` did not record — the
  `if playback.snapshot.isPlaying` guard in `resolveAndPlay` reads the
  0.5s-polled snapshot too early. Play-tracking is Phase-4 scope; wire it to
  the actual player-start signal there.
- *Phase 5:* playback started **paused** (showed ▶ at 0:05 until the
  transport was pressed) — auto-start-on-Play reliability + now-playing
  snapshot immediacy is a Phase-5 polish item.
- *Phase 4:* per-song re-resolution for app-playlists (arbitrary songs not
  backed by an Apple playlist) is unsolved — the Track-id≠Song-id finding
  means a different id (or reference) must be captured at add-time.
- *Perf:* D3 batch idioms are correct + tested, but first-import wall-clock
  (~88s) is dominated by MusicKit per-playlist `.with([.tracks])` paging
  across 269 playlists, **not** SQLite (identical plateau before/after the
  SQLite fix). This is the documented 🟡 large-library tradeoff; an
  incremental/parallel import is a Phase-5 perf item.
  > **RESOLVED in the Phase-5 CORRECTIVE (top entry):** this MusicKit-bound
  > diagnosis was *correct*. Parallel import was tried and measured
  > ineffective (the cost is CPU-bound + serialized inside MusicKit, not
  > concurrency-limited) and reverted; incremental import stays deferred
  > (unreliable `lastModifiedDate` on the macOS library → stale-snapshot
  > risk). Honest accepted v1 cost: ~90–120 s for ~270 playlists / ~8200
  > tracks, one-time / Refresh-only, surfaced by the progress affordance.

## 2026-05-15 — Phase 3 CORRECTIVE pass — code-complete, runtime-unverified, not committed

Addressed all three defects the signed-build gate caught (entry below). `make
check` green; `swift test` → **35 tests / 9 suites passed** (31→35: +5 new
`BatchImportTests`, the 3 dead string-heuristic namespace tests replaced by 2
provenance/round-trip tests). Signed `make` build produced:
`build/DJRoomba.app`, codesigned `Apple Development: Thomas Ptacek
(7F2QE7P59D)`, team `KK7E9G89GW`, valid on disk, satisfies its Designated
Requirement. **Not committed.** The agent CANNOT run the app — id round
trip + audio + artwork visuals remain for the orchestrator's signed runtime
re-gate; nothing about playback is claimed verified here.

- **D1 (showstopper) — id round trip, fixed in code.** `ImportService.song
  (from:)` now unwraps the `Track` enum (`.song(let s)` → `s.id.rawValue`,
  `.musicVideo(let v)` → `v.id.rawValue`, `@unknown default` falls back to
  `track.id` so a row is never dropped) and stores the **underlying item's**
  id, with `idNamespace` fixed to `.library` by **provenance** (library
  playlists). The string-sniffing `namespace(forRawID:)` / `namespace(of:)`
  is **deleted entirely** (it had degenerated to integer sign on real data —
  the exact gate failure). `PlaybackResolver` keeps `MusicLibraryRequest<
  MusicKit.Song>().filter(matching: \.id, memberOf:)` as the live path (the
  dev-signed path Phase 1 proved; no catalog entitlement) and the
  `MusicCatalogResourceRequest` branch is explicitly commented **dormant**
  (nothing catalog-namespace is imported). New **inline, non-modal** error
  surface: `MusicController.playbackProblem` (resolver error → unresolved-
  count → player error) rendered in the playlist header as a `.caption`
  `Label` with an `.orange exclamationmark.triangle.fill` glyph + `.secondary`
  text (typography-designer tier; macos-design unobtrusive idiom), value-
  animated. No temp debug affordance was added (none needed; none to remove).
  MusicKit API verified against the macOS 26.4 SDK `.swiftinterface`: `Track`
  is `enum { case song(Song); case musicVideo(MusicVideo) }`; `Song` has
  `let id: MusicItemID` + `var artwork: Artwork?`; `MusicItemID` conforms to
  `MusicLibraryRequestFilterValueMembershipComparable`; `Song`/`Playlist`/
  `MusicVideo` all conform to `MusicLibraryRequestable`.
- **D2 (artwork regression) — fixed in code.** Chose the `ArtworkImage`
  strategy (swiftui-pro + macos-design; it is exactly what Phase 1 used to
  show real art, and `plans/musickit-notes.md` already recommends it). The
  unfetchable private-scheme `artwork_url` is no longer stored (`Song`/
  `ApplePlaylist` keep the column for DB stability but write `nil` — **no
  schema migration needed**, so the v1-frozen rule is honored and no v2 was
  required). New `ArtworkProvider` (`actor`: cached, in-flight-deduped,
  negative-cached, no GCD) lazily re-resolves a live `MusicKit.Artwork` by
  stored `MusicItemID` via `MusicLibraryRequest<Song>` / `<Playlist>` (the
  Apple playlist's own id is a library id). `ArtworkThumbnail` rewritten to
  render `ArtworkImage(artwork, width:height:)` (Phase-1-identical) from a
  new `ArtworkRef` (`.song(id,namespace:)` / `.playlist(id)`); same fixed
  frame / corner radius / `.quaternary`+SF-Symbol placeholder / 0.2s value-
  driven cross-fade / no layout shift. `ArtworkImageLoader` deleted. Models
  (`PlaylistSummary`/`PlaylistDetail`/`TrackRow`/`PlayerStateSnapshot`)
  expose a computed `artworkRef`; all call sites repointed.
- **D3 (perf — user-flagged) — fixed in code.** `LibraryStore.upsertSongs`
  is now ONE transaction of chunked multi-row `INSERT … VALUES (…),(…)
  ON CONFLICT(music_item_id, id_namespace) DO UPDATE SET …=excluded.…`
  that deliberately **does not touch `id`** (stable PK / FKs preserved —
  non-destructive re-import, proven by new tests). New
  `LibraryStore.songIDsByKey(_:)` does the id resolution in ONE chunked
  `WHERE (music_item_id, id_namespace) IN (VALUES …)` query, replacing
  `ImportService`'s per-song N-await re-read loop. `replaceApplePlaylist
  Snapshot` membership insert is now chunked multi-row. All chunked under
  SQLite's 999-variable cap via a new `Array.chunked(into:)`. `SongKey`
  moved onto `LibraryStore`. Behavior identical: existing 31 tests stay
  green; new `BatchImportTests` prove UPSERT preserves `song.id` + FK on
  re-import, the batched lookup is correct across a chunk boundary (1200
  rows), and large-playlist membership stays ordered.
- swiftui-pro consulted **before** (drove: provenance over string-sniffing;
  `actor` provider with negative cache over per-view fetch; GRDB batch SQL
  in one `write`; `ArtworkImage` over a hand-rolled loader) and **after**
  (applied: added the missing value-driven `.animation` for the new inline
  surface; verified `.task(id:)` over `onAppear`, structured concurrency
  only, no GCD, one-type-per-file). macos-design drove the `ArtworkImage`
  choice + the unobtrusive inline-warning treatment. typography-designer set
  the new label's type (`.caption`, regular, `.orange` glyph + `.secondary`
  text — same tier as the subscription notice).
- Docs updated: this entry, `plans/data-and-import.md` (corrected id model +
  artwork + batch-write design), `plans/risks-and-challenges.md` (🔴 round
  trip → diagnosed+corrected, runtime re-verification pending), `PLAN.md`
  index still accurate. **Not committed** (CLAUDE.md).

## 2026-05-15 — Phase 3 RUNTIME VERIFICATION: 🔴 FAILED the gate (corrective DONE in the entry above — see it for the fix; runtime re-gate pending the orchestrator)

Signed-build computer-use verification of Phase 3 (the mandated end-of-stage
gate) **failed the core exit criterion**: the id store→re-resolve→play round
trip does not work. This is the 🔴 architectural risk firing — exactly what
the gate exists to catch. `make check` / `swift test` were green and the
SQLite-backed UI + UserDefaults→SQLite migration verified live (recents
survived: Backpacking), but **playback is broken** and there are two more
defects. Phase 3 is NOT handed off; a corrective pass is underway.

Live-observed on a real signed build against the user's library (270
playlists / 8229 songs / 25162 memberships imported):

- **D1 🔴 (showstopper) — id round-trip broken.** Every stored
  `music_item_id` is an opaque 16–20-digit macOS library `MusicItemID`
  (the persistentID-derived value); **none** are real Apple ids (0 are
  `i.`-prefixed; none are catalog store ids). `ImportService` stores the
  playlist `Track`'s id and the namespace classifier (`i.`→library /
  bare-numeric→catalog / else library) degenerates to *integer sign*:
  negative→"library" (4089), positive→"catalog" (4140). `PlaybackResolver`
  then sends non-catalog ids to `MusicCatalogResourceRequest` (resolves
  nothing) and Track-not-Song ids to the library request → nothing
  resolves → "Not Playing". Phase 1 only ever proved playback from *live*
  `Track` objects; the id-only path was explicitly carried as unproven —
  it is now disproven and must be redesigned. Fix direction: import must
  extract the underlying `Song` from each `Track` and store the Song's
  *library* id with namespace by **provenance** (library-playlist →
  library), dropping the string heuristic; resolver re-resolves those via
  `MusicLibraryRequest<Song>` (the dev-signed path Phase 1 proved; no
  catalog entitlement). Also: resolver/playback `lastError` has no UI
  surface — the failure was silent.
- **D2 (UI regression) — artwork all placeholders.** Stored `artwork_url`
  is `musicKit://artwork/transient/600x600?id=…`, a private scheme
  `URLSession` cannot fetch (macOS library `Artwork.url(...)` does not
  yield an https URL). Phase 1 showed real cover art; Phase 3 shows the
  placeholder everywhere. Must restore real artwork.
- **D3 (perf — user-flagged) — row-by-row import.** Full first import
  pegged a CPU core for ~90s: `upsertSongs` does N `SELECT`+`update`/
  `insert`, `ImportService` does an N-await per-song id re-read loop per
  playlist. User feedback: "there are sqlite idioms for batch inserts/
  updates." Apply UPSERT (`ON CONFLICT(music_item_id,id_namespace) DO
  UPDATE` preserving the stable `song.id` PK) + single IN-list id lookup +
  chunked multi-row membership INSERT. See memory `djroomba-sqlite-batch-idioms`.

Verified-good in Phase 3 despite the above: `make check`/`swift test`
(31/8), SQLite-backed sidebar/detail render, lazy detail from SQLite,
empty/loading states, the one-shot UserDefaults→SQLite favorites/recents
migration (Backpacking recent survived; selection restored). Artwork
*placeholder* rendering itself (frame/no-shift/transition) is correct —
only the source URL is wrong.

## 2026-05-15 — Phase 3 (IMPORT PIPELINE & UI ON SQLITE) — code-complete, not committed

The app now operates **from SQLite**; Apple Music is a one-way import source
+ playback engine only. No user-visible behavior regresses; the data path
underneath changed. `make check` green; `swift test` → **31 tests / 8
suites passed** (20 Phase 2 carried + 11 new). **Not committed.**

- **`ImportService`** (`DJRoomba/Music/`, `@MainActor @Observable`) — paged
  `MusicLibraryRequest<Playlist>` + per-playlist `playlist.with([.tracks])`
  paging (the proven M1 loops, caps `maxPlaylistBatches`/`maxTrackBatches`),
  maps `Track`→`Song` / `Playlist`→`ApplePlaylist`, dedupes per import key,
  writes via `LibraryStore.upsertSongs` + `replaceApplePlaylistSnapshot`
  (transactional). Strictly one-way: only touches `song`/`apple_playlist*`
  (the store guarantees app_playlist*/song_stat/play_event/favorites/recents
  are never touched — Phase 2 test still green). Wired to Refresh (⌘R /
  toolbar) and run on first authorized launch when `songCount() == 0`.
  Namespace capture (`library` vs `catalog`) is a pure, unit-tested
  classifier (`i.`-prefixed → library; bare-numeric → catalog; else
  library) — this is what the resolver keys re-fetch on.
- **Models de-MusicKit-ed** — `PlaylistSummary`/`PlaylistDetail`/`TrackRow`/
  `PlayerStateSnapshot`/`MusicContext`/`MusicCommand` no longer carry live
  `Playlist`/`Track`/`Artwork`/`MusicItemID`; they carry stored ids
  (String) + display fields + `artwork_url`. New `LibraryReadService`
  (sidebar from SQLite) replaces `PlaylistLibraryService` (deleted);
  `PlaylistDetailService` rewritten to read `songs(inApplePlaylist:)`.
  `MusicController` `await`s the store and republishes observable state;
  sidebar "Loading playlists…" now also covers the import window
  (`isLibraryBusy`) so first launch never flashes "No Playlists" — same UI,
  honest state.
- **Artwork from URL** — `ArtworkImageLoader` (an `actor`: `NSCache` +
  in-flight de-dup, `URLSession` async, no GCD/locks) + rewritten
  `ArtworkThumbnail` rendering the stored URL. Pixel-equivalent to the
  Phase-1 MusicKit look (macos-design reviewed): identical fixed frame /
  corner radius / `.quaternary`+SF-Symbol placeholder, no layout shift
  (frame fixed before load), gentle 0.2s value-driven cross-fade (no
  "pop"). All three call sites repointed (sidebar 28/r4, now-playing
  40/r6, header 104/r8).
- **One-shot UserDefaults → SQLite migration** — `LegacyPreferencesMigration`
  reads the M2 `favoritePlaylistIDs`/`recentlyPlayedPlaylistIDs` keys once,
  writes them into `favorite_playlist`/`recent_playlist` (recents stamped
  oldest→newest so `ORDER BY played_at DESC` reproduces the legacy
  most-recent-first order), sets a sentinel, then **never reads the old
  keys again** (no dual write). `FavoritesStore`/`RecentlyPlayedStore`
  deleted; the controller's favorites/recents now go through `LibraryStore`
  (optimistic local update + async persist). `UserPreferencesStore` (last
  selection) stays in UserDefaults by design.
- **`PlaybackResolver`** (`DJRoomba/Music/`, `@MainActor @Observable`) —
  groups a queue's stored rows by namespace (pure, de-duped), batch
  re-fetches library ids via `MusicLibraryRequest<Song>.filter(matching:
  \.id, memberOf:)` and catalog ids via `MusicCatalogResourceRequest<Song>
  (matching:\.id, memberOf:)`, reassembles in original order **tolerating
  unresolvable tracks** (reported via `unresolvedMusicItemIDs`, queue not
  broken — risk register), then plays via the **unchanged** M1
  `PlaybackService` (now takes resolved `MusicKit.Song`s). `recordPlay`
  fires on play start for the track that actually started (song_stat
  rollup is the Phase 2 machinery).
- **Tests added** (no faked MusicKit): `ImportNamespaceTests` (pure
  classifier), `PlaybackResolverTests` (grouping split/dedupe, both-namespace
  non-conflation, reassembly reports every unresolved id + empty queue
  doesn't crash), `LegacyMigrationTests` (pure plan ordering + end-to-end
  one-shot: migrates, idempotent, legacy keys never re-read, empty state
  still completes).
- `swiftui-pro` consulted **before** (drove: plain `Sendable` structs for
  the de-MusicKit'd model layer; `@MainActor @Observable` import/resolve
  services awaiting the off-main `Sendable` store; `actor`+`NSCache`
  loader over `AsyncImage`; pure logic factored as `nonisolated static`
  for testability) **and after** (applied: replaced a `try!` with
  `fatalError(desc)`; removed a redundant dedupe reduce + dead
  `mergeFavoritesIntoSummaries` hook; verified value-driven `.animation`,
  `task(id:)` over `onAppear`, ZStack+opacity over `_ConditionalContent`).
  `macos-design` consulted for the artwork loading/placeholder/fade.
  `typography-designer` **not triggered** — no type/label/scale changes
  (same strings, same fonts; artwork view has no text).
- **🔴 id round-trip status:** the store-id → discard → re-resolve →
  play path is now **code-complete** end-to-end (resolver + repointed
  player + recordPlay) but **runtime-unverified**: only a signed run on
  the user's Mac can finally confirm catalog/library re-resolution and
  audio. The orchestrator will do that signed run. Pure logic is tested;
  the MusicKit-session parts honestly are not (can't be, without a live
  account/subscription).
- Docs updated: `plans/data-and-import.md` (as-built ImportService +
  PlaybackResolver + namespace rule + legacy migration), `plans/
  architecture.md` (Phase 3 layering realized), `plans/
  risks-and-challenges.md` (🔴 round-trip → code-complete /
  runtime-pending), `PROGRESS.md` (this), `PLAN.md` index still accurate.
  **Not committed** (CLAUDE.md).

## 2026-05-15 — Phase 2 (LOCAL STORE FOUNDATION) — DONE, not committed

GRDB SQLite layer landed, **purely additive — no UI, no import wiring, app
behavior unchanged.** `make check` and `swift test` both green.

- **GRDB** added to `Package.swift` (`from: "7.0.0"`, resolved 7.10.0) as a
  dep of the `DJRoomba` target. New `.testTarget DJRoombaTests`. Verified
  `@testable import DJRoomba` of the `@main` executable target links + runs
  on Swift 6.3 SwiftPM, so **no `@main` restructuring needed**.
- **Schema** = one frozen migration `v1.initialSchema` covering all nine
  tables (song, apple_playlist[+track], app_playlist[+track], play_event,
  song_stat, favorite_playlist, recent_playlist). FKs enforced;
  `UNIQUE(music_item_id, id_namespace)` on song; ownership cascades;
  **song delete RESTRICTed** so play history is never silently destroyed;
  indices for the FK/sort/lookup paths. `eraseDatabaseOnSchemaChange =
  false`. Never-edit-shipped-migrations rule documented in a comment block
  at the migrator and in `plans/data-and-import.md`.
- **`LibraryStore`** (`DJRoomba/Persistence/`) — `Sendable`, NOT
  `@MainActor`; async read/write over a GRDB `DatabaseQueue` off the main
  actor. Coarse intent-named API (upsert songs / replace snapshot / record
  play / favorites / recents) so future columns are localized changes.
  `AppDatabase` opens `Application Support/DJRoomba/library.sqlite`
  (`URL.applicationSupportDirectory`, subdir created if missing) + an
  in-memory init for tests. Records: one Codable record per file in
  `Persistence/Records/`.
- **Tests**: 20 tests / 5 suites, all pass. Cover: fresh DB applies all
  migrations; migrator idempotent on re-run; song upsert dedupes on
  `(music_item_id, id_namespace)` and preserves the stable id (FKs intact);
  snapshot replace is transactional, ordered, atomic-on-failure, and does
  NOT touch app_playlist/song_stat/play_event; favorites + recents
  round-trip (idempotent, source preserved, capped, no dup on replay);
  `recordPlay` maintains song_stat (count + last_played_at, only-advances,
  FK-rejected for a missing song with rollback). `swift test` →
  `Test run with 20 tests in 5 suites passed`.
- `swiftui-pro` consulted **before** (drove: Sendable value type not
  `@MainActor`, async/await only, modern Foundation `applicationSupportDirectory`,
  `Date.now`, one-type-per-file) **and after** (clean — no defects; noted
  the per-song upsert fetch is acceptable for v1 volumes, Phase 5 perf
  item). Carried-forward Phase 1 unknown (id-only re-resolve, esp. catalog)
  is untouched here — it's a Phase 3 PlaybackResolver concern.
- Docs updated: `plans/data-and-import.md` (sketch → as-built schema +
  FK-policy + migration-extensibility rules + as-built concurrency),
  `PROGRESS.md` (this), `PLAN.md` index still accurate. **Not committed**
  (CLAUDE.md: commit only when asked).

## 2026-05-15 — Build system migrated to the mdv environment

Replaced XcodeGen/`xcodebuild` with the **tqbf/mdv build environment**
(SwiftPM + `build.sh` + `Makefile`; no Xcode IDE, no `xcodebuild`, no
XcodeGen). Xcode is now only a toolchain provider, reached only by
`make dist`. Full rationale + targets + signing in
[plans/build-system.md](plans/build-system.md).

- Added `Package.swift` (executableTarget over `DJRoomba/`, macOS 14, Swift
  6 language mode), `build.sh`, `Makefile`. Deleted `project.yml` and
  `DJRoomba.xcodeproj/`. De-templated `Info.plist` to literal values
  (`$(…)` were Xcode-only substitutions; literal `$(…)` as
  `CFBundleIdentifier` would break MusicKit's App ID match).
- Verified: `swift build` compiles the whole Swift 6 strict-concurrency
  tree clean; `make` produces `build/DJRoomba.app` signed with the
  Phase-1 identity `Apple Development: Thomas Ptacek (7F2QE7P59D)`,
  bundle id `org.sockpuppet.djroomba`, designated requirement satisfied;
  `make check` / `clean` / `check-version` guard all work.
- One deliberate deviation from mdv: mdv adhoc-signs; DJ Roomba signs dev
  builds with the Apple Development cert (adhoc → empty MusicKit library,
  Phase 1 fact). `make dist` = Developer ID + hardened runtime + notarize
  + staple (the standard mdv pipeline).
- The "notarized Developer ID build may need an embedded MusicKit
  provisioning profile for catalog APIs" question is **not solved** — it
  is pre-wired as the optional `PROVISION_PROFILE` hook and remains the
  Phase 2/3 risk-register item.
- NOT verified by this change: runtime MusicKit behaviour (unchanged from
  Phase 1) and `make dist` end-to-end (needs a `vX.Y.Z` tag + stored
  `djroomba-notary` keychain profile — neither done yet).
- Not committed (CLAUDE.md / process note: commit only when asked).

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
- **Local store:** SQLite via **GRDB** (SPM dep in `Package.swift`).
- **Data ownership:** app owns playlists, play counts, favorites, recents,
  metadata in SQLite. One-way import from Apple. **No write-back to Apple.**
- **Playback:** native `ApplicationMusicPlayer`, in-process; stored
  `MusicItemID`s re-resolved at play time. Requires active subscription.
- **Tooling/identity:** mdv-cloned build env (SwiftPM + `build.sh` +
  `Makefile`; no Xcode IDE/xcodebuild/XcodeGen — see
  [plans/build-system.md](plans/build-system.md)); macOS 14 min (Swift
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

## Open user actions (remaining)

1. ✅ ~~Apple Music + Sync Library on this Mac~~ — done 2026-05-15.
2. ✅ ~~Apple ID / dev cert~~ — `Apple Development: Thomas Ptacek
   (7F2QE7P59D)` present and used by `build.sh`; no Xcode-Accounts /
   automatic-provisioning step anymore (we sign directly).
3. **For `make dist` only:** `make notary-setup` once (interactive;
   stores the `djroomba-notary` keychain profile).
4. **Open Phase 2/3 question:** whether a notarized Developer ID build
   needs the MusicKit App Service / an embedded provisioning profile for
   *catalog* APIs. Pre-wired as `PROVISION_PROFILE`; validate when
   PlaybackResolver first hits catalog ids.

## Process notes

- Committed to `main`: `ff3294f` (M1), `4f0a7f9` (M2 + local-first pivot
  planning docs), `112e1b3` (Phase 1). The build-system migration is
  **uncommitted** (working tree has the SwiftPM/Makefile changes).
- Build (agent / CI, no signing): `make check` (== `swift build`).
  Full signed dev build: `make`. See
  [plans/build-system.md](plans/build-system.md) for all targets.
- Will not commit/push without being asked; **never merge to `main`**
  (CLAUDE.md).
