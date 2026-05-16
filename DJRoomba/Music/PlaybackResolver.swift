import Foundation
import MusicKit
import Observation

/// Re-resolves stored song rows back to playable MusicKit `Song`s at play
/// time, then hands them to the existing M1 `PlaybackService` to build the
/// `ApplicationMusicPlayer.Queue`. This validates the core local-first
/// assumption (the 🔴 id store-then-re-resolve round trip): SQLite keeps only
/// `MusicItemID` + namespace; nothing live is retained between import and
/// playback.
///
/// Resolution strategy (per `plans/data-and-import.md`, **D1 corrective**):
/// - group the queue's stored songs by `id_namespace`,
/// - **library ids → `MusicLibraryRequest<MusicKit.Song>` filtered by
///   `\.id` — the live, dev-signed path Phase 1 PROVED works for library
///   read with NO catalog / MusicKit-App-Service entitlement.** Import now
///   stores the underlying `Song`'s *library* id (provenance, not
///   string-sniffing), so every imported track flows through this branch.
/// - catalog ids → `MusicCatalogResourceRequest<Song>`: kept for the future
///   but **dormant** — `ImportService` imports nothing catalog-namespace
///   (library playlists → `.library` provenance), so this branch never
///   receives ids today. It must only ever get genuinely catalog ids.
/// - reassemble in the original queue order, **tolerating** individual
///   unresolvable tracks (region/catalog-removed, user-uploads, music
///   videos, DRM edge cases) so one bad id never breaks the whole queue
///   (risk register).
///
/// Concurrency: `@MainActor @Observable` like the sibling MusicKit services.
/// Pure grouping/reassembly is factored out as `static` so it can be
/// unit-tested without a live MusicKit session.
@MainActor
@Observable
final class PlaybackResolver {

  // MARK: Internal

  /// Outcome of resolving a queue: the playable songs in queue order, the
  /// song to start at (if it resolved), the **stored `song.id`** of the
  /// track playback actually starts at (for play recording — the resolved
  /// `Song.id` is the song's own `i.` id and does NOT equal the stored
  /// `music_item_id`, so id-matching back to a row is unreliable; this
  /// carries the FK target directly), the **canonical play context**, and
  /// which stored ids dropped out.
  ///
  /// `playContext` is *our* data from *our* SQLite read: stored `song.id`s
  /// **parallel to `songs`** (same count & order — `playContext[k]` is
  /// `songs[k]`'s stored id), so attribution is a structural-position
  /// index into our list, never a live-Apple-id translation (see
  /// `plans/play-statistics.md` — "Rejected alternative"). An element is
  /// `nil` only when that queue position has no canonically-attributable
  /// stored row (a live Apple-playlist track beyond the stored snapshot —
  /// the playlist changed since import): the song still plays, but it
  /// records no stats rather than being misattributed. Parallelism is by
  /// construction — every `songs` append has a paired `playContext` append.
  struct Resolution: Sendable {
    var songs: [MusicKit.Song]
    var startSong: MusicKit.Song?
    /// The `TrackRow.songID` (app-stable `song.id`) of the started track.
    var startSongID: String?
    /// Stored `song.id` per queue position, parallel to `songs`; `nil` at
    /// an unattributable position (see the type doc).
    var playContext: [String?]
    var unresolved: [String]
  }

  // (The original Phase-3 batch `memberOf` `resolve(rows:startAt:)` was
  // removed in Phase 4: it keyed resolved songs by the resolved `Song.id`
  // and `reassemble` looked them up by the stored `music_item_id` — the
  // exact Track-id≠Song-id mismatch that returned zero. Its correct
  // successor is `resolveAppPlaylist` below, which re-resolves each stored
  // id 1:1 with per-id `equalTo` and keys by the *stored* id. The pure
  // `groupByNamespace`/`reassemble` helpers it used are kept and now back
  // that working path.)

  struct GroupedPlan: Equatable, Sendable {
    var libraryIDs: [MusicItemID]
    var catalogIDs: [MusicItemID]
  }

  private(set) var lastError: String?
  /// Ids that could not be re-resolved on the most recent attempt — the
  /// UI/PROGRESS can surface this honestly rather than failing silently.
  private(set) var unresolvedMusicItemIDs = [String]()

