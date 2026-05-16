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

  @Test
  func `any summaries always wins regardless of cause`() {
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
      cloudLibraryEnabled: false,
    )
    #expect(state == .populated)
  }

  @Test
  func `hard error beats everything else`() {
    let state = LibrarySidebarState.resolve(
      hasAnySummaries: false,
      hasImportedPlaylists: false,
      isBusy: true, // even mid-import, a real error surfaces
      problem: "The local library database could not be opened.",
      subscriptionLoaded: false,
      canPlayCatalog: false,
      canBecomeSubscriber: false,
      cloudLibraryEnabled: true,
    )
    #expect(state == .error("The local library database could not be opened."))
  }

  @Test
  func `busy shows loading when no error and nothing yet`() {
    let state = LibrarySidebarState.resolve(
      hasAnySummaries: false,
      hasImportedPlaylists: false,
      isBusy: true,
      problem: nil,
      subscriptionLoaded: false,
      canPlayCatalog: false,
      canBecomeSubscriber: false,
      cloudLibraryEnabled: true,
    )
    #expect(state == .loading)
  }

  @Test
  func `cloud library off is distinguished from empty`() {
    // Sync Library off → MusicKit genuinely has no on-device library.
    let state = LibrarySidebarState.resolve(
      hasAnySummaries: false,
      hasImportedPlaylists: false,
      isBusy: false,
      problem: nil,
      subscriptionLoaded: true,
      canPlayCatalog: true,
      canBecomeSubscriber: false,
      cloudLibraryEnabled: false,
    )
    #expect(state == .libraryNotSynced)
  }

  @Test
  func `not synced takes precedence over subscription prompt`() {
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
      cloudLibraryEnabled: false,
    )
    #expect(state == .libraryNotSynced)
  }

  @Test
  func `subscription needed when synced but not entitled and can subscribe`() {
    let state = LibrarySidebarState.resolve(
      hasAnySummaries: false,
      hasImportedPlaylists: false,
      isBusy: false,
      problem: nil,
      subscriptionLoaded: true,
      canPlayCatalog: false,
      canBecomeSubscriber: true,
      cloudLibraryEnabled: true,
    )
    #expect(state == .subscriptionNeeded)
  }

  @Test
  func `no imported playlists when synced and entitled but empty`() {
    let state = LibrarySidebarState.resolve(
      hasAnySummaries: false,
      hasImportedPlaylists: false,
      isBusy: false,
      problem: nil,
      subscriptionLoaded: true,
      canPlayCatalog: true,
      canBecomeSubscriber: false,
      cloudLibraryEnabled: true,
    )
    #expect(state == .noImportedPlaylists)
  }

  @Test
  func `before subscription loads falls back to neutral no playlists`() {
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
      cloudLibraryEnabled: true,
    )
    #expect(state == .noImportedPlaylists)
  }

  @Test
  func `empty problem string is not treated as an error`() {
    let state = LibrarySidebarState.resolve(
      hasAnySummaries: false,
      hasImportedPlaylists: false,
      isBusy: false,
      problem: "",
      subscriptionLoaded: true,
      canPlayCatalog: true,
      canBecomeSubscriber: false,
      cloudLibraryEnabled: true,
    )
    #expect(state == .noImportedPlaylists)
  }
}
