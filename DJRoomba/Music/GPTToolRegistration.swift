import ContextWindow
import ContextWindowOpenAI
import Foundation
import GRDB
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

  /// Closure pattern for tools that need to talk to `MusicController`.
  /// Held weakly inside `GPTService`; this provider returns `nil` after
  /// the controller has been torn down. Tool runners hop to the main
  /// actor (`Task { @MainActor … }.value`) before reading the
  /// controller, since `MusicController` is `@MainActor`-isolated.
  typealias ControllerProvider = @Sendable @MainActor () -> MusicController?

  /// Produce the registered tools for one session. The order is the
  /// order the model sees in the system list — alphabetical, so it's
  /// stable. Every runner is wrapped in `LoggedToolRunner` so the tool
  /// boundary is fully observable via `log show` / `log stream` (see
  /// `AssistantLog`).
  static func tools(
    store: LibraryStore?,
    catalogIngest: CatalogIngestService?,
    controllerProvider: @escaping ControllerProvider = { nil },
  ) -> [ToolDefinition] {
    let raw = [
      addTracksToPlaylist(store: store, controllerProvider: controllerProvider),
      appState(controllerProvider: controllerProvider),
      createPlaylist(store: store, controllerProvider: controllerProvider),
      listPlaylists(store: store),
      playPlaylist(controllerProvider: controllerProvider),
      playTrack(store: store, controllerProvider: controllerProvider),
      playlistContents(store: store),
      recentlyPlayed(store: store),
      renameGenre(store: store, controllerProvider: controllerProvider),
      searchAppleMusic(store: store, catalogIngest: catalogIngest),
      setTrackGenres(store: store, controllerProvider: controllerProvider),
      sqlQuery(store: store),
      trackGenres(store: store),
      upNextAdd(store: store, controllerProvider: controllerProvider),
      upNextCount(controllerProvider: controllerProvider),
      upNextGet(controllerProvider: controllerProvider),
      upNextRemove(controllerProvider: controllerProvider),
    ]
    return raw.map { def in
      ToolDefinition(
        schema: def.schema,
        runner: LoggedToolRunner(name: def.name, inner: def.runner),
      )
    }
  }

  // MARK: Private

  /// Internal carrier for `app_state` — avoids leaking the controller
  /// types into the JSON builder.
  private struct AppStateSnapshot {
    struct Selected {
      var id: String
      var name: String
      var source: String
    }

    struct NowPlaying {
      var songId: String?
      var title: String
      var artist: String?
      var playlistId: String?
    }

    static let empty = AppStateSnapshot(selectedPlaylist: nil, nowPlaying: nil)

    var selectedPlaylist: Selected?
    var nowPlaying: NowPlaying?

    var json: JSONValue {
      var dict = [String: JSONValue]()
      if let selected = selectedPlaylist {
        dict["selectedPlaylist"] = .object([
          "id": .string(selected.id),
          "name": .string(selected.name),
          "source": .string(selected.source),
        ])
      } else {
        dict["selectedPlaylist"] = .null
      }
      if let playing = nowPlaying {
        var nowDict: [String: JSONValue] = [
          "title": .string(playing.title)
        ]
        if let id = playing.songId { nowDict["songId"] = .string(id) }
        if let artist = playing.artist { nowDict["artist"] = .string(artist) }
        if let playlist = playing.playlistId {
          nowDict["playlistId"] = .string(playlist)
        }
        dict["nowPlaying"] = .object(nowDict)
      } else {
        dict["nowPlaying"] = .null
      }
      return .object(dict)
    }
  }

  /// Cap how many rows any single tool returns. Big enough to be useful in
  /// chat ("show me my favourites"), small enough to not blow context.
  private static let playlistTrackCap = 200

  /// Maximum rows returned by `sql_query` in one call. Big enough for
  /// real use, small enough to never blow context.
  private static let sqlRowCap = 200

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

  private static func createPlaylist(
    store: LibraryStore?,
    controllerProvider: @escaping ControllerProvider,
  ) -> ToolDefinition {
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

      // Hop main-actor to drive the controller's create path —
      // `createAppPlaylist(autoSelect: false)` calls the store AND
      // runs `rebuildDerivedSummaries()` so the sidebar's "My
      // Playlists" section picks up the new row immediately (the
      // bug the tool's earlier direct-store path produced: the row
      // didn't appear until the next sidebar rebuild trigger,
      // typically a user clicking the "+" button).
      let provider = controllerProvider
      let mintedID: String? = await Task { @MainActor () -> String? in
        guard let controller = provider() else { return nil }
        return await controller.createAppPlaylist(named: trimmed, autoSelect: false)
      }.value
      if let mintedID {
        return encodeJSON(.object([
          "id": .string(mintedID),
          "name": .string(trimmed),
        ]))
      }
      // Controller wasn't available (rare — service torn down). Fall
      // back to the direct store path so the user still gets the
      // playlist created, even though the sidebar won't refresh
      // until the next rebuild trigger.
      let playlist = try await store.createAppPlaylist(named: trimmed)
      return encodeJSON(.object([
        "id": .string(playlist.id),
        "name": .string(playlist.name),
      ]))
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  private static func addTracksToPlaylist(
    store: LibraryStore?,
    controllerProvider: @escaping ControllerProvider,
  ) -> ToolDefinition {
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
      // Route through the controller's mutateAppPlaylist path so the
      // track table + cached detail get re-loaded and the sidebar's
      // derived summaries (incl. track counts) refresh — the bug fix
      // for "added tracks don't show up until I tap somewhere else."
      let provider = controllerProvider
      let routed = await Task { @MainActor () -> Bool in
        guard let controller = provider() else { return false }
        await controller.addSongs(input.trackIds, toAppPlaylist: input.playlistId)
        return true
      }.value
      if !routed {
        // Controller torn down — fall back to direct store write so
        // the data still lands.
        try await store.addSongsToAppPlaylist(input.playlistId, songIDs: input.trackIds)
      }
      return encodeJSON(.object([
        "playlistId": .string(input.playlistId),
        "added": .number(Double(input.trackIds.count)),
      ]))
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  /// Start playing a playlist by id (library or app-owned). Dispatches
  /// via `MusicCommand.playPlaylist` so the existing handle path owns
  /// the queue + context plumbing.
  private static func playPlaylist(
    controllerProvider: @escaping ControllerProvider
  ) -> ToolDefinition {
    let schema = JSONSchemaToolDefinition(
      name: "play_playlist",
      description: """
        Start playing a playlist by id (library or app-owned). Same path \
        the sidebar's Play button uses. Returns the playlist's name on \
        success so the model can echo back what's now playing.
        """,
      parameters: objectSchema(
        properties: [
          "playlistId": stringSchema("Playlist id from `list_playlists`.")
        ],
        required: ["playlistId"],
      ),
    )
    let runner = ClosureToolRunner { args in
      struct Input: Decodable { var playlistId: String }
      guard let input = try? JSONDecoder().decode(Input.self, from: args) else {
        return errorJSON("expected { playlistId }")
      }
      let provider = controllerProvider
      let resolved: String? = await Task { @MainActor () -> String? in
        guard let controller = provider() else { return nil }
        guard
          let summary = controller.allSummaries.first(where: { $0.id == input.playlistId })
        else { return nil }
        await controller.handle(.playPlaylist(input.playlistId))
        return summary.name
      }.value
      guard let name = resolved else {
        return errorJSON("no playlist with id \(input.playlistId), or playback unavailable")
      }
      return encodeJSON(.object([
        "playlistId": .string(input.playlistId),
        "playing": .string(name),
      ]))
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  /// Play a single track. Resolves our internal `song.id` to its
  /// MusicKit `musicItemID`, sets the playlist context (the model can
  /// pass one, or we default to the currently-selected playlist), and
  /// dispatches `MusicCommand.playTrack`. If no playlist context is
  /// available the call errors so the model can guide the user back to
  /// `play_playlist` instead — a single arbitrary-song queue is a
  /// future enhancement.
  private static func playTrack(
    store: LibraryStore?,
    controllerProvider: @escaping ControllerProvider,
  ) -> ToolDefinition {
    let schema = JSONSchemaToolDefinition(
      name: "play_track",
      description: """
        Play a single track. Pass the internal `trackId` from \
        `playlist_contents`, `recently_played`, or `search_apple_music`. \
        Optionally pass a `playlistId` to set the queue context — if \
        omitted, the currently-selected playlist is used. Returns the \
        track title + artist on success.
        """,
      parameters: objectSchema(
        properties: [
          "trackId": stringSchema("Internal song id."),
          "playlistId": stringSchema("""
            Optional playlist id to set as the playing queue context. \
            Defaults to the currently-selected playlist.
            """),
        ],
        required: ["trackId"],
      ),
    )
    let runner = ClosureToolRunner { [store] args in
      guard let store else { return errorJSON("library is unavailable") }
      struct Input: Decodable {
        var trackId: String
        var playlistId: String?
      }
      guard let input = try? JSONDecoder().decode(Input.self, from: args) else {
        return errorJSON("expected { trackId }")
      }
      guard let song = try await store.song(id: input.trackId) else {
        return errorJSON("no song with id \(input.trackId)")
      }
      let provider = controllerProvider
      let outcome: (title: String, artist: String)? = await Task {
        @MainActor () -> (title: String, artist: String)? in
        guard let controller = provider() else { return nil }
        let playlistID = input.playlistId ?? controller.selectedPlaylistID
        guard let playlistID else { return nil }
        await controller.handle(
          .playTrack(song.musicItemID, playlistID: playlistID)
        )
        return (song.title, song.artistName)
      }.value
      guard let outcome else {
        return errorJSON(
          "no playlist context — pass `playlistId` or select a playlist first"
        )
      }
      return encodeJSON(.object([
        "trackId": .string(input.trackId),
        "title": .string(outcome.title),
        "artist": .string(outcome.artist),
      ]))
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  /// Add a genre tag to one or many tracks. Idempotent — songs already
  /// carrying the tag are left alone (counted in `skipped`). Pure
  /// SQLite, no MusicKit. Returns how many rows were rewritten.
  private static func setTrackGenres(
    store: LibraryStore?,
    controllerProvider: @escaping ControllerProvider,
  ) -> ToolDefinition {
    let schema = JSONSchemaToolDefinition(
      name: "add_genre_to_tracks",
      description: """
        Append a genre tag to one or many tracks. The tag is a literal \
        string match — there is no genre entity. Idempotent: songs that \
        already carry the tag are unchanged. Use `rename_genre` to \
        rewrite an existing tag everywhere it appears.
        """,
      parameters: objectSchema(
        properties: [
          "genre": stringSchema("Genre tag to add (e.g. \"Synthwave\")."),
          "trackIds": arraySchema(
            of: .object(["type": .string("string")]),
            description: "Internal song ids to tag.",
          ),
        ],
        required: ["genre", "trackIds"],
      ),
    )
    let runner = ClosureToolRunner { [store] args in
      guard let store else { return errorJSON("library is unavailable") }
      struct Input: Decodable {
        var genre: String
        var trackIds: [String]
      }
      guard let input = try? JSONDecoder().decode(Input.self, from: args) else {
        return errorJSON("expected { genre, trackIds }")
      }
      let trimmed = input.genre.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return errorJSON("genre is empty") }
      guard !input.trackIds.isEmpty else { return errorJSON("trackIds is empty") }
      // Route through the controller's `addGenre(_:toSongs:)` so the
      // open detail pane / sidebar derivations / genre map re-load
      // (`reloadAfterGenreEdit`). The raw store call worked but left
      // the UI stale until the next refresh.
      let provider = controllerProvider
      let routed = await Task { @MainActor () -> Bool in
        guard let controller = provider() else { return false }
        await controller.addGenre(trimmed, toSongs: input.trackIds)
        return true
      }.value
      // We can't get a "rows changed" count back from the controller
      // path (it returns Void); count is best-effort via a fallback
      // store call only when the controller is unavailable. In the
      // routed case `tracksRequested` is the honest upper bound.
      let changed: Int =
        if routed {
          input.trackIds.count
        } else {
          (try? await store.addGenre(trimmed, toSongIDs: input.trackIds)) ?? 0
        }
      return encodeJSON(.object([
        "genre": .string(trimmed),
        "tracksRequested": .number(Double(input.trackIds.count)),
        "tracksChanged": .number(Double(changed)),
        "skipped": .number(Double(max(0, input.trackIds.count - changed))),
      ]))
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  /// Globally rename a genre tag across every song that carries it.
  /// Renaming onto an existing tag merges them (dedupe-on-write). Pure
  /// SQLite, no MusicKit. Returns rows changed.
  private static func renameGenre(
    store: LibraryStore?,
    controllerProvider: @escaping ControllerProvider,
  ) -> ToolDefinition {
    let schema = JSONSchemaToolDefinition(
      name: "rename_genre",
      description: """
        Globally rename a genre tag across the whole library. Every \
        song carrying `from` ends up carrying `to`. If `to` is already \
        present on a song, the two collapse to one (merge). Use \
        `add_genre_to_tracks` for non-global tagging.
        """,
      parameters: objectSchema(
        properties: [
          "from": stringSchema("Existing genre tag to rewrite."),
          "to": stringSchema("New tag — may already exist (merges)."),
        ],
        required: ["from", "to"],
      ),
    )
    let runner = ClosureToolRunner { [store] args in
      guard let store else { return errorJSON("library is unavailable") }
      struct Input: Decodable {
        var from: String
        var to: String
      }
      guard let input = try? JSONDecoder().decode(Input.self, from: args) else {
        return errorJSON("expected { from, to }")
      }
      let from = input.from.trimmingCharacters(in: .whitespacesAndNewlines)
      let to = input.to.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !from.isEmpty, !to.isEmpty else { return errorJSON("from/to is empty") }
      // Route through the controller's `renameGenreTag(from:to:)`
      // (newly file-public) so the genre map / sidebar derivations /
      // open detail pane all re-load via `reloadAfterGenreEdit`.
      let provider = controllerProvider
      let routed = await Task { @MainActor () -> Bool in
        guard let controller = provider() else { return false }
        await controller.renameGenreTag(from: from, to: to)
        return true
      }.value
      let changed: Int =
        if routed {
          // Controller path doesn't return a count; we lose the
          // honest "rows changed" number for the routed case. Return
          // `-1` as a sentinel — caller can ignore.
          -1
        } else {
          (try? await store.renameGenre(from: from, to: to)) ?? 0
        }
      return encodeJSON(.object([
        "from": .string(from),
        "to": .string(to),
        "tracksChanged": .number(Double(changed)),
      ]))
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  /// Read-only SQL against `library.sqlite`. Statements must start with
  /// `SELECT` or `WITH` (a CTE that yields a final `SELECT`); anything
  /// else is rejected up-front, and the call runs inside GRDB's
  /// `dbQueue.read` block which prevents writes at the engine level.
  /// Multiple statements (semicolon-separated) are also rejected.
  ///
  /// Schema hint: the main tables are `song(id, music_item_id, \
  /// id_namespace, title, artist_name, album_title, duration, \
  /// genre_names /* JSON array */, local_id, …)`, `apple_playlist(id, \
  /// name, …)`, `apple_playlist_track(playlist_id, song_id, position)`, \
  /// `app_playlist(id, name, …)`, `app_playlist_track(playlist_id, \
  /// song_id, position)`, `song_stat(song_local_id PK, play_count, \
  /// skip_count, last_played_at)`, `play_history(song_local_id, \
  /// played_at, sequence)`, `song_genre(song_id, genre)` (materialised \
  /// view), `genre_node`, `genre_edge_evidence`. For full DDL, run \
  /// `SELECT sql FROM sqlite_master WHERE type IN ('table', 'view') \
  /// ORDER BY name`.
  private static func sqlQuery(store: LibraryStore?) -> ToolDefinition {
    let schema = JSONSchemaToolDefinition(
      name: "sql_query",
      description: """
        Run a read-only SQL SELECT against the library database \
        (library.sqlite). Statements must start with SELECT or WITH; \
        INSERT / UPDATE / DELETE / DDL are rejected, and the read \
        block enforces this at the engine level too. Multiple \
        statements (semicolon-separated) are not allowed. Results are \
        capped at 200 rows with `truncated: true` past that.

        Main tables: `song` (id, music_item_id, id_namespace, title, \
        artist_name, album_title, duration, genre_names JSON, \
        local_id, …), `apple_playlist`, `apple_playlist_track`, \
        `app_playlist`, `app_playlist_track`, `song_stat` (per-song \
        play_count / skip_count / last_played_at), `play_history`, \
        `song_genre` (materialised view of song↔genre), `genre_node`, \
        `genre_edge_evidence`. For full DDL run \
        `SELECT sql FROM sqlite_master WHERE type IN ('table','view') \
        ORDER BY name`.
        """,
      parameters: objectSchema(
        properties: [
          "query": stringSchema("SELECT (or WITH … SELECT) SQL statement.")
        ],
        required: ["query"],
      ),
    )
    let runner = ClosureToolRunner { [store] args in
      guard let store else { return errorJSON("library is unavailable") }
      struct Input: Decodable { var query: String }
      guard let input = try? JSONDecoder().decode(Input.self, from: args) else {
        return errorJSON("expected { query }")
      }
      let trimmed = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
      if let violation = validateSelectOnly(trimmed) {
        return errorJSON(violation)
      }
      do {
        let result = try await store.database.dbQueue.read { db -> (rows: [JSONValue], columns: [String], truncated: Bool) in
          let rows = try Row.fetchAll(db, sql: trimmed)
          let capped = Array(rows.prefix(sqlRowCap))
          let columns: [String] = capped.first.map { Array($0.columnNames) } ?? []
          let payload = capped.map { row -> JSONValue in
            var dict = [String: JSONValue]()
            for name in row.columnNames {
              dict[name] = jsonValue(from: row[name] as DatabaseValue)
            }
            return .object(dict)
          }
          return (payload, columns, rows.count > sqlRowCap)
        }
        return encodeJSON(.object([
          "columns": .array(result.columns.map { .string($0) }),
          "rows": .array(result.rows),
          "rowCount": .number(Double(result.rows.count)),
          "truncated": .bool(result.truncated),
        ]))
      } catch {
        return errorJSON("sql failed: \(error.localizedDescription)")
      }
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  /// Snapshot of the UI: currently-selected playlist, currently-playing
  /// song, and the playlist context backing the queue. Cheap O(1)
  /// reads against `MusicController`. Useful when the user says "play
  /// this" / "tag this" without an id — the model can grab the
  /// current state instead of guessing.
  private static func appState(
    controllerProvider: @escaping ControllerProvider
  ) -> ToolDefinition {
    let schema = JSONSchemaToolDefinition(
      name: "app_state",
      description: """
        Return what's selected + what's playing right now. Useful when \
        the user refers to "this playlist" / "this song" / "what's \
        currently playing" — read the state instead of asking. Empty \
        sections are returned as `null` so a closed app or an idle \
        player don't break decoding.
        """,
      parameters: objectSchema(properties: [:]),
    )
    let runner = ClosureToolRunner { _ in
      let provider = controllerProvider
      let snapshot = await Task { @MainActor in
        guard let controller = provider() else { return AppStateSnapshot.empty }
        var state = AppStateSnapshot.empty
        if
          let id = controller.selectedPlaylistID,
          let summary = controller.selectedSummary
        {
          state.selectedPlaylist = .init(
            id: id,
            name: summary.name,
            source: summary.source == .appPlaylist ? "app" : "library",
          )
        }
        let snapshot = controller.playback.snapshot
        if
          let title = snapshot.title, !title.isEmpty
        {
          state.nowPlaying = .init(
            songId: controller.currentStoredSongID,
            title: title,
            artist: snapshot.artist,
            playlistId: snapshot.playlistContextID,
          )
        }
        return state
      }.value
      return encodeJSON(snapshot.json)
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  /// Append (or insert) tracks into the in-memory Up Next queue. The
  /// queue dominates playback — when the current song ends or the user
  /// hits Next, the queue head plays before falling through to the
  /// active playlist. Track ids resolve via `store.songs(byIDs:)` (one
  /// batched fetch, never per-row); any id that doesn't resolve is
  /// silently dropped + reflected in `added`. If EVERY id was invalid
  /// the whole call errors so the model knows it accomplished nothing.
  private static func upNextAdd(
    store: LibraryStore?,
    controllerProvider: @escaping ControllerProvider,
  ) -> ToolDefinition {
    let schema = JSONSchemaToolDefinition(
      name: "up_next_add",
      description: """
        Append tracks to the Up Next queue — a transient in-memory \
        queue that plays one track at a time and PREEMPTS the active \
        playlist (every Next press / song-end drains the queue head \
        first). Track ids come from `search_apple_music`, \
        `playlist_contents`, or `recently_played`. Pass `position` \
        (1-based) to insert at a specific slot; omit it to append. \
        Use this — NOT `play_track` / `play_playlist` — when the user \
        wants to queue something up to play next or "play more like \
        X" without disturbing the current playlist queue. Returns \
        `{ added, count }` where `added` is how many ids resolved \
        (silently skipped if missing) and `count` is the post-add \
        queue length.
        """,
      parameters: objectSchema(
        properties: [
          "trackIds": arraySchema(
            of: .object(["type": .string("string")]),
            description: "Internal song ids to enqueue, in order.",
          ),
          "position": .object([
            "type": .string("integer"),
            "description": .string("""
              Optional 1-based insert position. Omit to append to the tail; \
              `1` pushes to the head. Clamped to `[1, count + 1]`.
              """),
          ]),
        ],
        required: ["trackIds"],
      ),
    )
    let runner = ClosureToolRunner { [store] args in
      guard let store else { return errorJSON("library is unavailable") }
      struct Input: Decodable {
        var trackIds: [String]
        var position: Int?
      }
      guard let input = try? JSONDecoder().decode(Input.self, from: args) else {
        return errorJSON("expected { trackIds }")
      }
      guard !input.trackIds.isEmpty else {
        return errorJSON("trackIds is empty")
      }
      // Pre-resolve so we can tell "model gave us all junk" from "we
      // appended something". The controller funnel re-does this work
      // internally, but a second batched read on a ~10-row queue is
      // free + lets us reject the whole call when nothing resolves.
      let resolved: Int
      do {
        let songs = try await store.songs(byIDs: input.trackIds)
        let ids = Set(songs.map(\.id))
        resolved = input.trackIds.reduce(into: 0) { ids.contains($1) ? $0 += 1 : () }
      } catch {
        return errorJSON("lookup failed: \(error.localizedDescription)")
      }
      guard resolved > 0 else {
        return errorJSON("none of the supplied trackIds matched a song")
      }
      let provider = controllerProvider
      let trackIDs = input.trackIds
      let insertAt = input.position
      let count: Int? = await Task { @MainActor () -> Int? in
        guard let controller = provider() else { return nil }
        await controller.addToUpNext(songIDs: trackIDs, insertAt: insertAt)
        return controller.upNext.count
      }.value
      guard let count else {
        return errorJSON("controller unavailable")
      }
      return encodeJSON(.object([
        "added": .number(Double(resolved)),
        "count": .number(Double(count)),
      ]))
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  /// Return the current Up Next queue length. O(1) read.
  private static func upNextCount(
    controllerProvider: @escaping ControllerProvider
  ) -> ToolDefinition {
    let schema = JSONSchemaToolDefinition(
      name: "up_next_count",
      description: """
        Return how many tracks are currently in the Up Next queue. \
        Use this when you only need the size — to confirm the queue \
        is empty, to check whether adding more makes sense — rather \
        than dragging back the contents.
        """,
      parameters: objectSchema(properties: [:]),
    )
    let runner = ClosureToolRunner { _ in
      let provider = controllerProvider
      let count: Int? = await Task { @MainActor () -> Int? in
        guard let controller = provider() else { return nil }
        return controller.upNext.count
      }.value
      guard let count else {
        return errorJSON("controller unavailable")
      }
      return encodeJSON(.object([
        "count": .number(Double(count))
      ]))
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  /// Read a 1-based-inclusive slice of the Up Next queue. Out-of-range
  /// / swapped args collapse to an empty list; `total` always reflects
  /// the un-truncated range size so the model can ask for more.
  private static func upNextGet(
    controllerProvider: @escaping ControllerProvider
  ) -> ToolDefinition {
    let schema = JSONSchemaToolDefinition(
      name: "up_next_get",
      description: """
        Return a slice of the Up Next queue, 1-based inclusive on both \
        ends (`start = 1, end = 10` returns positions 1 through 10). \
        Each entry carries `{ position, songId, title, artist, album }`. \
        Capped at 200 entries per call; `truncated: true` past that, \
        and `total` reports the un-truncated range size.
        """,
      parameters: objectSchema(
        properties: [
          "start": .object([
            "type": .string("integer"),
            "description": .string("First position to return (1-based, inclusive)."),
          ]),
          "end": .object([
            "type": .string("integer"),
            "description": .string("Last position to return (1-based, inclusive)."),
          ]),
        ],
        required: ["start", "end"],
      ),
    )
    let runner = ClosureToolRunner { args in
      struct Input: Decodable {
        var start: Int
        var end: Int
      }
      guard let input = try? JSONDecoder().decode(Input.self, from: args) else {
        return errorJSON("expected { start, end }")
      }
      let provider = controllerProvider
      let result: (entries: [JSONValue], total: Int, truncated: Bool)? = await Task {
        @MainActor () -> (entries: [JSONValue], total: Int, truncated: Bool)? in
        guard let controller = provider() else { return nil }
        let slice = controller.upNext.range(input.start, input.end)
        let total = slice.count
        let capped = Array(slice.prefix(playlistTrackCap))
        let startBase = max(input.start, 1)
        let rows = capped.enumerated().map { offset, entry -> JSONValue in
          .object([
            "position": .number(Double(startBase + offset)),
            "songId": .string(entry.song.id),
            "title": .string(entry.song.title),
            "artist": .string(entry.song.artistName),
            "album": .string(entry.song.albumTitle ?? ""),
          ])
        }
        return (rows, total, total > playlistTrackCap)
      }.value
      guard let result else {
        return errorJSON("controller unavailable")
      }
      return encodeJSON(.object([
        "entries": .array(result.entries),
        "total": .number(Double(result.total)),
        "truncated": .bool(result.truncated),
      ]))
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  /// Remove tracks from the Up Next queue by 1-based position. ANY
  /// invalid position rejects the WHOLE call (no partial application);
  /// the model gets a clean error and can retry with a corrected
  /// list rather than guess what landed.
  private static func upNextRemove(
    controllerProvider: @escaping ControllerProvider
  ) -> ToolDefinition {
    let schema = JSONSchemaToolDefinition(
      name: "up_next_remove",
      description: """
        Remove tracks from the Up Next queue by 1-based position. If \
        ANY supplied position is out of range or duplicated the WHOLE \
        call errors and nothing is removed (no partial application) — \
        check `up_next_count` first or include only positions you \
        know are live. Returns `{ removed, count }` where `count` is \
        the post-remove queue length.
        """,
      parameters: objectSchema(
        properties: [
          "positions": arraySchema(
            of: .object(["type": .string("integer")]),
            description: "1-based positions to remove. Must all be in range.",
          )
        ],
        required: ["positions"],
      ),
    )
    let runner = ClosureToolRunner { args in
      struct Input: Decodable { var positions: [Int] }
      guard let input = try? JSONDecoder().decode(Input.self, from: args) else {
        return errorJSON("expected { positions }")
      }
      guard !input.positions.isEmpty else {
        return errorJSON("positions is empty")
      }
      let positions = input.positions
      if Set(positions).count != positions.count {
        return errorJSON("positions contains duplicates")
      }
      let provider = controllerProvider
      let outcome: (removed: Int, count: Int, error: String?) = await Task {
        @MainActor () -> (removed: Int, count: Int, error: String?) in
        guard let controller = provider() else {
          return (0, 0, "controller unavailable")
        }
        let total = controller.upNext.count
        let valid = 1...total
        if total == 0 {
          return (0, 0, "Up Next queue is empty")
        }
        for position in positions where !valid.contains(position) {
          return (0, total, "position \(position) is out of range (1...\(total))")
        }
        controller.removeFromUpNext(positions: positions)
        return (positions.count, controller.upNext.count, nil)
      }.value
      if let error = outcome.error {
        return errorJSON(error)
      }
      return encodeJSON(.object([
        "removed": .number(Double(outcome.removed)),
        "count": .number(Double(outcome.count)),
      ]))
    }
    return ToolDefinition(schema: schema, runner: runner)
  }

  /// Pre-flight validate a SQL string for the read-only tool. Returns
  /// a human-readable reason for rejection, or `nil` if it looks safe
  /// at the textual level (GRDB's `read` block is the second line of
  /// defence at the engine level).
  private static func validateSelectOnly(_ raw: String) -> String? {
    guard !raw.isEmpty else { return "query is empty" }
    // Reject multiple statements. SQLite accepts `;` only as a
    // separator; allow a single trailing `;` for convenience.
    let collapsed = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r;"))
    if collapsed.contains(";") {
      return "multiple statements are not allowed"
    }
    let upper = collapsed.uppercased()
    let prefix = upper.prefix { !$0.isWhitespace }
    guard prefix == "SELECT" || prefix == "WITH" else {
      return "only SELECT or WITH … SELECT statements are allowed"
    }
    // Defence-in-depth: forbid a handful of write/attach verbs that
    // would otherwise sneak past the prefix check via comments + the
    // engine. GRDB's `read` block also blocks them; this gives a
    // cleaner error message before round-tripping to SQLite.
    let banned = [
      "INSERT ",
      "UPDATE ",
      "DELETE ",
      "DROP ",
      "ALTER ",
      "CREATE ",
      "ATTACH ",
      "DETACH ",
      "REPLACE ",
      "PRAGMA ",
      "VACUUM",
    ]
    for keyword in banned where upper.contains(keyword) {
      return "write/DDL keywords are not allowed (\(keyword.trimmingCharacters(in: .whitespaces)))"
    }
    return nil
  }

  /// Convert a GRDB `DatabaseValue` to our `JSONValue` carrier. Nil
  /// → `.null`, integers/doubles → `.number`, strings → `.string`,
  /// blobs → base64 strings (rare; safest neutral encoding).
  private static func jsonValue(from db: DatabaseValue) -> JSONValue {
    switch db.storage {
    case .null:
      .null

    case .int64(let value):
      .number(Double(value))

    case .double(let value):
      .number(value)

    case .string(let value):
      .string(value)

    case .blob(let data):
      .string(data.base64EncodedString())
    }
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
