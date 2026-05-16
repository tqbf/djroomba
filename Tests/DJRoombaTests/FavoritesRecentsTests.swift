import Foundation
import Testing
@testable import DJRoomba

/// Favorites & recents round-trip through SQLite (the replacement for the
/// UserDefaults stores).
struct FavoritesRecentsTests {
    @Test func favoriteToggleRoundTrips() async throws {
        let store = try TestSupport.freshStore()

        #expect(try await store.isFavorite(playlistID: "pl") == false)

        try await store.setFavorite(true, playlistID: "pl", source: .apple)
        #expect(try await store.isFavorite(playlistID: "pl") == true)

        // Idempotent set (PK) — still one row.
        try await store.setFavorite(true, playlistID: "pl", source: .apple)
        #expect(try await store.favorites().count == 1)

        try await store.setFavorite(false, playlistID: "pl", source: .apple)
        #expect(try await store.isFavorite(playlistID: "pl") == false)
        #expect(try await store.favorites().isEmpty)
    }

    @Test func favoritePreservesSourceKind() async throws {
        let store = try TestSupport.freshStore()
        try await store.setFavorite(true, playlistID: "apple-1", source: .apple)
        try await store.setFavorite(true, playlistID: "app-1", source: .app)

        let favorites = try await store.favorites()
        let bySource = Dictionary(uniqueKeysWithValues: favorites.map { ($0.playlistID, $0.source) })
        #expect(bySource["apple-1"] == .apple)
        #expect(bySource["app-1"] == .app)
    }

    @Test func recentsAreMostRecentFirstAndCapped() async throws {
        let store = try TestSupport.freshStore()

        try await store.recordRecent(playlistID: "a", source: .apple, at: Date(timeIntervalSince1970: 1))
        try await store.recordRecent(playlistID: "b", source: .apple, at: Date(timeIntervalSince1970: 2))
        try await store.recordRecent(playlistID: "c", source: .app, at: Date(timeIntervalSince1970: 3))

        let all = try await store.recentPlaylists()
        #expect(all.map(\.playlistID) == ["c", "b", "a"])

        let capped = try await store.recentPlaylists(limit: 2)
        #expect(capped.map(\.playlistID) == ["c", "b"])
    }

    @Test func replayingABumpsTimestampWithoutDuplicating() async throws {
        let store = try TestSupport.freshStore()
        try await store.recordRecent(playlistID: "x", source: .apple, at: Date(timeIntervalSince1970: 1))
        try await store.recordRecent(playlistID: "y", source: .apple, at: Date(timeIntervalSince1970: 2))
        // Re-play x more recently.
        try await store.recordRecent(playlistID: "x", source: .apple, at: Date(timeIntervalSince1970: 3))

        let all = try await store.recentPlaylists()
        #expect(all.count == 2, "re-playing must not duplicate a recent row")
        #expect(all.map(\.playlistID) == ["x", "y"])
    }
}
