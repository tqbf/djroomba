import Foundation
import MusicKit
import Observation

/// One-way import: MusicKit library → SQLite. Apple Music is strictly a read
/// source here; this **never** deletes or mutates app-owned data
/// (`app_playlist*`, `song_stat`, `play_event`, favorites, recents) — it only
/// upserts songs and replaces `apple_playlist` snapshots transactionally via
/// `LibraryStore` (which itself guarantees the isolation; verified by test).
///
/// Concurrency: `@MainActor @Observable` like the other MusicKit services
/// (MusicKit request/response types are main-actor-friendly and our volumes
/// are modest). It `await`s the `Sendable`, off-main `LibraryStore`; only
/// `Sendable` value types (`Song`, `ApplePlaylist`, ids) cross that boundary.
///
/// Paging reuses the proven M1 logic: a `MusicLibraryRequest<Playlist>` page
/// loop, then a strictly **serial** per-playlist `playlist.with([.tracks])`
/// page loop. Full re-import is the v1 cost.
///
/// **Honest performance finding (Phase-5 corrective).** A bounded-parallel
/// `TaskGroup` over the per-playlist fetches was tried and **measured
/// ineffective**: a full re-import of the test library (~270 playlists /
/// ~8200 tracks) ran ~90–120 s with the parallel version (no improvement
/// over the prior serial ~88 s, slightly worse, and it added instability —
/// CPU spiked past one core and a transient inconsistent read was observed).
/// The dominant cost is MusicKit's own per-playlist track resolution on
/// macOS (`playlist.with([.tracks])` + `nextBatch()` paging — CPU-heavy and
/// internally serialized; one very large library playlist alone is a long
/// single task that parallelism cannot split, and concurrent
/// `with([.tracks])` calls contend on MusicKit's internal machinery rather
/// than overlapping). It is **not** SQLite (the batch write idioms are
/// already correct and tested) and **not** fixable by app-side parallelism.
/// The ineffective `TaskGroup` was therefore reverted to the simple proven
/// serial loop; only the harmless **"Importing N of M playlists…"** progress
/// affordance is kept. This cost is accepted for v1 — it's a one-time /
/// Refresh-only operation, surfaced honestly by the progress UI.
@MainActor
@Observable
final class ImportService {

  // MARK: Lifecycle

  init(store: LibraryStore) {
    self.store = store
  }

  // MARK: Internal

  /// Whether one playlist must be re-fetched, or its existing snapshot is
  /// provably still current.
  enum PlaylistImportDecision: Equatable {
    case fetch
    case skipUnchanged
  }

  private(set) var isImporting = false
  private(set) var lastError: String?
  /// Coarse progress for the UI: playlists processed / total discovered.
  private(set) var importedPlaylistCount = 0
  private(set) var totalPlaylistCount = 0
  /// Of `importedPlaylistCount`, how many were the incremental fast path
  /// (unchanged → expensive track fetch skipped). Surfaced for the
  /// profiling finding / a future "N updated, M unchanged" affordance.
  private(set) var skippedPlaylistCount = 0
  /// Imported-playlist ids whose stored snapshot this run actually changed
  /// — successfully re-fetched-and-written, or pruned (vanished). Lets the
  /// caller invalidate only those cached details (Phase B —
  /// `plans/memory-and-laziness.md`); a `.skipUnchanged` playlist is NOT
  /// here, so an incremental Refresh that changed nothing leaves the
  /// on-screen playlist's cached rows warm (no cold SQLite re-read of, e.g.,
  /// a multi-day playlist).
  private(set) var changedPlaylistIDs = Set<String>()

