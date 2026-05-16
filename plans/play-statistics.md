# Play statistics — bounded history + skip/replay counters

> Goal (user, verbatim intent):
> 1. Remember the **last 50,000 songs played**, as a list of track primary keys.
> 2. A per-song **skip count** — pressing "next" **before halfway** through a track.
> 3. A per-song **replay count** — pressing "back" **after halfway** through a track.

Status: **IMPLEMENTED — code-complete (2026-05-16).** All 4 phases
built, each through its own multi-agent cleanup gate (R6). **Phase 1
shipped** (pure SQLite, unit-tested, no gate). **Phases 2–4
code-complete; signed runtime gate PENDING (user)** — only a real
signed MusicKit build can confirm structural `queueIndex` tracks the
live queue across auto-advance/skip/`startingAt:`, that pre-skip
capture beats the `currentEntry` mutation, and that song 1 isn't
double-counted live. `swift build` clean, **100 tests / 18 suites**
green, `swiftformat`/`swiftlint` 0. See `PROGRESS.md` for the per-phase
record and the exact signed-gate checklist. Decisions (R1–R9) all
resolved (see end); one intentional refinement: `playContext` is
`[String?]` (a `nil` = an unattributable position: a live Apple-playlist
track beyond the stored snapshot — it plays but records no stats),
because the spec's `[String]` assumed live/stored align 1:1.

## Architecture principle (load-bearing constraint — user directive)

> "Don't use Apple Music's identifiers for things we store in SQLite
> already. Fetch from Apple Music, **canonicalize in our database**; the
> application **reads through SQLite**, maybe pulling from Apple Music as
> a side effect."

This is a hard constraint on this feature (and the codebase generally):

- Our canonical key is **`song.id`** (the UUID PK). Every stat, list, and
  in-app lookup keys off it.
- Apple's identifiers (`music_item_id`, the resolved live `Song.id`, queue
  entry ids) are an **import/playback boundary detail** — never an app
  lookup key, never the join key for stats, never carried into app logic
  to be "translated back". Canonicalisation happens once, at the boundary,
  on the way into SQLite.
- App logic **reads through SQLite**. Touching Apple Music (resolve for
  audio, artwork) is a **side effect of serving a SQLite-driven read**,
  not the source of identity.
- Consequence for this feature: we do **not** map the live now-playing
  Apple id back to our `song.id`. Instead we carry our **canonical
  ordered play context** (a list of our `song.id`s, taken from the SQLite
  read that built the queue) forward, and attribute by the player's
  **structural queue position**, not by any Apple content id.

## TL;DR of the evaluation

Most of #1 already exists. `play_event` (LibraryMigrator v1) is already an
append-only `(song_id, played_at)` log, indexed `(song_id, played_at)`,
written transactionally by `LibraryStore.recordPlay`. "Last 50,000 played"
is essentially `SELECT song_id FROM play_event ORDER BY played_at DESC
LIMIT 50000`. Two real gaps and one hard problem:

- **Gap A — only *manually started* tracks are recorded.** `recordPlay`
  fires once, for the track the user explicitly started
  (`MusicController.recordPlayStart`, off `resolution.startSongID`). When
  the queue **auto-advances**, nothing is recorded. So today "songs
  played" really means "songs I clicked play on". Honoring "the last
  50,000 songs *played*" needs queue-advance recording (Phase 4).
- **Gap B — history wants a different shape than `play_event`.** The user
  wants the history as a **compact, capped vector of numeric ids** ("cheap
  to store 50,000 numeric identifiers"; the same song appears many times;
  fine to lose history past the cap, "arguably shorter than 50k"). The
  shipped `play_event` is the opposite: unbounded, one fat row per play
  (`id` + UUID `song_id` TEXT + `played_at` datetime), no consumer except
  a test-only count. So history is a **purpose-built bounded table keyed
  by a minted numeric song surrogate** (below), not `play_event` pruned.
  Stats stay safe regardless: `song_stat` is an **independent incremental
  rollup**, never `COUNT(history)`, so capping history does not corrupt
  lifetime counts (verify with a test).
