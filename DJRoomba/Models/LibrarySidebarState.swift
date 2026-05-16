import Foundation

/// What the playlist sidebar should show, with the *cause* inferred — not just
/// "empty" but *why* it's empty, so the empty/error state can be honest and
/// specific (Phase 5; the risk register's "empty/failure modes are silent" —
/// MusicKit returns an empty collection rather than throwing for several
/// genuinely-different conditions, so we cross-check authorization /
/// subscription / cloud-library status to distinguish them).
///
/// Pure value computed by `resolve(...)` from inputs the controller already
/// owns, so the decision is unit-testable without a live MusicKit session and
/// stays out of the view `body` (swiftui-pro: logic in methods/types).
enum LibrarySidebarState: Equatable, Sendable {
    /// The library is being (re)populated — an Apple import is running or the
    /// store-backed sidebar is reloading. Show the progress affordance.
    case loading
    /// A store-open / migration / import error with a message + a retry.
    case error(String)
    /// Cloud / Sync Library is OFF for this Mac's Apple Account, so MusicKit
    /// genuinely has no on-device library to import. Distinct from "synced but
    /// empty" — the fix is a Music-settings toggle, not creating a playlist.
    case libraryNotSynced
    /// An active Apple Music subscription is needed (and the account *can*
    /// become a subscriber). Library browse may still be empty without one.
    case subscriptionNeeded
    /// Synced and entitled, but the imported library has no Apple playlists.
    /// "My Playlists" stays reachable so the create affordance still shows.
    case noImportedPlaylists
    /// There is content to show — render the populated list.
    case populated

    /// Decide what the sidebar should show. Inputs are exactly the signals the
    /// controller already tracks; ordering matters (most specific cause first).
    ///
    /// - `hasAnySummaries`: any imported OR app playlist exists.
    /// - `hasImportedPlaylists`: any *imported Apple* playlist exists.
    /// - `isBusy`: an import or store reload is in flight.
    /// - `problem`: a store/import/migration error string, if any.
    /// - `subscriptionLoaded` / `canPlayCatalog` / `canBecomeSubscriber` /
    ///   `cloudLibraryEnabled`: from `MusicSubscription` (the cross-check).
    static func resolve(
        hasAnySummaries: Bool,
        hasImportedPlaylists: Bool,
        isBusy: Bool,
        problem: String?,
        subscriptionLoaded: Bool,
        canPlayCatalog: Bool,
        canBecomeSubscriber: Bool,
        cloudLibraryEnabled: Bool
    ) -> LibrarySidebarState {
        // Anything to show wins — never nag a user who already has playlists
        // (e.g. they made an app playlist but never synced an Apple library).
        if hasAnySummaries { return .populated }

        // A hard failure (store couldn't open, import threw) needs its own
        // message + retry, regardless of subscription/cloud state.
        if let problem, !problem.isEmpty { return .error(problem) }

        // Still working — don't flash a cause before the import finishes.
        if isBusy { return .loading }

        // Now the genuinely-empty cases, most actionable cause first. Only
        // trust subscription/cloud signals once they've actually loaded;
        // before that, fall through to the neutral "no playlists yet".
        if subscriptionLoaded {
            if !cloudLibraryEnabled {
                // Sync Library off → MusicKit has no local library at all.
                return .libraryNotSynced
            }
            if !canPlayCatalog && canBecomeSubscriber {
                // No active subscription and the account could subscribe.
                return .subscriptionNeeded
            }
        }

        // Synced + entitled (or unknown) but no imported Apple playlists.
        return hasImportedPlaylists ? .populated : .noImportedPlaylists
    }
}