  /// Map a library playlist `Track` to a stored `Song`.
  ///
  /// **The D1 corrective.** A MusicKit `Track` is an enum
  /// (`.song(Song)` / `.musicVideo(MusicVideo)`); its own `track.id` is an
  /// opaque library `MusicItemID` that does **not** round-trip through any
  /// re-fetch. We unwrap the **underlying item** and store *its* id:
  /// `song.id.rawValue` (or `musicVideo.id.rawValue`). And because these
  /// tracks come exclusively from the user's *library* playlists, the
  /// namespace is fixed by **provenance** to `.library` — `PlaybackResolver`
  /// re-resolves these via `MusicLibraryRequest<Song>` (the dev-signed path
  /// Phase 1 proved; no catalog/MusicKit-App-Service entitlement). The old
  /// string-sniffing `namespace(forRawID:)` heuristic is deleted entirely:
  /// provenance decides the namespace, never the shape of the id string.
  ///
  /// A `.musicVideo` is tolerated (stored with `.library` namespace too);
  /// the resolver simply won't find it via `MusicLibraryRequest<Song>` and
  /// will report it unresolved rather than crashing.
  nonisolated static func song(from track: Track, importedAt: Date) -> Song {
    // Underlying-item id (NOT track.id). `Track` exposes the common
    // display fields directly; we keep using those for the snapshot's
    // metadata and only need the enum payload for the durable id.
    let underlyingID: String =
      switch track {
      case .song(let song):
        song.id.rawValue
      case .musicVideo(let video):
        video.id.rawValue
      @unknown default:
        // Forward-compat: fall back to the track id so import never
        // drops a row; provenance namespace still applies.
        track.id.rawValue
      }

    return Song(
      id: UUID().uuidString,
      musicItemID: underlyingID,
      // Provenance: library playlists → library namespace. Period.
      idNamespace: .library,
      title: track.title,
      artistName: track.artistName,
      albumTitle: track.albumTitle,
      duration: track.duration,
      isExplicit: track.contentRating == .explicit,
      // Artwork is no longer stored as a (private-scheme, unfetchable)
      // URL — it is re-resolved live by id at display time via
      // `ArtworkProvider` + MusicKit's `ArtworkImage` (the D2
      // corrective, Phase-1-identical). Kept nil here deliberately.
      artworkURL: nil,
      importedAt: importedAt,
    )
  }

  /// Incremental-import decision for ONE playlist, from the **cheap**
  /// list-fetch metadata only. Conservative by construction:
  /// `.skipUnchanged` ONLY when a snapshot exists AND both the stored and
  /// the current change tokens exist AND are equal. Any uncertainty —
  /// `force`, no current token (MusicKit gave no `lastModifiedDate`), no
  /// snapshot yet, or no stored token — yields `.fetch`. Correctness is
  /// never traded for speed: the worst case is a redundant fetch, never a
  /// stale skip. Pure & `nonisolated` so it's unit-tested with no MusicKit
  /// and no signing.
  nonisolated static func importDecision(
    currentToken: Int?,
    storedToken: Int?,
    hasStoredSnapshot: Bool,
    force: Bool,
  ) -> PlaylistImportDecision {
    if force { return .fetch }
    guard hasStoredSnapshot else { return .fetch }
    guard let currentToken, let storedToken else { return .fetch }
    return currentToken == storedToken ? .skipUnchanged : .fetch
  }

  /// The opaque per-playlist change token from the cheap list fetch:
  /// `Int(playlist.lastModifiedDate.timeIntervalSince1970)`, or `nil` when
  /// MusicKit supplied no `lastModifiedDate` (common on macOS — see
  /// musickit-notes; the decision then conservatively re-fetches).
  /// Integer seconds so it survives GRDB's millisecond date round-trip
  /// under exact equality.
  nonisolated static func changeToken(for playlist: Playlist) -> Int? {
    playlist.lastModifiedDate.map { Int($0.timeIntervalSince1970) }
  }

