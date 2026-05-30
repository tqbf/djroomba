# Up Next queue

An ephemeral, **in-memory** "play these tracks next" queue that takes
precedence over normal playlist advance, can be edited from a sidebar
landing surface peer to "All Recently Played Tracks", is exposed to the
GPT assistant via four `up_next_*` tools, and — when an opt-in toggle is
on — asks the assistant for eleven more tracks in a fresh conversation
the moment the queue depth drops to one. The intent is a continuous
stream of music populated eleven songs at a time (refilling while one
track is still playing, so the assistant's `gpt-5.4`-flex turn lands
under the cover of audible playback) that the user nudges in different
directions by talking to DJ Roomba.

## Product decisions (locked)

| Decision | Choice | Rationale |
|---|---|---|
| Storage | **In-memory** on `MusicController`; lost on quit. | Matches the "ephemeral virtual playlist" framing the user wants. Avoids a v10 schema migration. Auto-fill (Phase 5) covers the "I just relaunched and the queue is empty" case for users who want it. |
| Playback dominance | Queue **always preempts** the natural playlist advance. End-of-song and Next both drain the queue head first; only when empty do we fall through to whatever the player would have done. | The "11 at a time, refill at 1 remaining" loop only works if queue items actually play. User-stated escape hatch is "clear the queue". |
| Click a non-head queue row | **Consumes everything above it**: clicking #5 plays #5 and removes #1–#5 in one shot. | User-chosen. Removes the only path where the queue's order would visibly contradict play order. |
| Auto-fill on empty | Opt-in via UserDefaults toggle, **default OFF for now**. | User-chosen for v1. Phase 5 ships the wiring; the toggle lives in OpenAI Settings so it's reachable. |
| Tool names | `up_next_count`, `up_next_get`, `up_next_add`, `up_next_remove`. | Matches `play_track` / `play_playlist` snake-case convention; `up_next_` namespace avoids colliding with `ApplicationMusicPlayer.Queue` connotations. |
| Position indexing | **1-based, inclusive** on both ends of `up_next_get(start, end)`. | Matches `TrackRow.position` everywhere else in the app; matches what the user wrote ("tracks #x-#y on the queue"). |
| Library id discipline | Queue entries key on `Song.LocalID`, **never** Apple `MusicItemID`. Apple ids stay at the playback-resolution boundary. | `[[canonicalize-not-apple-ids]]`. |

## Architecture

### One service: `UpNextService`

`DJRoomba/Music/UpNextService.swift` — `@MainActor @Observable final
class`, mirroring `RecentlyPlayedService`'s shape. Owns:

```swift
struct Entry: Identifiable, Hashable {
  let id: UUID                  // stable for ForEach / Set selection
  let song: Song                // denormalised snapshot taken at add-time
  let musicItemID: MusicItemID  // resolved once at add-time; never round-tripped via SQLite at play
}

private(set) var entries: [Entry] = []
var count: Int { entries.count }
var isEmpty: Bool { entries.isEmpty }
```

**Denormalised on purpose.** Each `Entry` carries the full `Song`
snapshot it needs to render — title, artist, album, artwork ref — so
the queue table renders without a SQLite round-trip per row and is
unaffected by mid-queue library mutation (e.g. someone deletes a song
out from under us). The size is bounded by user behaviour, not library
size; eleven-at-a-time fill keeps `entries.count` small in practice
(steady-state floor 1, ceiling 12).

Service methods (all `@MainActor`, all return synchronously — this is
pure in-memory state with no I/O):

- `append(_ songs: [Song])` — push to tail.
- `insert(_ songs: [Song], at position: Int)` — 1-based insert; clamped to `[1, count + 1]`.
- `remove(at positions: [Int])` — 1-based; dedup + sort descending so multi-remove is index-stable.
- `clear()`
- `popHead() -> Entry?` — for the playback-dominance hook.
- `consumeThrough(position: Int) -> Entry?` — removes `[1...position]` and returns the entry at `position` (the click-to-play path).
- `range(_ start: Int, _ end: Int) -> [Entry]` — 1-based inclusive; clamped to non-empty.

A monotonic `revisionToken: Int` bumps on every mutation. Views observe
`entries` directly (`@Observable` makes the array reads tracked); the
playback-dominance hook reads `revisionToken` to debounce auto-fill
firing.

### Wiring into `MusicController`

- `let upNext: UpNextService` — constructed in `MusicController.init`, exposed for views and tool runners.
- `addToUpNext(_ songs: [Song], insertAt: Int? = nil)` — controller-level method so the track-table context menu and the GPT tool funnel through the same path. Logs to unified-log subsystem (`category = openai` for tool calls, `category = main` for user-driven). Triggers any required UI refresh (none today; observation does the work).
- `removeFromUpNext(positions: [Int])` / `clearUpNext()` — same shape.
- `playFromUpNext(position: Int) async` — calls `upNext.consumeThrough(position:)` then dispatches the resolved entry through the single-song play path described below.