  /// Group a queue's rows by id namespace, de-duplicating ids within each
  /// namespace (the batch re-fetch only needs each id once; reassembly
  /// re-expands to the original order/duplication).
  nonisolated static func groupByNamespace(_ rows: [TrackRow]) -> GroupedPlan {
    var libraryIDs = [MusicItemID]()
    var catalogIDs = [MusicItemID]()
    var seenLibrary = Set<String>()
    var seenCatalog = Set<String>()
    for row in rows {
      switch row.namespace {
      case .library:
        if seenLibrary.insert(row.musicItemID).inserted {
          libraryIDs.append(MusicItemID(row.musicItemID))
        }

      case .catalog:
        if seenCatalog.insert(row.musicItemID).inserted {
          catalogIDs.append(MusicItemID(row.musicItemID))
        }
      }
    }
    return GroupedPlan(libraryIDs: libraryIDs, catalogIDs: catalogIDs)
  }

  /// Rebuild the queue in the original row order from re-fetched songs,
  /// dropping rows that didn't resolve and reporting them. The start song
  /// falls back to the first resolved song if the requested start dropped.
  /// Also reports the **stored `song.id`** of the started row so the
  /// caller can record the play against the right FK target (the resolved
  /// `Song.id` is the song's own `i.` id and won't equal the stored id),
  /// and the **canonical play context** — `playContext[k]` is the stored
  /// `song.id` of `songs[k]`, appended in the same loop iteration as the
  /// song so the two arrays are parallel by construction (*our* ids from
  /// *our* read; here every resolved row has a stored id, so no element is
  /// nil).
  nonisolated static func reassemble(
    rows: [TrackRow],
    startRow: TrackRow?,
    resolved: [String: MusicKit.Song],
  ) -> Resolution {
    var songs = [MusicKit.Song]()
    var playContext = [String?]()
    var unresolved = [String]()
    for row in rows {
      if let song = resolved[row.musicItemID] {
        songs.append(song)
        playContext.append(row.songID)
      } else {
        unresolved.append(row.musicItemID)
      }
    }
    let startSong: MusicKit.Song?
    let startSongID: String?
    if let startRow, let s = resolved[startRow.musicItemID] {
      startSong = s
      startSongID = startRow.songID
    } else {
      startSong = songs.first
      startSongID = playContext.first ?? nil
    }
    return Resolution(
      songs: songs,
      startSong: startSong,
      startSongID: startSongID,
      playContext: playContext,
      unresolved: unresolved,
    )
  }

  /// The structural index of `startSongID` within the canonical play
  /// context. This is a lookup in **our** context by **our** `song.id`
  /// (never an Apple id): the position the player will seed
  /// `startingAt:` to. Falls back to `0` (queue head) when there is no
  /// start id or it isn't in the context — the same "first song" fallback
  /// `reassemble` uses for `startSong`. Pure, MusicKit-free, unit-tested
  /// with no live session (mirrors `groupByNamespace`/`reassemble`).
  nonisolated static func startIndex(
    in playContext: [String?],
    startSongID: String?,
  ) -> Int {
    guard let startSongID else { return 0 }
    return playContext.firstIndex { $0 == startSongID } ?? 0
  }

  /// The stored `song.id` at a structural queue position in the canonical
  /// play context, bounds-checked (out-of-range / empty context → nil).
  /// `index` is the player's *structural queue position*, an ordinal into
  /// **our** ordered context — emphatically NOT an Apple content id and
  /// never derived from one (see `plans/play-statistics.md`). Pure,
  /// MusicKit-free, unit-tested with no live session.
  nonisolated static func storedSongID(
    in playContext: [String?],
    at index: Int,
  ) -> String? {
    guard playContext.indices.contains(index) else { return nil }
    return playContext[index]
  }