  /// Read the whole library and write it into SQLite one-way. Per-playlist
  /// failures are tolerated (logged into `lastError`) so one bad playlist
  /// doesn't abort the whole import.
  ///
  /// **Strictly serial** per the honest performance finding on the type:
  /// app-side parallelism does not help (the bottleneck is MusicKit's own
  /// per-playlist track resolution on macOS, not SQLite and not concurrency-
  /// limited), so this is the simple proven loop — fetch a playlist's
  /// tracks, then write it on the unchanged batched write path, then move
  /// to the next. The SQLite write path (`writePlaylist` = batched
  /// upsert + transactional snapshot replace) is byte-for-byte unchanged,
  /// so the proven one-way isolation is not regressed. Progress
  /// (`importedPlaylistCount` / `totalPlaylistCount`) advances as each
  /// playlist is *written*, so the sidebar shows "Importing N of M
  /// playlists…" — the one affordance kept from the reverted perf pass.
  /// Incremental by default: per playlist, decide from the **cheap**
  /// list-fetch metadata whether its membership can have changed, and only
  /// run the expensive `fetchTracks` when it might have. `force: true`
  /// re-fetches everything (the recovery / "Reimport Everything" path —
  /// also what a smart/auto playlist whose contents changed server-side
  /// without bumping `lastModifiedDate` needs). The write path is
  /// unchanged and still strictly one-way isolated.
  func runImport(force: Bool = false) async {
    guard !isImporting else { return }
    isImporting = true
    lastError = nil
    importedPlaylistCount = 0
    totalPlaylistCount = 0
    skippedPlaylistCount = 0
    changedPlaylistIDs = []
    defer { isImporting = false }

    do {
      let playlists = try await fetchAllLibraryPlaylists()
      totalPlaylistCount = playlists.count

      // Cheap: existing snapshot ids → stored change token (no track
      // scan). The basis for skipping the expensive per-playlist fetch.
      let existing = try await store.applePlaylistChangeTokens()

      var failures = [String]()

      // Serial, one playlist in flight at a time. For each: decide skip
      // vs fetch from list metadata only; only `.fetch` pays the
      // MusicKit per-playlist track-resolution cost (the ~99% — see
      // plans/profiling.md).
      for playlist in playlists {
        let id = playlist.id.rawValue
        let decision = Self.importDecision(
          currentToken: Self.changeToken(for: playlist),
          storedToken: existing[id] ?? nil,
          hasStoredSnapshot: existing.keys.contains(id),
          force: force,
        )

        switch decision {
        case .skipUnchanged:
          // Provably current — keep the snapshot, just record that this
          // import saw it. The expensive `fetchTracks` is NOT called.
          try? await store.touchApplePlaylistImportDate(id, to: Date.now)
          skippedPlaylistCount += 1

        case .fetch:
          do {
            let tracks = try await Self.fetchTracks(
              of: playlist,
              maxTrackBatches: maxTrackBatches,
            )
            try await writePlaylist(playlist, tracks: tracks)
            // Snapshot rewritten → its cached detail is now stale.
            // (Only on success: a failed fetch left the snapshot — and
            // thus any cached detail — consistent, so don't invalidate.)
            changedPlaylistIDs.insert(id)
          } catch {
            failures.append(
              "\(playlist.name): \(error.localizedDescription)"
            )
          }
        }
        importedPlaylistCount += 1
      }

      // Drop snapshots whose upstream playlist vanished. Cheap: the live
      // id set is from the list fetch already done; FK cascade removes
      // only their membership (one-way isolation preserved). A vanished
      // playlist's cached detail is also stale → mark it changed.
      let liveIDs = Set(playlists.map { $0.id.rawValue })
      changedPlaylistIDs.formUnion(Set(existing.keys).subtracting(liveIDs))
      try? await store.pruneApplePlaylists(keeping: liveIDs)

      if !failures.isEmpty {
        lastError = "Some playlists could not be imported:\n"
          + failures.prefix(5).joined(separator: "\n")
      }
    } catch {
      lastError = error.localizedDescription
    }
  }

  // MARK: Private

  @ObservationIgnored private let store: LibraryStore

  /// Hard caps on pagination loops to avoid pathological infinite paging
  /// (mirrors the M1 services' guards).
  private let maxPlaylistBatches = 1000
  private let maxTrackBatches = 5000