### Playback dominance hook

The interception point is `MusicController.detectAndRecordAdvance()`
(MusicController.swift:1617), which already fires on every 0.5 s
`playback.onSnapshotRefresh` tick after `queueIndex` is global-corrected
across F1a chunks. Today it records play stats. We extend it (and the
explicit `skipNext()` path at line 871) with one branch:

```text
on advance-detected OR user-pressed-Next:
  if upNext.isEmpty:
    fall through to existing behaviour (playlist advance / nothing)
  else:
    let entry = upNext.popHead()!
    startResolvedQueue(with: [oneEntryAsResolvedRow(entry)],
                       label: "Up Next",
                       startAt: 0)
    record played-from-queue stat (existing pipeline)
    if upNext.count <= refillThreshold (=1) and autoFillOn:
      GPTService.autoFillUpNext()  # single-flight-guarded
```

The single-song play uses the existing `startResolvedQueue` path
([plans/catalog-playlists.md] F1a), which already accepts an arbitrary
list of resolved `(Song, MusicItemID, namespace)` rows and handles the
mixed-namespace sub-queue swap. A one-song queue is the trivial case;
no new playback infrastructure is needed.

**What this gives up.** Replacing the player queue with a single song
loses the previously-selected playlist's "next track" — once the queue
drains, the player has nothing to fall back to and stops. The user
restarts the playlist by clicking it. This is documented as a known v1
limitation; preserving the prior playlist context across queue-takeover
is out of scope.

### Sidebar landing

New sentinel `MusicController.upNextLandingID = "__djroomba.upNextLanding__"`
and new view `UpNextLandingRow` rendered **inside** the existing
"Recently Played" section in `PlaylistSidebarList.swift`, immediately
below `RecentlyPlayedLandingRow`. Same chip / icon treatment as the
recently-played row; chip shows `upNext.count`. Drop target: receives
`SongDragItem` payloads and appends to the queue.

New computed `MusicController.isShowingUpNextLanding` mirrors the
`isShowingRecentlyPlayedLanding` predicate; `PlaylistDetailView`
branches into a new `UpNextView`.

### Detail surface — `UpNextView`

Uses the existing `TrackTableView` with a queue-specific context menu
and header:

- Header chip: "N tracks" + `Clear` button (destructive style, confirm-and-clear inline).
- Context menu actions:
  - **Play** (single-select) — `controller.playFromUpNext(position:)`, which consumes everything above and plays the picked item.
  - **Remove from Up Next** (multi-select) — `controller.removeFromUpNext(positions:)`.
  - **Move to Top** (single or multi, preserving relative order).
- Empty state: friendly placeholder + a hint to add via track context menu OR talk to DJ Roomba.
- Row tap behaviour: same as Play.

Drag-to-reorder uses the existing `SongDragItem` infrastructure; for v1
intra-table reorder is acceptable to defer if it turns out to require
new drop-target plumbing (note as a polish item).

### GPT tools

Four new tools registered alphabetically into
`GPTToolRegistration.tools(store:catalogIngest:controllerProvider:)`,
each wrapped in `LoggedToolRunner` like the existing 13:

| Tool | Args | Output |
|---|---|---|
| `up_next_add` | `{ trackIds: [Int], position?: Int }` | `{ added: Int, count: Int }` — count is post-mutation. Trackids resolved via batched `SELECT … WHERE id IN (…)`. |
| `up_next_count` | `{}` | `{ count: Int }`. |
| `up_next_get` | `{ start: Int, end: Int }` | `{ entries: [{ position, songId, title, artist, album }], total: Int, truncated: Bool }`. Capped at 200 entries returned per call. |
| `up_next_remove` | `{ positions: [Int] }` | `{ removed: Int, count: Int }`. Invalid positions rejected with a clean error, no partial application. |

All four MainActor-hop through `Task { @MainActor in … }` using the
`controllerProvider` closure, exactly like `play_track`. System prompt
gets a paragraph teaching the model the queue's semantics and naming
the tools — keep it tight; per-tool affordances live in each tool's
schema description.

### Auto-fill on queue low-water (Phase 5)

UserDefaults key `djroomba.upNext.autoFillEnabled` (default `false`),
toggle in OpenAI Settings ("Auto-fill Up Next when empty"; the UI
label predates the low-water refinement but the footer copy is
accurate).

`UpNextDrainDetector` pairs two named constants:

