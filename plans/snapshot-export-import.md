# Library snapshot export / import (`.djroomba`)

**Problem this solves (immediate).** On macOS 14 (the user's daily driver)
the album→track genre import (`v5`, `GenreImportService`) only tags a
fraction of the library (<1/3 of genres) — a MusicKit-on-Sonoma data gap.
**We are explicitly NOT fixing that import here.** Instead we let the user
*carry the good metadata over* from a machine where the import works: export
the whole local SQLite library on the good machine, then on the macOS-14
machine **merge that snapshot's metadata onto the existing rows by content
matching** — without blitzing the local library (playlists, app playlists,
play history, stats, favorites, recents are all left exactly as they are).

## Shape

Three user-facing operations, all in the **File** menu
(`CommandGroup(.importExport)` — the native macOS home for these):

1. **Export Library Snapshot…** → writes a `.djroomba` file.
2. **Import Library Snapshot…** → picks a `.djroomba`, makes a quiet backup,
   then **merges its metadata** onto matched local songs.
3. **Revert Last Snapshot Import** → swaps the pre-import backup database
   back in. Also surfaced as a dismissible chip in the toolbar `.status`
   slot right after an import completes ("Updated N songs — Revert").

## `.djroomba` file format (v1 — "compressed sqlite, for now")

```
bytes 0..7   magic  "DJRMBA01"  (ASCII, 8 bytes; also the format version)
bytes 8..    zlib (DEFLATE) stream of a clean SQLite database file
```

- The SQLite payload is produced by GRDB `vacuum(into:)` (`VACUUM INTO`) —
  a defragmented, transactionally-consistent single-file copy taken while
  the app's `DatabaseQueue` stays open (no fd swap, no app quiesce).
- Compression is `NSData.compressed(using: .zlib)` / `.decompressed` —
  zero new dependencies, "just a compressed sqlite" as asked. Whole-file
  in memory is fine at this scale (~8k songs ≈ a few MB; tens of MB
  worst case).
- The magic is checked on import; an unknown magic is a clean, surfaced
  error (never a crash, never a half-applied merge).
- `SnapshotCodec` (pure, `nonisolated`, unit-tested) owns encode/decode +
  the magic. It runs **off the main actor** (`nonisolated async`) so the
  compression CPU never janks the UI.

## Matching (the "do some matching work" core)

The two databases come from the **same Apple Music account on different
Macs**. Nothing app-minted is shared: `song.id` (per-machine UUID) and
`song.local_id` (per-machine sequence) differ; library `MusicItemID`s are
*not* reliably stable across machines (musickit-notes / the D1 finding —
they don't even round-trip within a machine across a re-fetch). So matching
is **content-based and tiered**, source (imported snapshot) → target
(current library), first hit wins, deterministic:

| Tier | Key | Why |
|----|----|----|
| 1 | **ISRC** (uppercased/trimmed, both non-empty) | Globally stable recording id — the gold key when present (`v4` `isrc`). |
| 2 | **`music_item_id`** (same namespace) | Free true-positive when the account's library ids *do* coincide; never trusted as the only key. |
| 3 | **normalized (title, artist, album)** | The realistic workhorse — case/diacritic/whitespace-folded. |
| 4 | **normalized (title, artist)** — only when album is absent on a side | Last resort; album-present rows must still agree on album (tier 3) so a different pressing's genre can't bleed across. |

`MetadataMatcher` is **pure, `nonisolated`, no DB, exhaustively
unit-tested** (the codebase's established decider pattern —
`ImportService.importDecision`, `LibrarySidebarState.resolve`,
`ImportActivity.text`). It takes `[Song]` source + `[Song]` target and
returns `[MetadataUpdate]` plus per-tier counts for the summary string.

**What a match copies (coalesced, source-wins-*only-when-present*).** It
**never blanks** a populated target field with an empty source one. Fields:
`genre_names` (the headline), `track_number`, `disc_number`,
`release_date`, `composer_name`, `isrc`, `has_lyrics`, `work_name`,
`movement_name`, and the display core `title`, `artist_name`,
`album_title`, `duration`, `is_explicit`. An update row is emitted **only
if at least one field actually changes** (so the "updated N" count is
honest and we touch the minimum rows). Identity/relations
(`id`, `local_id`, `music_item_id`, `id_namespace`, `imported_at`) are
**never** touched — that is what keeps every playlist/history FK intact.

## Store additions (`LibraryStore`, batch idioms, one-way isolated)

- `snapshot(to:)` — `try await dbQueue.vacuum(into: url.path)`. Clean
  consistent copy; used for both export and the pre-import backup.
- `restore(from:)` — open the backup as a read-only `DatabaseQueue`, then
  GRDB's `backup(to: liveDbQueue)` (the SQLite Online Backup API). This
  overwrites every page of the live DB **through the already-open
  connection** — semantically "swap the SQLite databases" exactly as the
  user described, but done via SQLite's own API instead of an unsafe `mv`
  under an open fd, so the whole `LibraryStore`/services object graph
  stays valid and only the in-memory view caches need a reload.
- `applyImportedMetadata(_:) -> Int` — one chunked
  `UPDATE song SET col = CASE id WHEN ? THEN ? … END, … WHERE id IN (…)`
  per ≤999-var chunk (the exact `applyAlbumGenres` / `reorderAppPlaylists`
  idiom — never a per-row loop). Touches **only `song`**; the one-way
  isolation invariant (apple/app playlists, history, stats, favorites,
  recents untouched) is asserted by a test mirroring the existing
  isolation tests. Returns rows changed.

## Backup / revert

- Backup dir: `Application Support/DJRoomba/Backups/` (created on demand).
  **One** most-recent pre-import backup: `pre-import.djroomba-backup`
  (a plain uncompressed sqlite — it never leaves the machine; speed >
  size). Overwritten each import. "Revert" = undo the *last* import; a
  history of backups is deliberately out of scope.
- Flow: pick file → `store.snapshot(to: backupURL)` (quiet) → decompress
  to a temp sqlite → open it as an `AppDatabase` (**runs the migrator**,
  so an older-schema `.djroomba` is upgraded to the current schema before
  we read columns — forward-compat for free) → read both song sets →
  `MetadataMatcher.plan` → `applyImportedMetadata` → reload all view
  caches + reanalyze the genre graph (genres changed) → publish the
  result + enable Revert.
- Revert: `store.restore(from: backupURL)` → same full reload. Clears the
  chip. Also a File-menu item, enabled whenever the backup file exists
  (survives a relaunch — cheap, discoverable), both calling one
  `controller.revertSnapshotImport()`.

## Concurrency / architecture fit

- `SnapshotService` — `@MainActor @Observable`, mirrors `ImportService`
  exactly: holds the `Sendable` off-main `LibraryStore`, `await`s it,
  publishes `isExporting`/`isImporting`/`lastError`/`lastResult`/
  `canRevert`. Heavy work (vacuum, compress, decompress, GRDB backup) is
  off the main actor (GRDB queue + `nonisolated async` codec). Only
  `Sendable` values cross actors.
- Pure logic (`MetadataMatcher`, `SnapshotCodec`, the result-summary
  string) is `nonisolated` and unit-tested with no MusicKit, no signing,
  no live DB — so this whole feature is **build- and test-verifiable
  without a signed run** (unlike the MusicKit-gated phases).
- Sandbox: the app is sandboxed and currently has **no** user-selected
  file entitlement, so `.fileImporter`/`.fileExporter` (Powerbox) would
  silently fail. Adding `com.apple.security.files.user-selected.read-write`
  is required and expected for an import/export feature. The imported URL
  is security-scoped → `start/stopAccessingSecurityScopedResource()` is
  handled. A proper `UTExportedTypeDeclarations` entry +
  `UTType(exportedAs: "org.sockpuppet.djroomba.snapshot")`
  (extension `djroomba`, conforms to `public.data`) is added; the
  pre-existing stray `org.sockpuppet.djroomba.song` declaration is left
  untouched (out of scope).

## UI (macos-design: simple, native, consistent)

- File menu: `CommandGroup(.importExport)` → "Export Library Snapshot…",
  "Import Library Snapshot…", "Revert Last Snapshot Import" (disabled
  unless `canRevert`). No keyboard shortcuts (Apple's own apps' import/
  export items typically have none; the app's shortcut space is already
  dense — ⌘R/⇧⌘R/⌥⌘A/⌘N/⌘[).
- `.fileExporter` (a minimal `SnapshotDocument: FileDocument` holding the
  already-built compressed `Data` — built off-main *before* presenting,
  never inside `fileWrapper`) and `.fileImporter` (URL result), driven by
  `@Observable` controller flags via `@Bindable` (no `Binding(get:set:)`).
- The post-import affordance reuses the **exact existing pattern** of the
  `genreImportNotice` chip: a quiet `.status`-slot
  `Label(…, systemImage: "clock.arrow.circlepath")` whose popover shows
  the full result text + a "Revert This Import" button + "Dismiss".
  Slots into the existing `.status` precedence after the genre notice;
  no new type scale (reuses `.callout`/`.secondary`).

## Out of scope (deliberate)

Fixing the macOS-14 genre import itself; multi-backup history; incremental
/ selective field merge UI; conflict resolution UI; encryption; importing
*playlists* from a snapshot (this is a metadata merge, not a library
replace — by explicit user instruction "I don't want to blitz the library").