  /// Re-resolve an imported Apple playlist for playback by its stored
  /// **library playlist id**, then play its live tracks.
  ///
  /// D1 finding (proven by the temporary diagnostic, now removed): a stored
  /// `music_item_id` is the playlist *Track* id, which is NOT the library
  /// `Song` id. `MusicLibraryRequest<Song>.filter(matching:\.id,memberOf:)`
  /// *does* return the right songs but keyed by their own `i.`-prefixed
  /// ids, so song-level reassembly by the stored id finds zero matches.
  /// Re-resolving the *playlist* by its stored library id and reading its
  /// live `.tracks` round-trips correctly — stored ids and order align 1:1
  /// with the live tracks — and is exactly Phase 1's proven playback path.
  /// (The song-level helpers below stay for the future Phase-4 app-playlist
  /// / catalog path and remain unit-tested; they are not on this path.)
  func resolvePlaylist(
    libraryPlaylistID: String,
    rows: [TrackRow],
    startAt startRow: TrackRow?,
  ) async -> Resolution? {
    lastError = nil
    unresolvedMusicItemIDs = []
    do {
      var request = MusicLibraryRequest<MusicKit.Playlist>()
      request.filter(matching: \.id, equalTo: MusicItemID(libraryPlaylistID))
      let response = try await request.response()
      guard let livePlaylist = response.items.first else {
        lastError = "This playlist is no longer in your Apple Music library."
        return nil
      }

      // Page the live tracks (large playlists batch — mirrors the
      // proven import loop, same hard cap against pathological paging).
      let detailed = try await livePlaylist.with([.tracks])
      var liveTracks = [Track]()
      var batch: MusicItemCollection<Track>? = detailed.tracks
      var batchCount = 0
      while let current = batch {
        liveTracks.append(contentsOf: current)
        batchCount += 1
        if current.hasNextBatch, batchCount < maxTrackBatches {
          batch = try await current.nextBatch()
        } else {
          batch = nil
        }
      }

      var songs = [MusicKit.Song]()
      var playContext = [String?]()
      var unresolved = [String]()
      for (index, track) in liveTracks.enumerated() {
        switch track {
        case .song(let song):
          // Parallel by construction: every `songs` append has exactly
          // one paired `playContext` append. Stored row order aligns 1:1
          // with the live tracks (import preserves playlist order; the
          // re-resolve returns it). A live track beyond the stored
          // snapshot (playlist changed since import) still plays but is
          // unattributable → `nil` (no stats, never misattributed). Our
          // id from our read; the live `Song.id` is never a key.
          songs.append(song)
          playContext.append(index < rows.count ? rows[index].songID : nil)

        default:
          // Music video / unknown entry: not played. Report it by
          // the stored id at the same position — order aligns
          // (import preserves playlist order; re-resolve returns it).
          if index < rows.count {
            unresolved.append(rows[index].musicItemID)
          }
        }
      }
      guard !songs.isEmpty else {
        lastError = "None of this playlist's tracks could be played."
        return nil
      }

      // Start song: match the requested row to its live track by id
      // (stored id == live Track id, verified), else first song. Carry
      // the stored `song.id` so the caller records the play against the
      // right FK target (the live Song id won't equal the stored id).
      var startSong = songs.first
      var startSongID = rows.first(where: { row in
        liveTracks.contains { track in
          if case .song = track { return track.id.rawValue == row.musicItemID }
          return false
        }
      })?.songID
      if
        let startRow,
        let idx = liveTracks.firstIndex(where: { $0.id.rawValue == startRow.musicItemID }),
        case .song(let song) = liveTracks[idx]
      {
        startSong = song
        startSongID = startRow.songID
      }

      unresolvedMusicItemIDs = unresolved
      return Resolution(
        songs: songs,
        startSong: startSong,
        startSongID: startSongID,
        playContext: playContext,
        unresolved: unresolved,
      )
    } catch {
      lastError = error.localizedDescription
      return nil
    }
  }

