import Foundation
import Testing
@testable import DJRoomba

/// Phase 5 smarter empty/error states. `LibrarySidebarState.resolve` is the
/// pure classifier that turns the signals the controller already tracks
/// (summaries / busy / problem / subscription / cloud-library) into the
/// *cause* the sidebar shows — so an empty library reads as "not synced to
/// this Mac" vs "needs a subscription" vs "no playlists yet" instead of a
/// blanket "empty" (the risk register's "empty/failure modes are silent").
/// Deterministic, so it is unit-tested here (the MusicKit signals themselves
/// are signed-run verification).
struct LibrarySidebarStateTests {

    @Test func anySummariesAlwaysWinsRegardlessOfCause() {
        // A user with an app playlist but no synced Apple library must NOT be
        // told the library isn't synced — they have content to show.
        let state = LibrarySidebarState.resolve(
            hasAnySummaries: true,
            hasImportedPlaylists: false,
            isBusy: false,
            problem: nil,
            subscriptionLoaded: true,
            canPlayCatalog: false,
            canBecomeSubscriber: true,
            cloudLibraryEnabled: false
        )
        #expect(state == .populated)
    }

    @Test func hardErrorBeatsEverythingElse() {
        let state = LibrarySidebarState.resolve(
            hasAnySummaries: false,
            hasImportedPlaylists: false,
            isBusy: true, // even mid-import, a real error surfaces
            problem: "The local library database could not be opened.",
            subscriptionLoaded: false,
            canPlayCatalog: false,
            canBecomeSubscriber: false,
            cloudLibraryEnabled: true
        )
        #expect(state == .error("The local library database could not be opened."))
    }

    @Test func busyShowsLoadingWhenNoErrorAndNothingYet() {
        let state = LibrarySidebarState.resolve(
            hasAnySummaries: false,
            hasImportedPlaylists: false,
            isBusy: true,
            problem: nil,
            subscriptionLoaded: false,
            canPlayCatalog: false,
            canBecomeSubscriber: false,
            cloudLibraryEnabled: true
        )
        #expect(state == .loading)
    }

    @Test func cloudLibraryOffIsDistinguishedFromEmpty() {
        // Sync Library off → MusicKit genuinely has no on-device library.
        let state = LibrarySidebarState.resolve(
            hasAnySummaries: false,
            hasImportedPlaylists: false,
            isBusy: false,
            problem: nil,
            subscriptionLoaded: true,
            canPlayCatalog: true,
            canBecomeSubscriber: false,
            cloudLibraryEnabled: false
        )
        #expect(state == .libraryNotSynced)
    }

    @Test func notSyncedTakesPrecedenceOverSubscriptionPrompt() {
        // Both "no subscription" and "cloud off" — the more fundamental cause
        // (no local library at all) is the one to surface first.
        let state = LibrarySidebarState.resolve(
            hasAnySummaries: false,
            hasImportedPlaylists: false,
            isBusy: false,
            problem: nil,
            subscriptionLoaded: true,
            canPlayCatalog: false,
            canBecomeSubscriber: true,
            cloudLibraryEnabled: false
        )
        #expect(state == .libraryNotSynced)
    }

    @Test func subscriptionNeededWhenSyncedButNotEntitledAndCanSubscribe() {
        let state = LibrarySidebarState.resolve(
            hasAnySummaries: false,
            hasImportedPlaylists: false,
            isBusy: false,
            problem: nil,
            subscriptionLoaded: true,
            canPlayCatalog: false,
            canBecomeSubscriber: true,
            cloudLibraryEnabled: true
        )
        #expect(state == .subscriptionNeeded)
    }

    @Test func noImportedPlaylistsWhenSyncedAndEntitledButEmpty() {
        let state = LibrarySidebarState.resolve(
            hasAnySummaries: false,
            hasImportedPlaylists: false,
            isBusy: false,
            problem: nil,
            subscriptionLoaded: true,
            canPlayCatalog: true,
            canBecomeSubscriber: false,
            cloudLibraryEnabled: true
        )
        #expect(state == .noImportedPlaylists)
    }

    @Test func beforeSubscriptionLoadsFallsBackToNeutralNoPlaylists() {
        // Don't accuse a still-loading subscription of being unsynced /
        // unentitled — degrade to the neutral, non-alarming cause.
        let state = LibrarySidebarState.resolve(
            hasAnySummaries: false,
            hasImportedPlaylists: false,
            isBusy: false,
            problem: nil,
            subscriptionLoaded: false,
            canPlayCatalog: false,
            canBecomeSubscriber: false,
            cloudLibraryEnabled: true
        )
        #expect(state == .noImportedPlaylists)
    }

    @Test func emptyProblemStringIsNotTreatedAsAnError() {
        let state = LibrarySidebarState.resolve(
            hasAnySummaries: false,
            hasImportedPlaylists: false,
            isBusy: false,
            problem: "",
            subscriptionLoaded: true,
            canPlayCatalog: true,
            canBecomeSubscriber: false,
            cloudLibraryEnabled: true
        )
        #expect(state == .noImportedPlaylists)
    }
}
