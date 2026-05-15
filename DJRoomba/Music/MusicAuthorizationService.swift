import MusicKit
import Observation

/// Wraps `MusicAuthorization`. Maps to the spec's auth states; the
/// "authorized but no usable playlists" / "authorized but no playback" cases
/// are resolved at the controller level (they need library/subscription info).
@MainActor
@Observable
final class MusicAuthorizationService {
    private(set) var status: MusicAuthorization.Status = MusicAuthorization.currentStatus

    func refresh() {
        status = MusicAuthorization.currentStatus
    }

    func request() async {
        status = await MusicAuthorization.request()
    }
}