  /// Re-resolve an **app playlist** (an arbitrary user-owned song
  /// collection, *not* backed by an Apple playlist) for playback.
  ///
  /// Why this differs from `resolvePlaylist`: imported Apple playlists
  /// sidestep the Track-id≠Song-id problem by re-resolving the *playlist*
  /// and reading its live tracks. App playlists have no Apple playlist to
  /// re-resolve — they're an ad-hoc set of stored songs. The Phase-3 probe
  /// established the exact shape that *does* round-trip: a stored
  /// `music_item_id` (the underlying library `Song`'s id, captured by
  /// `ImportService` provenance) re-resolves **1:1** via
  /// `MusicLibraryRequest<Song>.filter(matching:\.id, equalTo: storedID)`
  /// when queried **one id at a time** — only batch `memberOf` loses the
  /// query→result correspondence (returned `Song.id`s differ). So we issue
  /// one bounded `equalTo` request per *unique* stored id, concurrently via
  /// a `TaskGroup` (structured concurrency; no GCD), tolerate misses, and
  /// `reassemble` in the original playlist order (the existing pure,
  /// unit-tested helper — duplicates re-expand, the start row is honored).
  func resolveAppPlaylist(
    rows: [TrackRow],
    startAt startRow: TrackRow?,
  ) async -> Resolution? {
    lastError = nil
    unresolvedMusicItemIDs = []

    // Unique stored ids (reassembly re-expands to full order/duplication).
    // App-playlist songs were imported with `.library` provenance, so
    // they re-resolve through `MusicLibraryRequest<Song>` exactly like
    // the imported-playlist path; the namespace split is kept so a future
    // catalog-import song would route to the catalog request unchanged.
    let plan = Self.groupByNamespace(rows)
    var resolvedByMusicItemID = [String: MusicKit.Song]()

    if !plan.libraryIDs.isEmpty {
      let resolved = await resolveLibrarySongsIndividually(plan.libraryIDs)
      for (rawID, song) in resolved { resolvedByMusicItemID[rawID] = song }
    }

    // Dormant today (nothing catalog-namespace is imported). Per-id
    // catalog resolution would slot in here the same way; kept minimal.
    do {
      if !plan.catalogIDs.isEmpty {
        let songs = try await fetchCatalogSongs(plan.catalogIDs)
        for song in songs { resolvedByMusicItemID[song.id.rawValue] = song }
      }
    } catch {
      lastError = error.localizedDescription
    }

    let reassembled = Self.reassemble(
      rows: rows,
      startRow: startRow,
      resolved: resolvedByMusicItemID,
    )
    unresolvedMusicItemIDs = reassembled.unresolved
    guard !reassembled.songs.isEmpty else {
      if lastError == nil {
        lastError = "None of this playlist's tracks could be matched for playback."
      }
      return nil
    }
    return reassembled
  }

  // MARK: Private

  /// Hard cap on track paging (mirrors `ImportService`).
  private let maxTrackBatches = 5000

  /// Max concurrent per-id MusicKit requests. A bounded window (not "fire
  /// every id at once") so a large app playlist doesn't open hundreds of
  /// simultaneous `MusicLibraryRequest`s — that risks throttling and is
  /// slower overall. 8 keeps the round trip parallel without flooding.
  private let maxConcurrentResolves = 8

  /// Resolve each stored library id individually (the verified 1:1 path),
  /// concurrently but **bounded**, keyed by the **stored** id so reassembly
  /// can map back even though the resolved `Song.id` differs. Misses are
  /// absent from the map (tolerated → reported as unresolved by
  /// `reassemble`). A single failed lookup never aborts the others (each
  /// task swallows its own error and yields nil; the queue is built from
  /// whatever resolved). Structured concurrency only — no GCD.
  private func resolveLibrarySongsIndividually(
    _ ids: [MusicItemID]
  ) async -> [String: MusicKit.Song] {
    let limit = maxConcurrentResolves
    return await withTaskGroup(
      of: (String, MusicKit.Song?).self,
      returning: [String: MusicKit.Song].self,
    ) { group in
      var result = [String: MusicKit.Song]()
      var index = 0

      func addTask(for id: MusicItemID) {
        group.addTask {
          let raw = id.rawValue
          do {
            var request = MusicLibraryRequest<MusicKit.Song>()
            request.filter(matching: \.id, equalTo: id)
            request.limit = 1
            let response = try await request.response()
            return (raw, response.items.first)
          } catch {
            return (raw, nil)
          }
        }
      }

      // Prime the window, then replace each finished task with the
      // next id — at most `limit` requests in flight at any moment.
      while index < ids.count, index < limit {
        addTask(for: ids[index])
        index += 1
      }
      for await (rawID, song) in group {
        if let song { result[rawID] = song }
        if index < ids.count {
          addTask(for: ids[index])
          index += 1
        }
      }
      return result
    }
  }

  //
  // The library re-fetch for app playlists is per-id `equalTo` (see
  // `resolveLibrarySongsIndividually`), NOT a batch `memberOf` — batch
  // `memberOf` returns the right songs but keyed by *their own* ids, losing
  // the query→result correspondence (the disproven Phase-3 path; that
  // helper was removed). This catalog helper stays for a future
  // catalog-import feature; nothing catalog-namespace is imported today.

  private func fetchCatalogSongs(_ ids: [MusicItemID]) async throws -> [MusicKit.Song] {
    let request = MusicCatalogResourceRequest<MusicKit.Song>(
      matching: \.id,
      memberOf: ids,
    )
    let response = try await request.response()
    return Array(response.items)
  }

}
