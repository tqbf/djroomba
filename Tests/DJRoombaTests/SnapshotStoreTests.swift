import Foundation
import Testing
@testable import DJRoomba

/// `LibraryStore.snapshot` / `restore` / `applyImportedMetadata` plus the
/// full export → content-merge → revert pipeline through the real
/// `SnapshotCodec` + `MetadataMatcher`. These need **file-backed** GRDB
/// (VACUUM INTO / online-backup are no-ops on `:memory:`), so each test
/// owns temp DB files and cleans them up. Pins the load-bearing
/// guarantees: the merge writes ONLY `song` metadata (the one-way
/// isolation invariant — playlists / app playlists / play history / stats
/// / favorites / recents untouched, mirroring the other store-isolation
/// tests), and revert restores the *whole* prior database.
struct SnapshotStoreTests {

  // MARK: Internal

  @Test
  func `snapshot then restore round trips the whole database`() async throws {
    let dbURL = tempURL("sqlite")
    let snapURL = tempURL("sqlite")
    defer {
      try? FileManager.default.removeItem(at: dbURL)
      try? FileManager.default.removeItem(at: snapURL)
    }
    let store = try fileStore(at: dbURL)
    try await store.upsertSongs([
      song(id: "s", mid: "m", title: "T", artist: "A", album: "Al", genres: ["Original"])
    ])

    try await store.snapshot(to: snapURL)
    #expect(FileManager.default.fileExists(atPath: snapURL.path))

    // Mutate AFTER the snapshot.
    try await store.applyImportedMetadata([
      MetadataUpdate(
        targetSongID: "s",
        title: "T",
        artistName: "A",
        albumTitle: "Al",
        duration: nil,
        isExplicit: false,
        trackNumber: nil,
        discNumber: nil,
        genreNames: ["Mutated"],
        releaseDate: nil,
        composerName: nil,
        isrc: nil,
        hasLyrics: nil,
        workName: nil,
        movementName: nil,
      )
    ])
    #expect(try await store.song(id: "s")?.genreNames == ["Mutated"])

    // Restore swaps the prior DB back through the open connection.
    try await store.restore(from: snapURL)
    #expect(try await store.song(id: "s")?.genreNames == ["Original"])
  }

  @Test
  func `applyImportedMetadata writes only song metadata (one-way isolated)`() async throws {
    let dbURL = tempURL("sqlite")
    defer { try? FileManager.default.removeItem(at: dbURL) }
    let store = try fileStore(at: dbURL)

    try await store.upsertSongs([
      song(id: "s1", mid: "m1", title: "One", artist: "A", album: "L"),
      song(id: "s2", mid: "m2", title: "Two", artist: "A", album: "L"),
    ])
    // Fixture spanning every app-owned table.
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(id: "ap", name: "Mix", lastImportedAt: .now),
      songIDs: ["s1", "s2"],
    )
    let app = try await store.createAppPlaylist(named: "Faves")
    try await store.addSongsToAppPlaylist(app.id, songIDs: ["s2"])
    try await store.recordPlay(songID: "s1")
    try await store.setFavorite(true, playlistID: "ap", source: .apple)
    try await store.recordRecent(playlistID: "ap", source: .apple)

    try await store.applyImportedMetadata([
      MetadataUpdate(
        targetSongID: "s1",
        title: "One",
        artistName: "A",
        albumTitle: "L",
        duration: nil,
        isExplicit: false,
        trackNumber: 4,
        discNumber: nil,
        genreNames: ["Rock"],
        releaseDate: nil,
        composerName: "Composer",
        isrc: "USX12300001",
        hasLyrics: nil,
        workName: nil,
        movementName: nil,
      )
    ])

    // Song metadata changed for s1, s2 untouched.
    let s1 = try #require(try await store.song(id: "s1"))
    #expect(s1.genreNames == ["Rock"])
    #expect(s1.trackNumber == 4)
    #expect(s1.composerName == "Composer")
    #expect(s1.isrc == "USX12300001")
    #expect(try await store.song(id: "s2")?.genreNames == [])

