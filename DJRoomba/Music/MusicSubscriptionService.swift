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
    private(set) var hasLoaded = false

    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await subscription in MusicSubscription.subscriptionUpdates {
                guard let self else { return }
                self.canPlayCatalogContent = subscription.canPlayCatalogContent
                self.canBecomeSubscriber = subscription.canBecomeSubscriber
                self.hasLoaded = true
            }
        }
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
    }
}
