# End-to-end roadmap (5 phases)

The authoritative forward plan after the local-first pivot. Read this with
`PLAN.md` (decisions) and `PROGRESS.md` (status). Phases are sequential;
**Phase 1 is a hard validation gate** — Phases 2–5 must not start in earnest
until it passes or its risk is explicitly accepted in writing in PROGRESS.md.

Guiding principle: **prove we can actually read tracks and play audio with a
properly-signed native build before investing in the data architecture.** The
empty-library incident (auth OK, library empty, no error) is exactly the class
of failure this ordering exists to catch early.

The full live risk register is `plans/risks-and-challenges.md` — consult it
per phase; Phase 1 exists to retire the 🔴 access/identity/round-trip risks.

---

## Phase 1 — ACCESS VALIDATION (de-risk first) ✅ PASSED 2026-05-15

**Result:** Apple Development-signed build read the real library (many
playlists + artwork), loaded tracks, and **played audio in-app** (verified
live). M2 recents also verified. Earlier "empty library" was ad-hoc build +
unsynced library — both fixed. 🔴 access/signing/library risks retired. The
explicit *id-only re-resolve* round trip (esp. catalog namespace) is carried
into Phase 2 as the remaining lower risk. Distribution is NOT covered by this
gate — see Phase 5. Details in PROGRESS.md.

**Goal (original):** prove, on this Mac, with a correctly-signed build, the full chain:
authorize → real library playlists returned → tracks fetched → a track plays
in-app via `ApplicationMusicPlayer` → a stored `MusicItemID` can be
re-resolved to a playable item.

**Why first:** every later phase assumes track access works. The local-first
SQLite design specifically depends on the *store-id-then-re-resolve* round
trip. If any link breaks (entitlement, id-namespace mismatch, subscription),
we must know now, not after building Phases 2–5.

**Prerequisites (user actions — cannot be done for them):**
- Apple ID added in Xcode → Settings → Accounts.
- MusicKit App Service enabled for App ID `org.sockpuppet.djroomba`.
- This Mac signed into Apple Music with Sync Library on (so the account's
  library is actually present locally for native MusicKit).

**Work:**
1. ✅ Done — `make` signs with `Apple Development: Thomas Ptacek
   (7F2QE7P59D)` (real cert, not ad-hoc) via `build.sh`. No
   `project.yml`/automatic-provisioning step anymore.
2. Using the existing M1/M2 app (no new architecture), verify live:
   - `MusicAuthorization` → authorized.
   - `MusicSubscription` reports catalog playback allowed.
   - `MusicLibraryRequest<Playlist>` returns the real playlists (non-empty).
   - Select a playlist → tracks load.
   - Press Play → **audio actually plays from the app process**.
   - Double-click a track → plays from that track.
3. Prove the **id round-trip**: take a track's `MusicItemID` (+ namespace),
   discard the live object, re-fetch by id (`MusicLibraryRequest` /
   `MusicCatalogResourceRequest`), build a queue from the re-fetched item,
   play it. This validates the core local-first assumption. A tiny temporary
   debug affordance is acceptable here and removed after.

**Exit criteria (all must hold):** signed build runs; real playlists listed;
a track plays in-app; id round-trip plays. Record outcomes + any caveats in
PROGRESS.md. If a link fails, stop and resolve before Phase 2.

**Risks:** missing MusicKit entitlement; library/catalog id namespaces not
interchangeable; subscription/region gating; macOS-specific MusicKit quirks.
See `plans/musickit-notes.md`, `plans/architecture.md`.

---

## Phase 2 — LOCAL STORE FOUNDATION

**Goal:** a working, tested SQLite layer with no behavior change yet.

**Work:**
- Add **GRDB** via SPM in `Package.swift`; `make check` clean.
- DB at `Application Support/DJRoomba/library.sqlite`; `DatabaseMigrator`
  with the schema in `plans/data-and-import.md` (songs, apple_playlist(+track),
  app_playlist(+track), play_event, song_stat, favorite_playlist,
  recent_playlist). Store `music_item_id` + `id_namespace`.
- `LibraryStore` over a GRDB `DatabaseQueue`; async read/write APIs;
  Sendable-safe; off the main actor.
- **Unit tests** for the store + migrations (closes the standing test gap;
  add a `.testTarget` in `Package.swift`, run with `swift test`).