  /// Page a single playlist's live tracks. `nonisolated static` so the
  /// MusicKit paging (the slow part — CPU-heavy + internally serialized in
  /// MusicKit on macOS; this is the measured import bottleneck and is *not*
  /// reducible by app-side concurrency) runs off the `@MainActor`; it
  /// captures nothing isolated and only returns `Sendable` `Track`s. The
  /// proven M1 paging loop + cap, unchanged. Called once per playlist,
  /// strictly serially, from `runImport`.
  private nonisolated static func fetchTracks(
    of playlist: Playlist,
    maxTrackBatches: Int,
  ) async throws -> [Track] {
    let detailed = try await playlist.with([.tracks])

    var allTracks = [Track]()
    var batch: MusicItemCollection<Track>? = detailed.tracks
    var batchCount = 0
    while let current = batch {
      allTracks.append(contentsOf: current)
      batchCount += 1
      if current.hasNextBatch, batchCount < maxTrackBatches {
        batch = try await current.nextBatch()
      } else {
        batch = nil
      }
    }
    return allTracks
  }

  private func fetchAllLibraryPlaylists() async throws -> [Playlist] {
    var request = MusicLibraryRequest<Playlist>()
    request.limit = 100
    let response = try await request.response()

    var collected = [Playlist]()
    var batch: MusicItemCollection<Playlist>? = response.items
    var batchCount = 0
    while let current = batch {
      collected.append(contentsOf: current)
      batchCount += 1
      if current.hasNextBatch, batchCount < maxPlaylistBatches {
        batch = try await current.nextBatch()
      } else {
        batch = nil
      }
    }
    return collected
  }

  /// Map already-fetched tracks → records and write them. The write path
  /// (batched UPSERT + transactional snapshot replace) is the proven
  /// batched store path, unchanged. Called once per playlist, strictly
  /// serially from `runImport`, so the store's one-way isolation guarantees
  /// and their tests still hold exactly.
  private func writePlaylist(_ playlist: Playlist, tracks allTracks: [Track]) async throws {
    let now = Date.now
    // Map tracks → Song records. A song may appear twice in one playlist:
    // `songsByKey` holds one record per import key (first occurrence
    // wins — they describe the same song); `orderedKeys` preserves the
    // full playlist order so both positions survive in the snapshot.
    var songsByKey = [LibraryStore.SongKey: Song]()
    var orderedKeys = [LibraryStore.SongKey]()
    for track in allTracks {
      let song = Self.song(from: track, importedAt: now)
      let key = LibraryStore.SongKey(
        musicItemID: song.musicItemID,
        namespace: song.idNamespace,
      )
      if songsByKey[key] == nil {
        songsByKey[key] = song
      }
      orderedKeys.append(key)
    }

    // 1. Batch UPSERT the unique songs (one chunked multi-row statement
    //    in one transaction; dedupe on (music_item_id, id_namespace),
    //    preserving stable song.id — non-destructive re-import; the
    //    store guarantees this).
    try await store.upsertSongs(Array(songsByKey.values))

    // 2. ONE batched lookup of every unique key → stored stable song.id
    //    (replaces the old per-song N-await re-read loop — the
    //    user-flagged perf fix).
    let idByKey = try await store.songIDsByKey(
      songsByKey.keys.map { ($0.musicItemID, $0.namespace) }
    )
    // Expand back to full playlist order (duplicates included).
    let songIDs = orderedKeys.compactMap { idByKey[$0] }

    // 3. Replace the Apple playlist snapshot transactionally. This only
    //    touches apple_playlist + apple_playlist_track (store guarantee).
    let record = ApplePlaylist(
      id: playlist.id.rawValue,
      name: playlist.name,
      // Artwork re-resolved live by the playlist's library id at
      // display time (D2: ArtworkProvider + ArtworkImage). The stored
      // private-scheme URL was unfetchable; deliberately nil now.
      artworkURL: nil,
      curator: playlist.curatorName,
      lastImportedAt: now,
      // Persist the change token alongside the snapshot it describes, so
      // the next import can skip re-fetching this playlist if MusicKit
      // reports the same `lastModifiedDate`.
      changeToken: Self.changeToken(for: playlist),
    )
    try await store.replaceApplePlaylistSnapshot(record, songIDs: songIDs)
  }

}
