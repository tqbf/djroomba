# Playlist folders imported as playlists — phased fix

Music.app's hierarchical playlist scheme has **folders** (containers of
other playlists). The import treats them as playlists. This document is the
durable plan to root it out. Verification may **blitz** the real library
freely — full *Reimport Everything* (⇧⌘R) + *Analyze* (⌥⌘A) as many times
as needed (sanctioned by the user; on this library incremental import
already degrades to full re-import anyway — see Phase 0).

> Resume pointer: Phases 0–4 are **DONE** (Option A — iTunesLibrary,
> exclude-only; Phase 5 SKIPPED, optional/not requested). The only thing
> left is the user-gated signed *blitz* (⇧⌘R → ⌥⌘A + the `sqlite3`
> checks), consistent with every prior milestone's "signed gate pending
> (user)" pattern. The phase bodies below are kept as the durable record;
> "as built" notes inline.

## The problem (confirmed)

`ImportService.runImport` writes **every** `MusicLibraryRequest<Playlist>`
item as an `apple_playlist` (+ `apple_playlist_track`). MusicKit surfaces
library **folders** as ordinary `Playlist` values, so the folder "AAA ME"
was imported as a single huge "playlist" = the flattened union of its child
playlists. It then dominated the genre graph / associations card
("AAA ME 57"). Pre-existing Phase-3 gap; the genre work only surfaced it.

## Phase 0 — Empirical probe ✅ DONE

Throwaway signed `PlaylistFolderProbe` over the real 270-playlist library
(reverted; finding kept in `plans/musickit-notes.md` → "Playlist folders").

**Result — definitive:** MusicKit exposes **no folder discriminator
whatsoever**. Across *all 270* playlists: `kind` nil, `curatorName` nil,
`lastModifiedDate` nil, `hasArtwork` true; the only `Mirror` children are
`id` + an opaque `propertyProvider`; `String(reflecting:)` only ever yields
`Playlist(id, name, isChart:false)`. The folder is byte-for-byte identical
to a real playlist.

Corollaries that shape the plan:

1. **MusicKit-native detection is impossible.** Detection must come from an
   external source or a content heuristic.
2. A folder's `playlist.with([.entries])` (and likely deep `.tracks`)
   **hangs the MainActor** — for any *exact* (pre-fetch) path, folders must
   be excluded *before* `fetchTracks`, never filtered after.
3. `lastModifiedDate` nil for all 270 ⇒ incremental import already always
   degrades to a full re-fetch on this library. Re-import is the only
   refresh that does anything here, so "blitz reimport" costs us nothing
   extra and is the natural verification loop.
4. **Strong lead for Phase 1:** the probe's library ids are signed 64-bit
   decimals (e.g. `2807883042140459807`, `-7422005473605192085`). That is
   exactly how a 64-bit Music *persistent ID* renders as
   `Int64(bitPattern:)`. So `MusicKit.Playlist.id.rawValue` is very likely
   the signed-decimal of `ITLibPlaylist.persistentID` — i.e. an **exact,
   free id mapping** between iTunesLibrary and MusicKit. Phase 1 confirms.

## Phase 1 — Detection spike + decision gate ✅ RESOLVED

**Decision: Option A — `iTunesLibrary.framework`, exclude-only.** Both
"Open decisions" resolved at this gate (user delegated to the
orchestrator; "don't intervene"): (1) **A over B** — A1 is solved
(the signed-64-bit id mapping is encoded and unit-tested), and A2 has no
correctness cliff: the `com.apple.security.assets.music.read-only`
entitlement covers the sandboxed read, and the source **graceful-degrades
to `[]`** when iTunesLibrary is unavailable (no exclusion = today's
behavior, zero regression) — so nothing ever *forces* the B fallback. B
remains the **recorded fallback only** (documented below, never coded —
A degrades safely). (2) **Exclude-only** — the correctness fix; Phase 5
(model the hierarchy) is **SKIPPED** (optional, not requested).

Decide *how* to identify a folder. Two candidates (Phase 0 eliminated
MusicKit-native). Time-boxed; output is the chosen mechanism + the data to
defend it.

### Option A — `iTunesLibrary.framework` (exact, hierarchy-aware)

`ITLibrary.library().allPlaylists` → `ITLibPlaylist.kind == .folder` gives
the exact folder set; `parentID` gives the whole tree for free. Spike must
resolve **two risks**, in order:

- **A1 — id mapping.** Confirm `Int64(bitPattern: itLibPlaylist.persistentID
  .uint64Value)` rendered as a decimal string == the MusicKit
  `Playlist.id.rawValue` we already fetch (the Phase-0 ids strongly
  suggest yes). Verify on ≥3 known playlists + the "AAA ME" folder. If it
  holds, folder detection is an O(1) `Set<String>` lookup built *before*
  import — dodging corollary 2's MainActor hang entirely.
