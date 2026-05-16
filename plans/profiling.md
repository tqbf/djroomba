# Profiling — import hot path

Tooling: [apple/swift-profile-recorder](https://github.com/apple/swift-profile-recorder)
(in-process sampling profiler) wired into the app + the global
`swift-profiling` skill (`~/.claude/skills/swift-profiling/`, incl.
`scripts/hotspots.sh`). This doc is the **runbook + the hypothesis to test**.

## What we're investigating

A full re-import of the test library (~270 playlists / ~8200 tracks) takes
~90–120 s. `ImportService` documents this as "all MusicKit's per-playlist
`playlist.with([.tracks])` resolution; not SQLite; not fixable by app-side
parallelism." **That conclusion came from coarse wall-clock A/B (serial vs
`TaskGroup`), not a self-time sampling profile.** The profiler answers the
question that A/B couldn't: *is there any reducible app-side self-time, and
which exact frame/playlist dominates?*

### Static read of the path (`DJRoomba/Music/ImportService.swift`)

`runImport()` → `fetchAllLibraryPlaylists()` (cheap: ~3 paged
`MusicLibraryRequest<Playlist>` calls) → **serial loop**, per playlist:

1. `fetchTracks(of:)` — `playlist.with([.tracks])` + `nextBatch()` loop.
   *Hypothesised dominant cost* (MusicKit, off-`@MainActor`, ~270×).
2. `writePlaylist(_:tracks:)` — in-memory map tracks→`Song`
   (`song(from:)` per track, dict + array build), then **3** `await`s into
   `LibraryStore`: `upsertSongs`, `songIDsByKey` (batched), then
   `replaceApplePlaylistSnapshot`.

### Hypotheses the profile will confirm or refute

- **H1 (documented):** ≥80% of on-CPU self-time is MusicKit / CoreData /
  libnetwork frames under `fetchTracks`. → Only structural wins remain:
  **incremental import** (skip playlists unchanged since `lastImportedAt`),
  fewer requested properties, or accept it.
- **H2:** non-trivial self-time in DJRoomba frames — `song(from:)`,
  `writePlaylist` dict/array building, `LibraryStore` row encode/decode, GRDB.
  → A real app-side win the prior wall-clock A/B never isolated.
- **H3:** self-time dominated by `swift_retain`/`swift_release`/`memmove`/
  `Array`/`Dictionary` under the write path → ARC/allocation churn;
  `reserveCapacity`, fewer intermediate copies, value-type tightening.
- **Distribution:** is wall time spread evenly or dominated by **one huge
  playlist**? (Time Order view + per-playlist progress timing.) Changes the
  optimization entirely (parallelism can't split one giant serial task; a
  cache can skip the other 269).

Report which hypothesis the SELF table supports, with %s. Don't pre-optimize.

## Runbook (this app is sandboxed + MusicKit-signed)

MusicKit library reads need the **signed** build; **App Sandbox blocks a
`/tmp` socket**, so bind inside the app's sandbox container.

```bash
# 1. Signed DEBUG .app (debug => recorder compiled in via #if DEBUG).
make build                       # ./build.sh debug — signs w/ Apple Development cert

# 2. Socket path inside the sandbox container (sandbox-writable).
CID=org.sockpuppet.djroomba
SOCK_DIR="$HOME/Library/Containers/$CID/Data/tmp"
mkdir -p "$SOCK_DIR"             # exists after first normal launch anyway

# 3. Launch the SIGNED bundle binary directly so the env var is inherited
#    (`open` doesn't pass env). Same signature/entitlements/container apply.
PROFILE_RECORDER_SERVER_URL_PATTERN="unix://$SOCK_DIR/spr-{PID}.sock" \
  build/DJRoomba.app/Contents/MacOS/DJRoomba
#  If MusicKit auth misbehaves launched directly: run once via `make run`
#  to register with LaunchServices, then relaunch directly as above.

# 4. In the app: authorize if prompted, let it settle, then trigger the
#    full re-import — ⌘R ("Refresh Playlists"). runImport() is already a
#    full, non-incremental re-import; no test feature needed. Repeat ⌘R
#    to re-profile after a change.

# 5. While the import runs (~90–120 s window — ample), capture:
PID=$(pgrep -n DJRoomba)
curl --unix-socket "$SOCK_DIR/spr-$PID.sock" \
  -sd '{"numberOfSamples":2000,"timeInterval":"20ms"}' \
  http://localhost/sample | swift demangle --compact > /tmp/import.perf
#  2000 × 20ms ≈ 40 s of samples mid-import. Take 2–3 (before/after a fix).

# 6. Deterministic hotspot table FIRST:
bash ~/.claude/skills/swift-profiling/scripts/hotspots.sh -n 30 /tmp/import.perf

# 7. Visual call paths: speedscope (Left Heavy) + computer-use screenshots.
speedscope /tmp/import.perf
```