**Exit criteria:** build + tests green; migrations apply on a fresh DB; no UI
or import wired yet (purely additive).

---

## Phase 3 — IMPORT PIPELINE & UI ON SQLITE ✅ code-complete 2026-05-15 (signed-run pending)

**Result:** `ImportService` (one-way MusicKit→SQLite, paged, namespace-aware),
sidebar/detail re-pointed at `LibraryStore`, models de-MusicKit'd, artwork
from cached URL (pixel-equivalent), UserDefaults favorites/recents one-shot
migrated, `PlaybackResolver` (library+catalog re-fetch, tolerant) wired to
the unchanged M1 `PlaybackService` with `recordPlay` on start. `make check`
+ `swift test` (31/8) green; nothing committed. The 🔴 id round-trip is
**code-complete but runtime-unverified** — only the orchestrator's signed
run can confirm catalog/library re-resolution + audio. Details in
PROGRESS.md + `plans/data-and-import.md`.

**Goal:** the app operates from SQLite; Apple is a one-way import source.

**Work:**
- `ImportService`: paged `MusicLibraryRequest` + lazy tracks → transactional
  upsert into SQLite (dedupe songs; replace each apple_playlist snapshot).
  One-way; never deletes app-owned data. Wire to Refresh (⌘R).
- Re-point sidebar/detail to read from `LibraryStore` (not live MusicKit).
- One-shot migrate UserDefaults favorites/recents → SQLite tables; stop using
  the old keys.
- `PlaybackResolver`: stored id (by namespace) → MusicKit item → queue;
  reuse M1 `PlaybackService`.

**Exit criteria (needs Phase 1 signed build):** import populates the DB from
the real library; sidebar/detail render from SQLite; play works through the
resolver; favorites/recents survive the migration. Verify on a signed run.

---

## Phase 4 — APP OWNERSHIP: PLAYLISTS + PLAY COUNTS ✅ code-complete 2026-05-15; signed gate ran (core PASSED) + UI corrective applied; signed re-gate pending

**Result:** App-playlist CRUD over `LibraryStore` (batch idioms, one-way
isolation, no schema change — Phase-2 tables sufficed), `AppPlaylistService`,
a native "My Playlists" sidebar section (always-present, inline `+`/⌘N
create, Finder-style inline rename, destructive `confirmationDialog`, context
menu, drag-reorder, song drag-in + "Add to Playlist ▸"), per-song 1:1
app-playlist re-resolution (`resolveAppPlaylist`: per-id `equalTo` through a
bounded `TaskGroup`, keyed by the stored id), the Phase-3 play-tracking bug
fixed (records on the player's confirmed `.playing`, for the resolver-
reported stored `song.id`), and play count + last played as sortable Table
columns.

**Signed-gate outcome:** the computer-use signed-build gate confirmed the
**core works** (CRUD + one-way isolation DB-verified; per-id app-playlist
playback plays real audio; play-tracking records on confirmed start; native
context menu + delete dialog) but caught **4 UI defects** (non-functional
inline rename; phantom empty rounded-gray Table rows; stale "My Playlists"
sidebar count; stale Plays/Last Played). All four were root-caused and fixed
as **view/reactivity-only** changes (the verified-good data layer, playback,
resolution and schema untouched) — see the "Phase 4 UI CORRECTIVE" PROGRESS.md
top entry. `make check` + `swift test` (**51/11**) green; signed `make` build
produced; nothing committed. The 4 UI fixes + the per-id `equalTo` re-fetch +
audio + play-count persistence are **runtime-unverified** — only the
orchestrator's signed re-gate confirms them. Details in PROGRESS.md +
`plans/architecture.md`.

**Goal:** the actual product value — user owns their library locally.

**Work:**
- App playlists: create / rename / delete / add / remove / reorder, all
  SQLite-only, never written to Apple.
- Sidebar: "My Playlists" section distinct from imported "Library Playlists"
  (+ existing Favorites / Recently Played).
- Play tracking: record `play_event` + maintain `song_stat`
  (play_count, last_played_at) when playback actually starts.
- Surface play count + last played in the track table (sortable column);
  optional sort/smart ordering.

**Exit criteria (needs the signed run):** can build and manage an app
playlist end to end and play it; play counts increment and persist; imported
data untouched by app edits.

