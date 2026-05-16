import MusicKit
import Observation

/// Observes Apple Music subscription capability. The UI uses this to *explain*
/// disabled Play buttons rather than letting playback silently fail. Library
/// browsing still works without catalog playback.
@MainActor
@Observable
final class MusicSubscriptionService {
    private(set) var canPlayCatalogContent = false
    private(set) var canBecomeSubscriber = false
    /// Whether the system Apple Account has Cloud / Sync Library enabled.
    /// This is the signal that lets the empty-state logic distinguish
    /// "library isn't synced to this Mac" (cloud library off → MusicKit
    /// genuinely has nothing local) from "synced but you have no playlists"
    /// (Phase 5 smarter empty states; the risk register's "empty/failure
    /// modes are silent" item). Defaults `true` until subscription info has
    /// loaded so we never accuse a syncing library of being unsynced.
    private(set) var hasCloudLibraryEnabled = true
    private(set) var hasLoaded = false

    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await subscription in MusicSubscription.subscriptionUpdates {
                guard let self else { return }
                self.canPlayCatalogContent = subscription.canPlayCatalogContent
                self.canBecomeSubscriber = subscription.canBecomeSubscriber
                self.hasCloudLibraryEnabled = subscription.hasCloudLibraryEnabled
                self.hasLoaded = true
            }
        }
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
    }
}
