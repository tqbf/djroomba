# Data layer & import pipeline

Local-first. SQLite via **GRDB** is the source of truth. Apple Music is a
one-way import source + the playback engine. No write-back to Apple.

## Why GRDB

Mature, SQLite-native (real SQL + schema migrations), value-type records
(`FetchableRecord`/`PersistableRecord`/`Codable`), `DatabaseQueue`/`Pool` with
async APIs and Swift-6 concurrency support, `ValueObservation` for live UI.
Chosen over: SQLite.swift (thinner, less migration tooling), raw `sqlite3`
(too much boilerplate), SwiftData (hides SQL — wrong fit for "I own the DB").

Added via SPM through XcodeGen (`project.yml`):

```yaml
packages:
  GRDB:
    url: https://github.com/groue/GRDB.swift
    from: "7.0.0"
targets:
  DJRoomba:
    dependencies:
      - package: GRDB
```

DB file: `Application Support/DJRoomba/library.sqlite` (sandbox-safe;
`URL.applicationSupportDirectory`). Schema versioned with
`DatabaseMigrator`; every change is a new named migration (never edit old).

## Schema (initial sketch — refine in M3)

Identifiers: store the MusicKit `MusicItemID` raw string **and** which
namespace it is (`library` vs `catalog`) so `PlaybackResolver` knows how to
re-fetch. Never assume the two id spaces are interchangeable.

```
song(
  id TEXT PRIMARY KEY,            -- app-stable uuid
  music_item_id TEXT NOT NULL,    -- MusicItemID rawValue
  id_namespace TEXT NOT NULL,     -- 'library' | 'catalog'
  title TEXT NOT NULL,
  artist_name TEXT NOT NULL,
  album_title TEXT,
  duration REAL,                  -- seconds, nullable
  is_explicit INTEGER NOT NULL DEFAULT 0,
  artwork_url TEXT,               -- resolved/cached, nullable
  imported_at REAL NOT NULL,
  UNIQUE(music_item_id, id_namespace)
)

apple_playlist(                   -- read snapshot of an imported Apple list
  id TEXT PRIMARY KEY,            -- MusicItemID rawValue (library)
  name TEXT NOT NULL,
  artwork_url TEXT,
  curator TEXT,
  last_imported_at REAL NOT NULL
)
apple_playlist_track(apple_playlist_id TEXT, song_id TEXT, position INTEGER,
                     PRIMARY KEY(apple_playlist_id, position))

app_playlist(                     -- user-created, SQLite-only
  id TEXT PRIMARY KEY,            -- app uuid
  name TEXT NOT NULL,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL,
  sort_index INTEGER NOT NULL
)
app_playlist_track(app_playlist_id TEXT, song_id TEXT, position INTEGER,
                    PRIMARY KEY(app_playlist_id, position))

play_event(song_id TEXT, played_at REAL)         -- one row per play
song_stat(song_id TEXT PRIMARY KEY,              -- denormalized for sort/UI
          play_count INTEGER NOT NULL DEFAULT 0,
          last_played_at REAL)

favorite_playlist(playlist_id TEXT PRIMARY KEY,  -- apple or app id
                  source TEXT NOT NULL)          -- 'apple' | 'app'
recent_playlist(playlist_id TEXT PRIMARY KEY, source TEXT, played_at REAL)
```

`play_count`/`last_played_at` maintained from `play_event` (trigger or in the
write that records a play). Favorites/recents replace the UserDefaults stores.

## ImportService (MusicKit → SQLite, one-way)

- Read library playlists via `MusicLibraryRequest<Playlist>` (paged, as M1).
- For each, lazily fetch tracks (`playlist.with([.tracks])`, paged).
- Upsert songs (dedupe on `(music_item_id, id_namespace)`), replace the
  `apple_playlist` + its `apple_playlist_track` rows transactionally.
- Incremental + manual (⌘R). Full re-import is acceptable for v1 (volumes are
  modest); optimize later only if needed.
- Pure import — never deletes app playlists or play stats.

## PlaybackResolver (SQLite id → playable MusicKit item)

At play time, take the song rows for the queue, group by `id_namespace`, batch
re-fetch: `MusicLibraryRequest`/`MusicCatalogResourceRequest` filtered by
`MusicItemID`, then build `ApplicationMusicPlayer.Queue(for:)` /
`(for:startingAt:)` (same player code as M1). Record a `play_event` for the
starting track when playback actually begins.

## Concurrency

- `LibraryStore` wraps a GRDB `DatabaseQueue`; DB work via `try await
  dbQueue.read/write { }` off the main actor. GRDB types are Sendable-aware.
- `MusicController` stays `@MainActor @Observable`; it `await`s store calls and
  republishes results as observable state. `ValueObservation` may drive live
  sidebar updates later; start with explicit reload after import.
- Strict Swift 6 concurrency retained; same `nonisolated(unsafe)` note for
  `ApplicationMusicPlayer` applies (see `plans/musickit-notes.md`).

## Migration from M1/M2

Favorites/recents currently in UserDefaults: on first M3 launch, migrate any
existing values into the new tables, then stop using the UserDefaults keys
(leave a one-shot migration; don't keep dual writes).