    // Every relation/identity-bearing table is exactly as before.
    #expect(try await store.songs(inApplePlaylist: "ap").map(\.id) == ["s1", "s2"])
    #expect(try await store.songs(inAppPlaylist: app.id).map(\.id) == ["s2"])
    let stat = try #require(try await store.songStat(songID: "s1"))
    #expect(stat.playCount == 1)
    #expect(try await store.recentlyPlayedSongIDs().contains("s1"))
    #expect(try await store.favorites().map(\.playlistID) == ["ap"])
    #expect(try await store.recentPlaylists().map(\.playlistID) == ["ap"])
    // FK target unchanged ⇒ history still resolves (delete-RESTRICT held).
    #expect(s1.id == "s1")
  }

  @Test
  func `full export content-merge then revert`() async throws {
    let sourceURL = tempURL("sqlite")
    let targetURL = tempURL("sqlite")
    let rawSnapshotURL = tempURL("sqlite")
    let containerURL = tempURL("djroomba")
    let decodedURL = tempURL("sqlite")
    let backupURL = tempURL("sqlite")
    defer {
      for url in [sourceURL, targetURL, rawSnapshotURL, containerURL, decodedURL, backupURL] {
        try? FileManager.default.removeItem(at: url)
      }
    }

    // Good machine: genres + ISRC present.
    let sourceStore = try fileStore(at: sourceURL)
    try await sourceStore.upsertSongs([
      song(
        id: "src1",
        mid: "x1",
        title: "Alive",
        artist: "Pearl Jam",
        album: "Ten",
        genres: ["Alternative"],
        isrc: "USX1",
      ),
      song(
        id: "src2",
        mid: "x2",
        title: "Just",
        artist: "Radiohead",
        album: "The Bends",
        genres: ["Alt/Indie"],
        isrc: "USX2",
      ),
    ])

    // macOS-14 machine: same songs by content, NO genres, plus a playlist
    // + a play that must survive the merge AND the revert.
    let targetStore = try fileStore(at: targetURL)
    try await targetStore.upsertSongs([
      song(id: "tgt1", mid: "y1", title: "Alive", artist: "Pearl Jam", album: "Ten"),
      song(id: "tgt2", mid: "y2", title: "Just", artist: "Radiohead", album: "The Bends"),
    ])
    try await targetStore.replaceApplePlaylistSnapshot(
      ApplePlaylist(id: "p", name: "Daily", lastImportedAt: .now),
      songIDs: ["tgt1", "tgt2"],
    )
    try await targetStore.recordPlay(songID: "tgt1")

    // Export = VACUUM INTO + zlib container; import = decode + open
    // (runs the migrator) + read — exactly the SnapshotService pipeline.
    try await sourceStore.snapshot(to: rawSnapshotURL)
    let container = try await SnapshotCodec.encode(sqliteAt: rawSnapshotURL)
    try container.write(to: containerURL)
    try await SnapshotCodec.decode(
      Data(contentsOf: containerURL),
      toSQLiteAt: decodedURL,
    )
    let importedSource = try await fileStore(at: decodedURL).allSongs()
    let target = try await targetStore.allSongs()

    let (updates, summary) = MetadataMatcher.plan(source: importedSource, target: target)
    #expect(summary.matched == 2)
    #expect(summary.matchedByTitleArtistAlbum == 2)
    #expect(updates.count == 2)

    // Quiet pre-import backup, then apply.
    try await targetStore.snapshot(to: backupURL)
    let changed = try await targetStore.applyImportedMetadata(updates)
    #expect(changed == 2)
    #expect(try await targetStore.song(id: "tgt1")?.genreNames == ["Alternative"])
    #expect(try await targetStore.song(id: "tgt2")?.genreNames == ["Alt/Indie"])
    #expect(try await targetStore.song(id: "tgt1")?.isrc == "USX1")
    // The library itself was NOT blitzed.
    #expect(try await targetStore.songs(inApplePlaylist: "p").map(\.id) == ["tgt1", "tgt2"])
    #expect(try await targetStore.songStat(songID: "tgt1")?.playCount == 1)

    // Revert swaps the pre-import DB back; genres gone, library still intact.
    try await targetStore.restore(from: backupURL)
    #expect(try await targetStore.song(id: "tgt1")?.genreNames == [])
    #expect(try await targetStore.song(id: "tgt2")?.genreNames == [])
    #expect(try await targetStore.songs(inApplePlaylist: "p").map(\.id) == ["tgt1", "tgt2"])
    #expect(try await targetStore.songStat(songID: "tgt1")?.playCount == 1)
  }

  // MARK: Private

  private func tempURL(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "djr-snap-\(UUID().uuidString).\(ext)")
  }

  private func fileStore(at url: URL) throws -> LibraryStore {
    LibraryStore(database: try AppDatabase(path: url.path))
  }

  private func song(
    id: String,
    mid: String,
    title: String,
    artist: String,
    album: String?,
    genres: [String] = [],
    isrc: String? = nil,
    track: Int? = nil,
  ) -> Song {
    Song(
      id: id,
      musicItemID: mid,
      idNamespace: .library,
      title: title,
      artistName: artist,
      albumTitle: album,
      isExplicit: false,
      importedAt: .now,
      trackNumber: track,
      genreNames: genres,
      isrc: isrc,
    )
  }

}