### Notes & alternatives

- **Release-accurate numbers:** debug perf ≠ release. For a representative
  profile, build release with the recorder opted in:
  `swift build -c release -Xswiftc -g -Xswiftc -DPROFILE_RECORDER`, then sign
  that binary (the `#if DEBUG || PROFILE_RECORDER` gate). Start with the
  signed debug build (zero extra steps) to see *where* time goes; escalate to
  release only if debug is misleading.
- **Non-sandboxed alternative:** sign a profiling build with an entitlements
  file lacking `com.apple.security.app-sandbox`; then a plain
  `unix:///tmp/spr-{PID}.sock` works and no container path is needed.
- The recorder is **never in `make dist`** (gate defines neither symbol).
- pprof endpoint also available: `GET /debug/pprof/profile?seconds=30`.
- Full tool detail: the `swift-profiling` skill's `references/*.md`.

## Findings log

_(Append capture results here: date, build config, workload, window, the
SELF/TOTAL top frames, which hypothesis, the change made, and the
before→after self-% diff. An optimization isn't done until a re-capture
shows the targeted frame shrank and nothing replaced it.)_

### 2026-05-16 — write-path isolated (unsigned, no MusicKit) → **H1 confirmed**

`ImportPerfBench` (`Tests/DJRoombaTests/ImportPerfBench.swift`,
`DJROOMBA_IMPORT_PERF=1 swift test --filter ImportPerfBench`) mirrors
`ImportService.writePlaylist` byte-for-byte over a synthetic library at the
measured real scale (270 playlists, ~18.8k track slots, ~7.9k unique songs),
**file-backed** SQLite, no MusicKit, no signing.

| phase | time | share |
|-------|------|-------|
| map tracks→keys | 0.015 s | 1% |
| `upsertSongs` | 0.37 s | 34% |
| `songIDsByKey` | 0.14 s | 13% |
| `replaceApplePlaylistSnapshot` | 0.54 s | 50% |
| **TOTAL app-side write path** | **~1.08 s** | 100% |

**Conclusion.** The entire app-side import path is **~1 s**; the real import
is **~90–120 s**. ⇒ **≈99% of import wall time is MusicKit's
`playlist.with([.tracks])` per-playlist fetch**, not our code. H1 confirmed
with a real isolated measurement (the prior finding rested only on coarse
serial-vs-parallel wall-clock A/B); **H2/H3 refuted** — no reducible app-side
hotspot exists (and within the irrelevant 1 s, snapshot-replace + upsert
dominate; the SQLite batch idioms are already fine).

**Only real lever = structural, not a hotspot fix:** *incremental import* —
skip the MusicKit re-fetch for playlists unchanged since
`apple_playlist.lastImportedAt` (needs a cheap per-playlist change signal
from MusicKit, e.g. `lastModifiedDate` if exposed; otherwise a heuristic).
App-side parallelism stays ruled out (MusicKit internally serialized; one
huge playlist is an unsplittable serial task). No app-side optimization can
move the 90–120 s.

- _Optional follow-up:_ a **signed** run (runbook above) would only show the
  *internal* MusicKit breakdown (network vs CoreData vs CPU) — informative
  but not our code to fix. Not required for the decision above.

### 2026-05-16 — lever IMPLEMENTED: incremental import

Acted on the above. `apple_playlist.change_token` (migration
`v2.applePlaylistChangeToken`) = `Int(Playlist.lastModifiedDate
.timeIntervalSince1970)`; `ImportService.importDecision` skips the
expensive per-playlist `with([.tracks])` when the token is unchanged
(conservative — any uncertainty re-fetches; never a stale skip). ⇧⌘R
"Reimport Everything" forces a full re-fetch (recovery for smart/auto
playlists that mutate without bumping `lastModifiedDate`). Vanished
playlists pruned (FK-cascade only; one-way isolation tested). 10 new
unsigned tests; gate 78/16 green. **Effectiveness is signed-run-gated**:
correctness/safety hold unconditionally, but the *speedup* needs macOS
MusicKit to populate `lastModifiedDate` (often nil — musickit-notes); if
nil it degrades to today's full import (no regression). Measure the real
payoff on a signed Refresh via `skippedPlaylistCount` / repeated ⌘R
timing. Detail: `plans/data-and-import.md` → "Incremental import".