- **A2 — sandbox/entitlement.** The app is sandboxed
  (`com.apple.security.app-sandbox`). Determine the minimum to let a
  signed sandboxed build instantiate `ITLibrary` and read playlists with
  no user prompt: the `com.apple.security.assets.music.read-only`
  entitlement and/or a `~/Music` access grant. Record exactly what's
  needed; this is the make-or-break risk (the id mapping is expected to be
  fine).

Tradeoffs: a new Apple framework + an entitlement, and a *second* read of
the library — but it stays a strict **classification input at the import
boundary** (SQLite is still the only source of truth; Apple is still
import-only). It's the only exact option and the only one that enables the
optional hierarchy (Phase 5).

### Option B — content heuristic (no dependency, fallback)

Classify post-fetch: a fetched "playlist" is a probable folder when its
track set is the **union/superset of other fetched playlists with
(near-)zero tracks unique to it** — computable purely from data the import
already pages (the genre work established folders *are* the union of their
children). The normal `.with([.tracks])` works (only `.entries` hung), so
this is feasible. Tradeoffs: heuristic (false-positive risk on a
hand-curated superset playlist); classify-after-fetch (pays the folder's
track fetch once); no hierarchy. Zero new dependency/entitlement; pure,
unit-testable decision logic.

### Option C — ScriptingBridge to Music.app (last resort)

Music.app has a distinct `folder playlist` class. Exact, but needs
Automation permission + Music running and fights the thin local-first
posture. Documented only as the escape hatch if A2 blocks and B's
false-positive rate proves unacceptable.

### Decision gate (end of Phase 1)

Recommendation going in: **pursue A**. A1 looks already solved by
inspection; if A2 yields to a known entitlement, A is exact, cheap, and
hierarchy-ready. **Fall back to B only if A2 is a hard blocker.** The user
makes the call here, informed by the spike, plus the second decision:

- **Exclude-only vs. model hierarchy.** Phase 2 (exclude folders) is the
  correctness fix and is enough on its own. If folders should later become
  collapsible sidebar groupings, only A's `parentID` provides the tree —
  so this choice feeds back into A-vs-B. Default: exclude-only now,
  hierarchy as an explicit later feature (Phase 5).

## Phase 2 — Prevent at import ✅ DONE

