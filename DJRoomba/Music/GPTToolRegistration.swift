import ContextWindow
import ContextWindowOpenAI
import Foundation
import MusicKit

/// The set of tools the assistant can call.
///
/// Each tool: an OpenAI `function`-shaped schema (`JSONSchemaToolDefinition`)
/// + a `ClosureToolRunner` that decodes the args, dispatches to the
/// `LibraryStore` (or the catalog ingest / MusicKit catalog search), and
/// returns a JSON string the model can read back. Responses cap their array
/// payloads at sane sizes and add an `truncated: true` flag when they do,
/// so the model can ask for more rather than receive a giant blob.
///
/// All runners are `@Sendable` closures captured around the `LibraryStore`
/// value type (which is `Sendable` by construction). The catalog-search and
/// catalog-ingest tools hop to the main actor because MusicKit + the
/// `CatalogIngestService` are main-actor-isolated.
enum GPTToolRegistration {

  // MARK: Internal

  /// Produce the registered tools for one session. The order is the order
  /// the model sees in the system list — alphabetical, so it's stable.
  /// Every runner is wrapped in `LoggedToolRunner` so the tool boundary is
  /// fully observable via `log show` / `log stream` (see `AssistantLog`).
  static func tools(
    store: LibraryStore?,
    catalogIngest: CatalogIngestService?,
  ) -> [ToolDefinition] {
    let raw = [
      addTracksToPlaylist(store: store),
      createPlaylist(store: store),
      listPlaylists(store: store),
      playlistContents(store: store),
      recentlyPlayed(store: store),
      searchAppleMusic(store: store, catalogIngest: catalogIngest),
      trackGenres(store: store),
    ]
    return raw.map { def in
      ToolDefinition(
        schema: def.schema,
        runner: LoggedToolRunner(name: def.name, inner: def.runner),
      )
    }
  }

  // MARK: Private

  /// Cap how many rows any single tool returns. Big enough to be useful in
  /// chat ("show me my favourites"), small enough to not blow context.
  private static let playlistTrackCap = 200