---

## Phase 5 — POLISH, EXTENSION READINESS, HARDENING ✅ code-complete 2026-05-15; signed gate pending

**Result:** All scope delivered. Smarter cause-inferred empty/error states
(pure `LibrarySidebarState` cross-checking `MusicSubscription.hasCloudLibrary
Enabled`/auth — "library not synced" vs "subscription needed" vs "no
playlists" vs error, native `ContentUnavailableView`). Auto-start polish
(bounded re-issue of `play()` + immediate snapshot on the confirmed `.playing`
— no transport nudge; play-recording NOT regressed). The M3 extension
boundary realized as a real collapsible native `.inspector()` (collapsed by
default, toolbar toggle) that observes the read-only `MusicContext` and acts
only via `MusicCommand` — never touches the player. Edge hardening (rapid
switching cancels in-flight loads, disappeared playlist, unplayable track,
network-down — graceful + tested where deterministic). Import perf (honest
finding, Phase-5 corrected): a bounded-parallel `TaskGroup` was tried and
**measured ineffective on the signed build (~119 s, no improvement over the
prior serial ~88 s, slightly worse + unstable)** — the cost is MusicKit's
own per-playlist track resolution on macOS, CPU-bound and internally
serialized, **not** SQLite and **not** fixable by app-side parallelism — so
it was **reverted to the simple serial loop**, keeping only the "Importing N
of M" progress affordance. The SQLite write path is byte-for-byte unchanged
(one-way isolation NOT regressed). Honest accepted v1 cost: a full re-import
of a ~270-playlist / ~8200-track library is **~90–120 s**, one-time /
Refresh-only. (The earlier unmeasured "~88 s → ~20–35 s" estimate was wrong
and is struck everywhere.) Incremental import investigated and
**deliberately deferred** (the `lastModifiedDate` signal is
macOS-14-unreliable; faking it would ship stale snapshots — scope forbids).
Catalog search **deferred** (documented, not half-built). Final swiftui-pro/
macos-design/typography pass applied (no new type roles). Distribution
pipeline reviewed (internally consistent; entitlements distribution-correct);
the open MusicKit-App-Service question analyzed + exact remaining USER steps
documented — **nothing notarized by the agent**. `make check` + `swift test`
(**67/14**) green; signed `make` build produced; **nothing committed**. The
empty-state branches / auto-start / inspector are **runtime-unverified** —
the orchestrator's signed gate confirms them; the import wall-clock is now
re-measured by the orchestrator against the reverted serial loop (no speedup
is claimed — see the Phase-5 CORRECTIVE in PROGRESS.md).
Details in PROGRESS.md + `plans/architecture.md` +
`plans/risks-and-challenges.md`.

**Goal:** make it pleasant, durable, and extensible.

**Work:**
- Smarter empty/error states (e.g. distinguish "no playlists" from "library
  not synced to this Mac"; subscription-needed messaging).
- Extension surface: `MusicContext` boundary + collapsible inspector
  (deferred from the original M3); extensions observe, never touch the player.
- Edge/error coverage from the spec testing checklist (playlist disappeared,
  unplayable track, network down, huge library/playlist, rapid switching).
- Performance pass for large libraries (paging, `ValueObservation` for live
  sidebar if warranted).
- Broaden tests; final `swiftui-pro` / `macos-design` / `typography-designer`
  review pass.
- Optional: catalog search strictly as an import-to-library affordance.
- **Distribution**: Developer ID signing + Apple notarization so others can
  run it (end users need NO dev account, but DO need their own Apple Music
  subscription). Enable the MusicKit App Service on the App ID for the
  distribution build's entitlement. See risks-and-challenges.md → Distribution.

**Exit criteria:** spec testing checklist exercised; review passes clean;
docs (PLAN/PROGRESS/plans) current.

---

## Cross-cutting

- CLI builds verify with `make check` (`swift build`, no signing); real
  runtime verification requires a signed `make` build. State runtime status
  honestly in PROGRESS.md — never claim verified playback that wasn't
  exercised.
- Consult `swiftui-pro` before/after code, `macos-design` for UI,
  `typography-designer` for type (CLAUDE.md). Keep PLAN/plans/PROGRESS current.
- May push PRs; **never merge to `main`**.
