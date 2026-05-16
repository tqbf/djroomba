import Foundation

/// Derived UI projection of MusicKit player state. MusicKit owns the real
/// playback/queue state; this is a read snapshot the now-playing bar binds
/// to. It carries no live MusicKit objects (local-first pivot): artwork is
/// re-resolved from the now-playing id and ids are raw strings, so the
/// snapshot is a plain `Sendable` value.
struct PlayerStateSnapshot: Sendable {
  enum Status: Sendable, Equatable {
    case stopped
    case playing
    case paused
    case interrupted
    case seekingForward
    case seekingBackward
  }

  var status = Status.stopped
  var title: String?
  var artist: String?
  var elapsed: TimeInterval = 0
  var duration: TimeInterval?
  /// App-local context: which playlist playback was started from, if known.
  var playlistContextID: String?
  /// `MusicItemID.rawValue` of the now-playing item, if known.
  var nowPlayingItemID: String?
  /// The **structural** position of the playing entry within the player's
  /// queue: the ordinal of `queue.currentEntry` among `queue.entries`,
  /// matched by the queue `Entry`'s own `id` (the queue's per-position
  /// structural handle MusicKit mints when it builds the queue — NOT the
  /// song's catalog/library `MusicItemID`). `nil` when it can't be
  /// determined (no current entry / entry absent from `entries`). This is
  /// the Phase-2 enabler: it indexes the resolver's canonical play context
  /// (our `song.id`s) by position, so "which stored song is playing now"
  /// needs zero Apple-id translation (see `plans/play-statistics.md`).
  var queueIndex: Int?

  var hasContent: Bool {
    title != nil
  }

  var isPlaying: Bool {
    status == .playing
  }

  /// Re-resolvable artwork for the now-playing item (D2). The player
  /// resolves library Songs (provenance `.library`), so the now-playing id
  /// re-resolves the same way every other thumbnail does.
  var artworkRef: ArtworkRef? {
    guard let nowPlayingItemID, !nowPlayingItemID.isEmpty else { return nil }
    return .song(nowPlayingItemID, namespace: .library)
  }
}
