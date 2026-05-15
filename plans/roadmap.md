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

## Phase 1 — ACCESS VALIDATION (de-risk first) ⟵ gate

**Goal:** prove, on this Mac, with a correctly-signed build, the full chain:
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
1. Flip `project.yml` back to automatic signing, team `KK7E9G89GW`; confirm a
   signed build succeeds (real cert, not ad-hoc).
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
- Add **GRDB** via SPM in `project.yml`; regenerate; build clean.
- DB at `Application Support/DJRoomba/library.sqlite`; `DatabaseMigrator`
  with the schema in `plans/data-and-import.md` (songs, apple_playlist(+track),
  app_playlist(+track), play_event, song_stat, favorite_playlist,
  recent_playlist). Store `music_item_id` + `id_namespace`.
- `LibraryStore` over a GRDB `DatabaseQueue`; async read/write APIs;
  Sendable-safe; off the main actor.
- **Unit tests** for the store + migrations (closes the standing test gap;
  add a test target via XcodeGen).

**Exit criteria:** build + tests green; migrations apply on a fresh DB; no UI
or import wired yet (purely additive).

---

## Phase 3 — IMPORT PIPELINE & UI ON SQLITE

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

## Phase 4 — APP OWNERSHIP: PLAYLISTS + PLAY COUNTS

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

**Exit criteria:** can build and manage an app playlist end to end and play
it; play counts increment and persist; imported data untouched by app edits.

---

## Phase 5 — POLISH, EXTENSION READINESS, HARDENING

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

**Exit criteria:** spec testing checklist exercised; review passes clean;
docs (PLAN/PROGRESS/plans) current.

---

## Cross-cutting

- CLI builds verify with `CODE_SIGNING_ALLOWED=NO`; real runtime verification
  requires the Phase 1 signed build. State runtime status honestly in
  PROGRESS.md — never claim verified playback that wasn't exercised.
- Consult `swiftui-pro` before/after code, `macos-design` for UI,
  `typography-designer` for type (CLAUDE.md). Keep PLAN/plans/PROGRESS current.
- May push PRs; **never merge to `main`**.