*As built:* `com.apple.security.assets.music.read-only` added to
`DJRoomba.entitlements`; pure `nonisolated PlaylistFolderClassifier`
(`String(Int64(bitPattern: persistentID))` id mapping + `isFolder(_:in:)`,
8 unit tests); `PlaylistFolderSource.libraryFolderIDs() async -> Set<String>`
(off-main `Task.detached`, graceful-degrades to `[]` if iTunesLibrary
unavailable — no exclusion, zero regression); `ImportService.runImport`
builds the folder-id set once and skips folder ids **before** `fetchTracks`
(dodges corollary 2's MainActor hang). No schema change.

Implement the chosen classifier and **never persist a folder**.

- A pure, `nonisolated`, unit-tested classifier:
  - **A:** `isFolder(musicItemID:) -> Bool` backed by a `Set<String>` of
    folder ids built once from `ITLibrary` at the start of `runImport`
    (before the playlist loop). Folders are skipped *before*
    `fetchTracks`/`writePlaylist` — no fetch, no MainActor hang.
  - **B:** `classifyFolders(_ fetched: [(id,trackKeys)]) -> Set<String>`
    run as a post-fetch pass; folders are then excluded from
    `writePlaylist` and actively pruned (Phase 3).
- Touch points: `ImportService.runImport` /
  `fetchAllLibraryPlaylists` (the skip), a new
  `PlaylistFolderClassifier` file, no schema change (folders simply never
  become rows). Because the genre graph, associations card, sidebar and
  recents all derive purely from `*_playlist_track`, excluding folders at
  import fixes every downstream surface with no other code change.

## Phase 3 — Converge the existing DB (blitz) ✅ DONE

*As built:* `LibraryStore.deleteApplePlaylists(ids:)` (chunked,
single-write, FK-cascade, one-way-isolation, empty-set no-op) wired into
`runImport` (`changedPlaylistIDs.formUnion(folderIDs.intersection(
existing.keys))` then `try? await store.deleteApplePlaylists(ids:
folderIDs)`) so already-stored folder snapshots actively converge.
`PlaylistFolderConvergeTests` pins the isolation invariant + "a converged
folder no longer contributes genre edges".

**Signed blitz EXECUTED & PASSED (2026-05-17, not user-gated).** On the
signed sandboxed build against the real library: `apple_playlist`
**270 → 265** (all 5 `iTunesLibrary` folders gone, incl. "AAA ME";
`… LIKE 'AAA%'` → empty), genre graph de-skewed (top weight 145→143;
`genre_edge` 1462), one-way isolation held (`song` 8229,
`play_history` 502 preserved, 0 orphan membership rows). A1 confirmed by
a throwaway `iTunesLibrary` probe (`kind == .folder`; the
`Int64(bitPattern:)` id mapping reproduces the stored MusicKit id
exactly). A2 is **not** a hard blocker — the embedded
`com.apple.security.assets.music.read-only` entitlement lets the
sandboxed build read `ITLibrary`; one cold-first-import miss degraded
gracefully with zero regression, as designed. See PROGRESS.md top entry.

The folder's id is still "live," so `pruneApplePlaylists(keeping:)` won't
drop the stale "AAA ME" row. The fix must **actively delete** any
`apple_playlist` now classified as a folder (FK cascade removes its
`apple_playlist_track`; `song`/app/stat/history untouched — the one-way
isolation invariant, test-asserted). Then **blitz to converge**:

1. *Reimport Everything* (⇧⌘R) on the signed build.
2. *Analyze* (⌥⌘A).
3. `sqlite3` the container DB:
   `SELECT id,name FROM apple_playlist WHERE name LIKE 'AAA%';` → empty;
   `genre_edge` no longer dominated by the folder; the associations card
   for a previously-folder-skewed genre looks sane.

Repeat the blitz as needed across iterations — sanctioned and, per Phase 0
corollary 3, the only refresh that does anything here anyway.

## Phase 4 — Tests, defense-in-depth, docs ✅ DONE

*As built:* the A-path classifier is unit-tested (8 tests, incl. the
signed-64-bit id mapping); `PlaylistFolderConvergeTests` proves a
converged folder yields no `apple_playlist` row, no `genre_edge`, **and
no `associatedPlaylists` card** (single-genre + edge); the
`maxPlaylistTracks` doc carries an explicit "defense-in-depth, NOT the
folder fix" note; the four docs below are updated. The Option B
"union/superset detection + curated-superset negative" bullet is **N/A**
— B was never implemented (it's the recorded fallback; A degrades
safely), so that bullet is satisfied by documentation, not code.

- Unit-test the pure classifier (A: id-set membership incl. the
  signed-64-bit mapping; B: union/superset detection + a curated-superset
  non-folder negative case).
- Store-level test: a folder id never yields an `apple_playlist` row and
  never enters `genre_edge` / `associatedPlaylists`.
- Keep the genre-analysis `maxPlaylistTracks` threshold as *documented
  defense-in-depth*, explicitly **not** the fix (a small folder still
  needs the classifier; a big real playlist must not be excluded).
- Update `plans/musickit-notes.md` (done — the Phase-0 finding),
  `plans/data-and-import.md` (import now folder-filters), `PROGRESS.md`,
  and this file's status.

## Phase 5 — Model the hierarchy ⏭️ SKIPPED (optional, not requested)

Explicitly out of scope: optional and not requested. The exclude-only fix
(Phases 2–3) is the complete correctness fix on its own. Option A keeps
this *available* later (`ITLibPlaylist.parentID` is the only source of the
tree) but no hierarchy code was written.

If Option A was chosen and the user wants it: use `ITLibPlaylist.parentID`
to show folders as collapsible groupings in the "Library Playlists"
sidebar, children nested, folders non-selectable (they have no real
membership of their own). Separate feature; out of scope unless explicitly
requested. Listed so the Phase-1 A-vs-B decision is made with it in view.

## Open decisions — RESOLVED at the Phase-1 gate

1. **A vs B → A (iTunesLibrary).** RESOLVED. A1 (the signed-64-bit id
   mapping) is encoded and unit-tested. A2 is not a blocker: the
   `com.apple.security.assets.music.read-only` entitlement covers the
   sandboxed `ITLibrary` read, and the source graceful-degrades to `[]`
   when iTunesLibrary is unavailable — no correctness cliff ever *forces*
   B. **B was not implemented**; it stays the recorded fallback (documented
   above, not coded — A degrades safely).
2. **Exclude-only vs hierarchy → exclude-only.** RESOLVED. Phases 2–3 ship
   the correctness fix; Phase 5 (hierarchy) is SKIPPED (optional, not
   requested), kept available later only because A retains `parentID`.

## Non-goals

Smart/Genius playlists are real playlists — keep them; only *folders* (and
any master "Library" container, if it ever appears) are excluded. Not
fixing the always-nil `lastModifiedDate` / incremental-import degradation
here (separate, already-documented; blitz reimport is the accepted loop).
