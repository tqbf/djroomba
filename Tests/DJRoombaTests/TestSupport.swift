import Foundation
@testable import DJRoomba

/// Shared helpers for the Phase 2 store/migration tests. Every test gets a
/// fresh in-memory DB (migrations applied) so cases are isolated and fast.
enum TestSupport {
    static func freshStore() throws -> LibraryStore {
        LibraryStore(database: try AppDatabase())
    }

    /// GRDB stores dates as text with millisecond precision, so a
    /// round-tripped `Date.now` differs from the original in the sub-ms
    /// digits. Compare stored timestamps with a tolerance.
    static func datesMatch(_ a: Date?, _ b: Date?, tolerance: TimeInterval = 0.01) -> Bool {
        switch (a, b) {
        case let (a?, b?): abs(a.timeIntervalSince(b)) <= tolerance
        case (nil, nil): true
        default: false
        }
    }

    static func sampleSong(
        id: String = UUID().uuidString,
        musicItemID: String,
        namespace: Song.IDNamespace = .library,
        title: String = "Untitled",
        artist: String = "Unknown Artist"
    ) -> Song {
        Song(
            id: id,
            musicItemID: musicItemID,
            idNamespace: namespace,
            title: title,
            artistName: artist,
            albumTitle: nil,
            duration: nil,
            isExplicit: false,
            artworkURL: nil,
            importedAt: .now
        )
    }
}
