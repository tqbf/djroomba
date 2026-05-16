import GRDB

/// Whether a favorite / recent entry points at an imported Apple playlist
/// (`apple_playlist`) or a user-owned one (`app_playlist`). Stored as the
/// raw string in SQLite so the value is self-describing in the DB and
/// stable across refactors.
///
/// This is intentionally a persistence-layer enum (distinct from the
/// UI-layer `PlaylistSource`): favorites/recents reference *two different
/// parent tables*, so a single FK can't express it; the discriminator
/// rides with the id instead.
enum PlaylistSourceKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case apple
    case app
}