- **THE HARD PROBLEM — attribution, solved the canonical way.**
  Skip/replay/auto-advance all need *"which stored `song.id` is playing
  right now"*. `PlaybackService` only exposes `snapshot.nowPlayingItemID
  = song.id.rawValue` of the **resolved MusicKit Song** — an Apple id the
  codebase already proved ≠ our stored id (the Track-id≠Song-id finding;
  why `recordPlayStart` uses `resolution.startSongID`). Under the
  architecture principle above we must **not** "translate that Apple id
  back". Instead: the queue is built from a SQLite read whose rows already
  carry our `song.id`s in order — **retain that canonical ordered list as
  the play context** and attribute by the player's structural queue
  position. Apple's live ids are never an app key. The enabler is Phase 2
  (canonical play context), not an id-translation map.

## Two identities — relational UUID + a canonical numeric song id

The request said "rowids (or whatever the primary key is for tracks)" and
later "a vector of numeric identifiers, cheap to store". Reconcile:

- **Relational identity stays `song.id`** (UUID `TEXT` PK): the FK target
  everywhere (`*_playlist_track`, `song_stat`), preserved across re-import
  (UPSERT never rewrites `id`). All existing in-app lookups/joins use it.
- **`song.local_id` is a first-class canonical numeric song id**
  (`INTEGER`, `UNIQUE NOT NULL`): a small stable integer assigned **once**
  when a song first enters our DB, **never reused**, stable across
  re-import. Decision Q1: it is **not** history-private — the user will
  **use it in other features** (compact references, future indices,
  exports). So it is documented as a durable identity with a contract,
  not an internal surrogate: *assigned at import, monotonic, never
  recycled, never an Apple id, never the rowid.* (`song.id` stays the
  relational key; `local_id` is the compact stable handle alongside it.)
  50k of these is a few hundred KB vs. 50k UUID rows.
- **Not the SQLite rowid.** `song`'s PK is TEXT so rowid is a separate
  implicit column a `VACUUM` can silently renumber — that would corrupt
  the durable history *and* anything else built on it. It's also a
  physical-storage detail, the opposite of "canonicalize in our DB".
  `local_id` is *our* minted canonical id (architecture principle).

## Data model change — migration `v3`

Per the frozen-migration rules (`LibraryMigrator`: never touch v1/v2; new
`vN`; defaulted/backfilled so existing DBs migrate non-destructively).
Four coordinated changes:

1. **`song.local_id`** — add `INTEGER`; backfill existing rows
   sequentially (deterministic order, e.g. by `imported_at, id`); then a
   `UNIQUE` index; new imports assign `MAX(local_id)+1` inside the upsert
   transaction (race-free, same idiom as `app_playlist.sort_index`).
2. **`play_history`** — the bounded sequence, the user's "vector":
   `seq INTEGER PRIMARY KEY AUTOINCREMENT`, `song_local_id INTEGER NOT
   NULL` (FK → `song(local_id)` `ON DELETE RESTRICT`, matching the
   existing "history is never silently destroyed" ethos). Append one row
   per recorded play; **prune** oldest beyond the cap in the same
   transaction (`DELETE WHERE seq <= :maxSeq - :cap` — keyset, cheap,
   bounded). Read newest-first: `SELECT song_local_id FROM play_history
   ORDER BY seq DESC LIMIT :n`.
3. **`song_stat`** — add `skip_count`, `replay_count` (`INTEGER NOT NULL
   DEFAULT 0`). Counts, not history, belong on the existing per-song
   rollup (maintained in the same write as the play, like `play_count`).
   A `skip_event` log would be speculative generality — clubbed.
4. **DROP `play_event`** (Decision Q2). Why it existed: v1 framed it as
   the durable audit log that `song_stat` is "a rollup of". Why it goes:
   verified it has **no consumer** — written by `recordPlay`, read only
   by `playEventCount`, which has **zero app callers** (only 3 test
   files, asserting "a play happened"). `song_stat` is maintained
   *independently* in the same transaction, never derived from
   `play_event`, so dropping it changes no behaviour and the new
   `play_history` is the only history of record. It is the last
   unbounded table — exactly what the user asked to eliminate. Its FK
   `ON DELETE RESTRICT` protection is preserved by `play_history`'s own
   FK on `song(local_id)`. **Consequence (Phase 1 task):** the 3 tests
   asserting via `playEventCount` (`PlayTrackingTests`,
   `SnapshotReplaceTests`, `AppPlaylistCRUDTests`) move to assert via
   `play_history` / `song_stat.play_count`; `PlayEvent.swift` +
   `recordPlay`'s insert + `playEventCount` are removed.

`playHistoryCap` is a single constant, **finalized at 50,000** (the
user's original number; trivially tunable — one line). Note Q3: dropping
`play_event` does **not** make the cap moot — `play_history` is itself
the capped "last N played" the user originally asked for; the cap is
that N. The track table already has the `Plays`/`Last Played`
sortable-column pattern, so
surfacing skip/replay later is trivial and **out of scope here**
(recording only).

## Phases (ordered low-risk first)

Phase 1 is independently shippable. Per **R1**, "played" includes
auto-advance, so **Phase 4 is required** for the feature to mean what was
asked — not à la carte. 3 & 4 depend on 2.

| Ph | What | Unlocks | Risk | Signed gate |
|----|------|---------|------|-------------|
| 1 | `v3`: `local_id` + `play_history` (capped) + `song_stat` counters + store methods | bounded numeric history; counters exist | low | no (pure SQLite, unit-tested) |
| 2 | Canonical play context (our `song.id`s, structural position) | correct "current stored song" w/o Apple-id translation | med | yes (MusicKit queue position) |
| 3 | Skip/replay counting on transport | asks #2 & #3 | low–med | yes (needs real elapsed/transport) |
| 4 | Record auto-advance plays (**required, R1**) | ask #1 means *played*, not *started* | med | yes (transition detection) |

### Phase 1 — Schema + numeric surrogate + capped history + counters
(no playback code)
- `LibraryMigrator` `v3` (the **four** coordinated changes above,
  including `DROP play_event`); `Song` gains `localID`, `SongStat` gains
  `skipCount`/`replayCount` (Codable columns); new `PlayHistoryEntry`
  record; **delete `PlayEvent.swift`**.
- `LibraryStore`:
  - `upsertSongs` assigns `local_id = MAX(local_id)+1` for genuinely new
    keys inside the existing upsert transaction; existing rows keep
    theirs (mirrors the stable-`id` non-destructive re-import guarantee).
  - `recordPlay` (rewritten): one transaction — bump `song_stat`
    (`play_count`/`last_played_at`, upsert-or-insert as today), **append**
    `play_history(song_local_id)`, **prune** beyond `playHistoryCap`. No
    `play_event` insert (table dropped). Remove `playEventCount`.
  - **Migrate the 3 tests off `playEventCount`** (`PlayTrackingTests`,
    `SnapshotReplaceTests`, `AppPlaylistCRUDTests`) to assert via
    `play_history` / `song_stat.play_count` — part of this phase, not a
    follow-up (Phase 1 isn't green until they are).
  - `recordSkip(songID:)` / `recordReplay(songID:)` — increment the one
    `song_stat` counter (upsert-or-insert; new row at count 1,
    `play_count 0`). **Neither touches `play_history`** (R4: a replay is
    not a new history entry).
  - `recentlyPlayedSongLocalIDs(limit: Int = playHistoryCap) -> [Int]`
    — the numeric vector, newest first. (A `…SongIDs -> [String]`
    convenience can join to UUID `song.id` for callers that need it.)
- **Pays its freight (falsifiable):** a test recording `cap + 5` plays
  leaves exactly `cap` `play_history` rows, newest-first order intact,
  **and** `song_stat.play_count` still equals true lifetime count (cap ≠
  stat corruption); `recordSkip`/`recordReplay` move only their own
  column and add **zero** `play_history` rows; `local_id` is stable
  across a simulated re-import (UPSERT) of the same songs.
- **Verify:** new `PlayStatisticsTests` (v3 idempotent &
  non-destructive on a v2 DB incl. `local_id` backfill uniqueness; cap
  exact; counters isolated; replay adds no history row; one-way
  isolation — nothing here touches `app_playlist*`/favorites/recents).
  `swift test` green; migration tests run without the app
  (LibraryMigrator rule 5). **Then run all Swift code-quality skills
  (see Process gates).**
- **Depends on:** none. Independently shippable; no playback behavior
  change. This is the durable spine; 2–4 are the wiring.

### Phase 2 — Canonical play context (THE enabler)
Honors the architecture principle: carry **our** ids forward from the
SQLite read; never translate Apple's live ids back.

- The queue is built from `detail.tracks` (a SQLite read) → resolved
  subsequence. At that point we already hold the **ordered list of our
  `song.id`s** for exactly the entries placed in the player queue
  (`resolution` is produced from those rows; `reassemble` already knows
  the resolved-row order). Capture that as
  `playContext: [String]` (our `song.id`s, queue order) — *our* data,
  taken from *our* read. Add it to `PlaybackResolver.Resolution`
  alongside the existing `startSongID` (same idea, generalised; no Apple
  id introduced).
- `MusicController` retains `playContext` for the active queue next to
  `playlistContextID`; cleared/replaced when a new queue is set.
- `currentStoredSongID = playContext[currentIndex]`, where
  `currentIndex` is the **player's structural position** in the queue we
  built (the queue entry's index — a position in *our* ordered context,
  not an Apple content id). The 0.5 s monitor already observes
  `currentEntry`; it tracks the index (advance/retreat), seeded at the
  start row. No Apple identifier is ever used as a key.
- **Pays its freight (falsifiable):** for a played queue,
  `currentStoredSongID` returns the right `song.id` for every position
  with **zero** use of `nowPlayingItemID`/any Apple id as a lookup key
  (grep: no Apple-id→our-id translation on the stats path). Pure
  index↔context logic is `static` + unit-tested with no MusicKit (same
  pattern as `groupByNamespace`/`reassemble`).
- **Risk:** medium — the structural-position tracking must stay aligned
  with MusicKit's queue across auto-advance/skip/`startingAt:`. Same
  class of signing-gated runtime check as prior phases. **Verify under a
  signed run** that `currentStoredSongID` tracks across a natural
  auto-advance and a manual skip. (If MusicKit's queue position proves
  unreliable to read directly, the fallback is still principle-clean:
  count transitions off the monitor to advance `currentIndex` — never
  re-derive identity from Apple ids.)
- **Depends on:** none structurally, but 3 & 4 depend on **2**.

### Phase 3 — Skip/replay counting on transport (asks #2 & #3)
- In `MusicController.skipNext()` / `skipPrevious()`, **before**
  delegating to `playback` (the transport call mutates `currentEntry`):
  read `playback.snapshot`/live `player.playbackTime` for `elapsed`,
  `duration`, and `currentStoredSongID` (Phase 2).
  - `skipNext`: if `duration` known & `> 0` & `elapsed > 1 s` &
    `elapsed < duration/2` → `store.recordSkip(currentStoredSongID)`.
  - `skipPrevious`: if `duration` known & `> 0` & `elapsed > duration/2`
    → `store.recordReplay(currentStoredSongID)`. (We only *count* per
    the elapsed rule; whatever MusicKit then does to the queue —
    restart vs previous — is unchanged and irrelevant to the count.)
  - Counting is fire-and-forget off the optimistic path (mirror
    `recordRecentlyPlayed`'s shape); a store error sets `storeError`,
    never blocks transport.
- **Intent dead-zone (skips only): `elapsed ≤ 1 s` never counts a
  skip.** Rapidly skipping through a bunch of tracks isn't a "didn't
  like it" signal — there's no real intent in the first second. So a
  skip counts only in the window `1 s < elapsed < duration/2`. (Moot for
  replays: a replay requires `elapsed > duration/2`, so it can't also be
  ≤ 1 s unless the track is ≤ 2 s — an absurd edge, no special-casing.)
- The half rule is **strict** (`<` for skip, `>` for replay); exactly
  50% counts as neither. Unknown/zero duration → no count (library
  songs almost always have a duration; a missing one is not signal).
  Ultra-short tracks where `duration/2 ≤ 1 s` simply have an empty skip
  window → no skip ever counts (correct, falls out of the rule).
- **Pays its freight (falsifiable):** unit test the pure decision
  `skipKind(elapsed:duration:button:)` → {skip, replay, none} across
  every boundary: 1.0 s next = none (dead-zone, inclusive); 1.01 s next
  = skip; 49.9% next = skip; 50% = none; 50.1% back = replay; nil
  duration = none; 2 s track @ 0.5 s next = none. Counter increments
  exactly once per qualifying press, attributed to the song that *was*
  playing (captured pre-skip).
- **R4 — a replay press adds NO history row.** `skipPrevious` past
  halfway calls `recordReplay` (counter only). It must **not** append to
  `play_history`, and the Phase-4 transition detector must not re-append
  when the back-restart replays the current track (the user: "do not
  record a song twice in the history if we hit the back button to replay
  it"). This falls out naturally from index-based attribution: a replay
  keeps the same `currentIndex`, so there is no transition → no append.
  General repeats are still fine (the same song at a different
  play/position appears again — only the back-replay of the *current*
  track is suppressed).
- **Risk:** low–med (needs real elapsed under a signed run to confirm
  pre-skip capture beats the `currentEntry` mutation; the decision
  itself is pure & deterministic).
- **Depends on:** 2. (And 1 for the store methods.)
- **After this phase: run all Swift code-quality skills (Process gates).**

### Phase 4 — Record auto-advance plays (makes #1 mean *played*)
- The existing 0.5 s `PlaybackService` monitor already reads
  `currentEntry`. Detect a **transition** (the `currentIndex` in our
  canonical play context moved to a *different* position) and, for the
  song newly become current, `store.recordPlay(currentStoredSongID)` —
  the same call the manual start uses, so `song_stat` + `play_history`
  append + cap all flow through one path.
- Index-based detection (Phase 2) gives R4 for free: a back-button
  **replay** restarts the *same* `currentIndex` → no transition → no
  history append (only `recordReplay`'s counter). A genuine advance /
  forward-skip / new-queue start *is* a different index → append.
- Must not double-count the explicitly-started first track (it's
  recorded by the existing `recordPlayStart`); the transition detector
  seeds its "last seen" with the start index so song 1 isn't re-appended.
- Known accepted limitation (document, don't over-engineer): a burst of
  skips faster than the 0.5 s poll can skip *intermediate* songs in the
  history (they were arguably not "played" anyway). A finer transition
  signal than the poll is out of scope unless a need appears.
- **Pays its freight (falsifiable):** a queue advancing N distinct
  positions yields N `play_history` rows (first from the start path,
  rest from transitions), **no** extra row for a back-replay of the
  current track, no duplicate for song 1; "last cap" reflects actual
  listening, not just clicks.
- **Risk:** medium (transition-detection correctness, double-count
  avoidance, pause/interrupt/loop edges). Signed-gate it.
- **Depends on:** 2.

## Rejected alternative — a persisted Apple-id → `song.id` index

Considered (2026-05-16) and **rejected**: "just keep an index of the
Apple Music song id back to our row PK" so the now-playing id can be
looked up to our `song.id`. It splits into two ids, and neither wants a
new index:

- **Stored library id → our PK already exists.** `song` has
  `UNIQUE(music_item_id, id_namespace)` (indexed); `LibraryStore.song(
  musicItemID:namespace:)` is the lookup. This is the legitimate
  boundary canonicalisation (it's how import dedupes). Building another
  index for it is redundant.
- **Resolved live now-playing `Song.id` → our PK is the trap.** That is
  the id you'd actually need for attribution, and this codebase has
  **already proven it does not round-trip** to the stored
  `music_item_id` (the Track-id≠Song-id finding: why the batch
  `memberOf` resolver path was deleted, why `resolvePlaylist`
  re-resolves at *playlist* granularity, why `recordPlayStart` uses
  `resolution.startSongID`, and the [[djroomba-musickit-id-roundtrip]]
  memory). An index keyed on it is not a fix — it persists an **unstable
  Apple id as a key**, grows unbounded in Apple ids, and is exactly what
  the architecture principle above forbids. You cannot index your way
  out of a non-correspondence.

Why no index is needed at all: Phase 2 carries our `song.id`s forward
from the SQLite read that built the queue and attributes by structural
position. The only legitimate pairing is the **ephemeral, per-queue**
one we already hold for free at enqueue (our `song.id` ↔ the `Song` just
placed) — that is the canonical play context, cleared per queue, **not**
a stored Apple-id table. A plan that reintroduces an Apple-id→PK lookup
on a read/stats path is wrong here by construction; flag it.

## Decisions

### Resolved (user, 2026-05-16)

- **R1 — "played" includes auto-advance. Phase 4 is IN.** "Auto-advanced
  tracks count as played, for sure." So #1 means *actually played*, not
  *manually started*; the bounded history must reflect listening. Phase 4
  is in scope, and it sharply raises the history append rate, so the cap
  (Phase 1) is **load-bearing**, not optional — Phases 1 & 4 are sized
  together.
- **R2 — Skip intent dead-zone: `elapsed ≤ 1 s` never counts a skip.**
  Rapid skip-through has no intent in the first second. A skip counts
  only in `1 s < elapsed < duration/2` (replays unaffected — see Phase
  3). This resolves the "minimum" part of the old duration question.
- **R3 — History = raw sequence of a numeric surrogate.** A compact
  vector of `song.local_id` ints, newest-first, **repeats allowed** (the
  same song appears many times). Cheap to store the cap's worth.
- **R4 — A replay never adds a history row.** Back-button past halfway
  bumps `replay_count` only; it does not append to `play_history` and
  the transition detector must not re-append the restarted track ("do
  not record a song twice if we hit back to replay it"). Naturally
  handled by index-based attribution.
- **R5 — History is bounded; losing old history is fine.** Cap deletes
  oldest beyond `playHistoryCap`; lifetime `song_stat.play_count` is an
  independent rollup so it stays correct.
- **R6 — All Swift code-quality skills run after *each* phase** (not
  just at the end). See Process gates.
- **R7 (Q1) — Mint `song.local_id` as a first-class canonical numeric
  song id.** Not just a history surrogate: the user will use it in other
  features, so it's a documented durable identity (assigned at import,
  monotonic, never recycled, stable across re-import, never the rowid /
  an Apple id). See "Two identities".
- **R8 (Q2) — DROP `play_event` in v3.** Verified consumer-less (read
  only by `playEventCount`, which has zero app callers). `song_stat` is
  maintained independently, so removal changes no behaviour and kills
  the last unbounded table. The 3 tests asserting via `playEventCount`
  migrate to `play_history`/`song_stat` as part of Phase 1.
- **R9 (Q3) — `playHistoryCap` = 50,000**, finalized (the user's
  original number; single tunable constant). Dropping `play_event` does
  not moot this — `play_history` *is* the capped "last N" of the
  original ask; N = 50,000.

### Assumed (stated defaults — flag now if any is wrong)

Vector stored as the narrow `play_history` table (not a packed BLOB —
atomic, queryable, 50k ints already cheap); half-boundary strict (`<`
skip / `>` replay, exactly 50% = neither); unknown/zero duration → no
count; record-only, no UI this feature.

## Non-goals / deferred

- No skip/replay **event log** (only counts) — add later iff history is
  needed (avoid speculative generality).
- No UI surfacing in this feature (trivial follow-on via the existing
  `Plays`/`Last Played` column pattern).
- No change to how playback/queueing works; counters are observers.
- No new global mutable state beyond the per-playback **canonical play
  context** (essential domain state; our `song.id`s; cleared per queue).
- **No Apple identifier as an app/stat key, anywhere on this path** —
  enforced by the architecture principle above; a review check, not a
  preference.

## Process gates (repo conventions)

- **All Swift code-quality skills run after EACH phase (R6)** — not only
  at the end: `swiftui-pro` (modern API/perf/`body` hygiene),
  `airbnb-swift-style` (naming/format/structure), and `simplify`
  (reuse/quality/efficiency on the changed code), plus
  `typography-designer`/`macos-design` for any phase that touches UI
  (none planned here — recording-only). A phase isn't "done" until its
  gate (build + tests + lint) **and** these skills are clean. Each
  phase's **Verify** says so.
- `swiftui-pro` additionally consulted **before** the Phase 2/3/4 design
  (CLAUDE.md, before *and* after deciding on code): the play-context
  holder is `@Observable` state and the transition detector hangs off
  the existing monitor — keep sort/derive out of `body`, no now-playing
  tick coupling regressions.
- Pure cores (`skipKind`, the play-context index↔id mapping, the cap
  SQL) are `static`/unit-tested with no MusicKit/signing (matches
  `importDecision`/`groupByNamespace` precedent).
- Phases 2–4 need a **signed runtime gate** (MusicKit Queue/elapsed
  behavior), like the resolver round-trip and import perf before them.
- On implementation: update `PLAN.md` index status, `PROGRESS.md` top
  entry, and `PROBLEMS.md` if a signed gate finds a defect.
