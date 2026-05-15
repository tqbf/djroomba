import Foundation

/// App-local, persisted metadata about a playlist. Music state stays with
/// Apple Music; this is purely app state. Mostly exercised in Milestone 2
/// (favorites, recents) — defined now so the boundary is stable.
struct UserPlaylistMetadata: Codable, Sendable {
    var isFavorite: Bool = false
    var lastPlayed: Date?
}
