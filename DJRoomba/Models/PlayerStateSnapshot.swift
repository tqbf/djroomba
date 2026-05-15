import Foundation
import MusicKit

/// Derived UI projection of MusicKit player state. MusicKit owns the real
/// playback/queue state; this is a read snapshot the now-playing bar binds to.
struct PlayerStateSnapshot: Sendable {
    enum Status: Sendable {
        case stopped, playing, paused, interrupted, seekingForward, seekingBackward
    }

    var status: Status = .stopped
    var title: String?
    var artist: String?
    var artwork: Artwork?
    var elapsed: TimeInterval = 0
    var duration: TimeInterval?
    /// App-local context: which playlist playback was started from, if known.
    var playlistContextID: MusicItemID?
    var nowPlayingItemID: MusicItemID?

    var hasContent: Bool { title != nil }
    var isPlaying: Bool { status == .playing }
}