- `targetDepth = 11` — how many tracks the seed prompt asks for.
- `refillThreshold = 1` — the queue depth that triggers a refill.

When `upNext.count` transitions from strictly above `refillThreshold`
to at-or-below it (`oldCount > 1 && newCount <= 1`) AND the toggle is
on AND `gpt.isKeyConfigured` AND no auto-fill is already in flight,
`MusicController` dispatches `GPTService.autoFillUpNext()`:

1. `await gpt.newConversation()` — mints a fresh context (the user
   wanted "in a new conversation").
2. `await gpt.sendMessage(autoFillSeed)` where `autoFillSeed` is a
   short instruction grounding the model in the queue tools, telling
   it to use `recently_played` + `app_state` to pick eleven tracks,
   and to add them via `up_next_add`.
3. One-at-a-time guard: a `Task<Void, Never>?` handle on
   `GPTService`. If the queue refills before the task lands, the task
   still completes (the model may add eleven on top of the
   user-added ones; that's fine — `entries.count` stays small).

**Why low-water instead of empty.** The model loop runs against
`gpt-5.4` on `service_tier: "flex"`, which can sit ~10–30 s on a
typical refill turn. Triggering at empty leaves a dead-air gap
between the last queued track and the first newly-added one;
triggering at depth 1 gives the assistant a full song's worth of
playback to complete the round-trip, so the user always has something
queued.

No retry on failure beyond what the assistant naturally does inside
its tool loop; failures land in unified log under the existing
`category = openai`.

## Phased delivery

Five PR-sized phases. Each is verified per CLAUDE.md (swiftui-pro +
macos-design + typography passes where relevant, airbnb-swift-style on
all Swift, `make check` + `swift test` green, signed build for
playback / UI phases). I push PRs and never merge.

### Phase 1 — `UpNextService` + controller plumbing + playback hook

- New `DJRoomba/Music/UpNextService.swift` (pure unit-testable).
- `MusicController` exposes `upNext` + `addToUpNext` / `removeFromUpNext` / `clearUpNext` / `playFromUpNext`.
- `detectAndRecordAdvance` + `skipNext` branch on `upNext.isEmpty`.
- Unit tests for `UpNextService` (insert / remove / consumeThrough / clamp).
- No UI yet; verified by `swift test` + signed build smoke (queue ops via debug-menu seed, observe via `log show`).

### Phase 2 — Sidebar landing + `UpNextView`

- `upNextLandingID` sentinel, `UpNextLandingRow`, sidebar wiring.
- `isShowingUpNextLanding` + `PlaylistDetailView` branch + `UpNextView`.
- Header chip + Clear; row tap → play.
- Live-verified end-to-end via computer-use: seed queue (debug menu or Phase 3 context menu), open landing, see rows, click row, intervening rows consumed and song plays.

### Phase 3 — Track-list editing surface

- "Add to Up Next" submenu in `TrackContextMenu` peer to "Add to Playlist".
- `UpNextLandingRow` accepts `SongDragItem` drops (append).
- Context menu on queue rows: Play, Remove, Move to Top, Clear.

### Phase 4 — GPT tools

- Four `up_next_*` tools registered in `GPTToolRegistration.tools(...)`.
- System prompt paragraph added in `GPTService.swift`.
- Live-verified: "Add five Pinback tracks to up next" → tool calls land → queue populates → first plays automatically when current song ends.

### Phase 5 — Auto-fill toggle + low-water dispatch

- UserDefaults toggle + OpenAI Settings UI.
- `MusicController` watches the `oldCount > 1 → newCount <= 1`
  transition via `UpNextDrainDetector.didCrossLowWater`.
- `GPTService.autoFillUpNext()` mints a fresh conversation and seeds
  it with the "add 11 tracks" instruction.
- Live-verified: enable toggle, drain queue to depth 1, watch a new
  conversation appear in the sidebar that calls `up_next_add` with
  ~11 track ids while the depth-1 song is still playing.

## Open / deferred

- **Restoring prior playlist after queue drains.** v1 leaves the player
  stopped. Doable later by snapshotting `(playlist, index)` before the
  first queue takeover and restarting the playlist at `index + 1` once
  the queue empties (and the auto-fill task doesn't refill).
- **Persisting the queue.** If users complain about losing the queue
  on quit, promote to a SQLite-backed store (a single small table). The
  service API is already shaped to swap the backing store with no
  caller changes.
- **Drag-to-reorder.** v1 supports Move to Top + Remove. Intra-table
  drag reorder is a polish item if `SongDragItem`'s drop infrastructure
  doesn't carry it for free.
- **Queue indicator in the now-playing bar.** Not in v1. Sidebar chip
  is the only count surface.