  private static func listPlaylists(store: LibraryStore?) -> ToolDefinition {
    let schema = JSONSchemaToolDefinition(
      name: "list_playlists",
      description: """
        List the user's playlists. By default returns every playlist — both \
        the read-only ones imported from Apple Music's library and the \
        user's own app-owned playlists. Pass `source` to scope the list.
        """,
      parameters: objectSchema(
        properties: [
          "source": stringSchema("""
            One of "all" (default), "library" (Apple Music library imports, \
            read-only), or "app" (user-created, writable).
            """)
        ]
      ),
    )
    let runner = ClosureToolRunner { [store] args in
      guard let store else { return errorJSON("library is unavailable") }
      struct Input: Decodable { var source: String? }
      let input = (try? JSONDecoder().decode(Input.self, from: args)) ?? Input(source: nil)
      let want = (input.source ?? "all").lowercased()

      var rows = [JSONValue]()
      if want == "all" || want == "library" {
        let lists = try await store.applePlaylists()
        for p in lists {
          rows.append(.object([
            "id": .string(p.id),
            "name": .string(p.name),
            "source": .string("library"),
          ]))
        }
      }
      if want == "all" || want == "app" {
        let lists = try await store.appPlaylists()
        let counts = try await store.appPlaylistTrackCounts()
        for p in lists {
          var row: [String: JSONValue] = [
            "id": .string(p.id),
            "name": .string(p.name),
            "source": .string("app"),
          ]
          if let count = counts[p.id] {
            row["trackCount"] = .number(Double(count))
          }
          rows.append(.object(row))
        }
      }
      return encodeJSON(.object([
        "playlists": .array(rows),
        "count": .number(Double(rows.count)),
      ]))
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  private static func playlistContents(store: LibraryStore?) -> ToolDefinition {
    let schema = JSONSchemaToolDefinition(
      name: "playlist_contents",
      description: """
        Return the tracks in a playlist (library or app-owned), with track \
        title, artist, album, and genre tags. Capped at 200 tracks; very \
        long playlists report `truncated: true`.
        """,
      parameters: objectSchema(
        properties: [
          "playlistId": stringSchema("The id from `list_playlists`.")
        ],
        required: ["playlistId"],
      ),
    )
    let runner = ClosureToolRunner { [store] args in
      guard let store else { return errorJSON("library is unavailable") }
      struct Input: Decodable { var playlistId: String }
      guard let input = try? JSONDecoder().decode(Input.self, from: args) else {
        return errorJSON("expected { playlistId }")
      }

      // Try library first, then app. ids are namespace-disjoint by
      // construction (library = Apple's MusicItemID; app = our UUID),
      // so these never collide.
      var songs = try await store.songs(inApplePlaylist: input.playlistId)
      var source = "library"
      if songs.isEmpty {
        songs = try await store.songs(inAppPlaylist: input.playlistId)
        source = songs.isEmpty ? source : "app"
      }
      if songs.isEmpty {
        return errorJSON("no playlist found with id \(input.playlistId)")
      }
      let truncated = songs.count > playlistTrackCap
      if truncated { songs = Array(songs.prefix(playlistTrackCap)) }
      let rows = songs.map { trackJSON($0) }
      return encodeJSON(.object([
        "playlistId": .string(input.playlistId),
        "source": .string(source),
        "tracks": .array(rows),
        "truncated": .bool(truncated),
      ]))
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  private static func trackGenres(store: LibraryStore?) -> ToolDefinition {
    let schema = JSONSchemaToolDefinition(
      name: "track_genres",
      description: """
        Return genre labels. With no arguments, returns the list of every \
        distinct genre in the library (good for discovering what's there). \
        With `trackIds`, returns `[{ id, title, genres }]` for each track.
        """,
      parameters: objectSchema(
        properties: [
          "trackIds": arraySchema(
            of: .object([
              "type": .string("string")
            ]),
            description: """
              Track ids from `playlist_contents` or `recently_played`. \
              Omit to list every distinct genre instead.
              """,
          )
        ]
      ),
    )
    let runner = ClosureToolRunner { [store] args in
      guard let store else { return errorJSON("library is unavailable") }
      struct Input: Decodable { var trackIds: [String]? }
      let input = (try? JSONDecoder().decode(Input.self, from: args)) ?? Input(trackIds: nil)

      if let ids = input.trackIds, !ids.isEmpty {
        var rows = [JSONValue]()
        rows.reserveCapacity(ids.count)
        for id in ids.prefix(playlistTrackCap) {
          if let song = try await store.song(id: id) {
            rows.append(.object([
              "id": .string(song.id),
              "title": .string(song.title),
              "genres": .array(song.genreNames.map { .string($0) }),
            ]))
          }
        }
        return encodeJSON(.object([
          "tracks": .array(rows),
          "truncated": .bool(ids.count > playlistTrackCap),
        ]))
      }

      let genres = try await store.distinctGenres()
      return encodeJSON(.object([
        "genres": .array(genres.map { .string($0) }),
        "count": .number(Double(genres.count)),
      ]))
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  private static func searchAppleMusic(
    store _: LibraryStore?,
    catalogIngest: CatalogIngestService?,
  ) -> ToolDefinition {
    let schema = JSONSchemaToolDefinition(
      name: "search_apple_music",
      description: """
        Search Apple Music's catalog for songs matching `query`. Results are \
        ingested into the local store so the returned `id`s can be passed \
        straight to `add_tracks_to_playlist`. Returns `[{ id, title, artist, \
        album }]`.
        """,
      parameters: objectSchema(
        properties: [
          "query": stringSchema("Search term (artist, song title, album, etc.)."),
          "limit": .object([
            "type": .string("integer"),
            "description": .string("Max results (1–25; default 10)."),
          ]),
        ],
        required: ["query"],
      ),
    )
    let runner = ClosureToolRunner { [catalogIngest] args in
      guard let catalogIngest else { return errorJSON("catalog ingest unavailable") }
      struct Input: Decodable { var query: String
        var limit: Int?
      }
      guard let input = try? JSONDecoder().decode(Input.self, from: args) else {
        return errorJSON("expected { query }")
      }
      let trimmed = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return errorJSON("query is empty") }
      let limit = max(1, min(input.limit ?? 10, 25))

      // `request.response()` is callable from any executor; `catalogIngest`
      // is @MainActor-isolated so the `await` on `ingest(_:)` automatically
      // hops to main.
      var request = MusicCatalogSearchRequest(
        term: trimmed,
        types: [MusicKit.Song.self],
      )
      request.limit = limit
      let catalogSongs: [MusicKit.Song]
      do {
        catalogSongs = Array(try await request.response().songs)
      } catch {
        return errorJSON("catalog search failed: \(error.localizedDescription)")
      }
      let internalIDs: [String]
      do {
        internalIDs = try await catalogIngest.ingest(catalogSongs)
      } catch {
        return errorJSON("ingest failed: \(error.localizedDescription)")
      }
      // `internalIDs` is order-aligned with input (per `ingest(_:)`'s docs).
      var rows = [JSONValue]()
      rows.reserveCapacity(catalogSongs.count)
      for (i, song) in catalogSongs.enumerated() where i < internalIDs.count {
        rows.append(.object([
          "id": .string(internalIDs[i]),
          "title": .string(song.title),
          "artist": .string(song.artistName),
          "album": .string(song.albumTitle ?? ""),
        ]))
      }
      return encodeJSON(.object([
        "query": .string(trimmed),
        "results": .array(rows),
      ]))
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  private static func recentlyPlayed(store: LibraryStore?) -> ToolDefinition {
    let schema = JSONSchemaToolDefinition(
      name: "recently_played",
      description: """
        Return the most recently played tracks (distinct by song). Capped \
        at 100; default 25.
        """,
      parameters: objectSchema(
        properties: [
          "limit": .object([
            "type": .string("integer"),
            "description": .string("Max results (1–100; default 25)."),
          ])
        ]
      ),
    )
    let runner = ClosureToolRunner { [store] args in
      guard let store else { return errorJSON("library is unavailable") }
      struct Input: Decodable { var limit: Int? }
      let input = (try? JSONDecoder().decode(Input.self, from: args)) ?? Input(limit: nil)
      let limit = max(1, min(input.limit ?? 25, 100))

      let page = try await store.recentlyPlayedPage(beforeSeq: nil, limit: limit)
      let rows = page.map { entry -> JSONValue in
        var row: [String: JSONValue] = [
          "id": .string(entry.song.id),
          "title": .string(entry.song.title),
          "artist": .string(entry.song.artistName),
          "album": .string(entry.song.albumTitle ?? ""),
          "playCount": .number(Double(entry.playCount)),
        ]
        if let date = entry.lastPlayedAt {
          row["lastPlayedAt"] = .string(ISO8601DateFormatter().string(from: date))
        }
        return .object(row)
      }
      return encodeJSON(.object([
        "tracks": .array(rows),
        "count": .number(Double(rows.count)),
      ]))
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  private static func createPlaylist(store: LibraryStore?) -> ToolDefinition {
    let schema = JSONSchemaToolDefinition(
      name: "create_playlist",
      description: """
        Create a new app-owned (writable) playlist with the given name. \
        Returns the new playlist's `id` so it can be passed straight to \
        `add_tracks_to_playlist`.
        """,
      parameters: objectSchema(
        properties: [
          "name": stringSchema("Display name for the new playlist.")
        ],
        required: ["name"],
      ),
    )
    let runner = ClosureToolRunner { [store] args in
      guard let store else { return errorJSON("library is unavailable") }
      struct Input: Decodable { var name: String }
      guard let input = try? JSONDecoder().decode(Input.self, from: args) else {
        return errorJSON("expected { name }")
      }
      let trimmed = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return errorJSON("name is empty") }

      let playlist = try await store.createAppPlaylist(named: trimmed)
      return encodeJSON(.object([
        "id": .string(playlist.id),
        "name": .string(playlist.name),
      ]))
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  private static func addTracksToPlaylist(store: LibraryStore?) -> ToolDefinition {
    let schema = JSONSchemaToolDefinition(
      name: "add_tracks_to_playlist",
      description: """
        Append the given track ids to an app-owned playlist (the kind \
        created by `create_playlist`). Library-imported playlists are \
        read-only and rejected. Track ids come from `search_apple_music`, \
        `playlist_contents`, or `recently_played`.
        """,
      parameters: objectSchema(
        properties: [
          "playlistId": stringSchema("Target app-owned playlist id."),
          "trackIds": arraySchema(
            of: .object(["type": .string("string")]),
            description: "Track ids to append, in order.",
          ),
        ],
        required: ["playlistId", "trackIds"],
      ),
    )
    let runner = ClosureToolRunner { [store] args in
      guard let store else { return errorJSON("library is unavailable") }
      struct Input: Decodable {
        var playlistId: String
        var trackIds: [String]
      }
      guard let input = try? JSONDecoder().decode(Input.self, from: args) else {
        return errorJSON("expected { playlistId, trackIds }")
      }
      guard !input.trackIds.isEmpty else {
        return errorJSON("trackIds is empty")
      }
      // Guard against attempting to append to a library playlist (read-only).
      let appLists = try await store.appPlaylists()
      guard appLists.contains(where: { $0.id == input.playlistId }) else {
        return errorJSON("\(input.playlistId) is not a writable app playlist")
      }
      try await store.addSongsToAppPlaylist(
        input.playlistId,
        songIDs: input.trackIds,
      )
      return encodeJSON(.object([
        "playlistId": .string(input.playlistId),
        "added": .number(Double(input.trackIds.count)),
      ]))
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  private static func trackJSON(_ song: Song) -> JSONValue {
    .object([
      "id": .string(song.id),
      "title": .string(song.title),
      "artist": .string(song.artistName),
      "album": .string(song.albumTitle ?? ""),
      "genres": .array(song.genreNames.map { .string($0) }),
    ])
  }

  private static func objectSchema(
    properties: [String: JSONValue],
    required: [String] = [],
  ) -> JSONValue {
    var dict: [String: JSONValue] = [
      "type": .string("object"),
      "properties": .object(properties),
    ]
    if !required.isEmpty {
      dict["required"] = .array(required.map { .string($0) })
    }
    return .object(dict)
  }

  private static func stringSchema(_ description: String) -> JSONValue {
    .object([
      "type": .string("string"),
      "description": .string(description),
    ])
  }

  private static func arraySchema(of items: JSONValue, description: String) -> JSONValue {
    .object([
      "type": .string("array"),
      "items": items,
      "description": .string(description),
    ])
  }

  private static func encodeJSON(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }

  private static func errorJSON(_ message: String) -> String {
    encodeJSON(.object(["error": .string(message)]))
  }
}
