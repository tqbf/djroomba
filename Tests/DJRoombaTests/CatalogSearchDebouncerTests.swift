import Foundation
import Testing
@testable import DJRoomba

/// Phase 2 (`plans/catalog-playlists.md`): the pure decider for the catalog
/// search debounce/dispatch policy. **No async, no Task.sleep, no time
/// measurement** — the decider is a total function from inputs to a
/// `SearchDecision`, and that is what we cover. The view layer's
/// `.task(id: query)` + `Task.sleep(for:)` wiring is a separate concern
/// not exercised here (and not testable as a pure decider would be).
///
/// Invariants pinned (one per test):
///
/// 1. An empty (or whitespace-only) query clears, regardless of elapsed.
/// 2. A query shorter than `minLength` waits — DOES NOT clear (mid-type).
/// 3. A query equal to `lastFiredTerm` waits, even after the debounce
///    window has elapsed (no-op re-fire is worthless).
/// 4. A long-enough new query past the debounce window fires.
/// 5. A long-enough new query within the debounce window waits.
/// 6. Trimming: leading/trailing whitespace is normalized — the fired
///    term is the trimmed string, and a whitespace-padded duplicate of
///    `lastFiredTerm` still suppresses a fire.
@Suite("Catalog search debouncer (Phase 2)")
struct CatalogSearchDebouncerTests {

  @Test("an empty query is always a clear")
  func emptyQueryClears() {
    #expect(
      CatalogSearchDebouncer.decision(
        for: "",
        lastFiredTerm: nil,
        elapsedSinceLastInputMS: 0,
      ) == .clear,
    )
    // Whitespace-only is "empty" per the trim rule.
    #expect(
      CatalogSearchDebouncer.decision(
        for: "   ",
        lastFiredTerm: "queen",
        elapsedSinceLastInputMS: 10000,
      ) == .clear,
    )
  }

  @Test("a below-minLength query waits (does NOT clear — user is mid-type)")
  func belowMinLengthWaits() {
    // Default minLength = 2.
    #expect(
      CatalogSearchDebouncer.decision(
        for: "q",
        lastFiredTerm: nil,
        elapsedSinceLastInputMS: 1000,
      ) == .wait,
    )
    // Explicit minLength of 3 also waits at 2 chars.
    #expect(
      CatalogSearchDebouncer.decision(
        for: "qu",
        lastFiredTerm: nil,
        elapsedSinceLastInputMS: 1000,
        minLength: 3,
      ) == .wait,
    )
  }

  @Test("the same query as last fired waits — even after the debounce window")
  func sameAsLastFiredWaits() {
    // 10s elapsed, well past the 250 ms debounce, but the query is
    // unchanged → re-firing the same request gains nothing and burns
    // rate. Wait.
    #expect(
      CatalogSearchDebouncer.decision(
        for: "queen",
        lastFiredTerm: "queen",
        elapsedSinceLastInputMS: 10000,
      ) == .wait,
    )
  }

  @Test("an above-minLength new query past the debounce fires")
  func longEnoughPastDebounceFires() {
    #expect(
      CatalogSearchDebouncer.decision(
        for: "queen",
        lastFiredTerm: nil,
        elapsedSinceLastInputMS: 250,
      ) == .fire("queen"),
    )
    // Different lastFired (the user changed the term) — also fires.
    #expect(
      CatalogSearchDebouncer.decision(
        for: "queen II",
        lastFiredTerm: "queen",
        elapsedSinceLastInputMS: 500,
      ) == .fire("queen II"),
    )
  }

  @Test("an above-minLength new query within the debounce window waits")
  func longEnoughWithinDebounceWaits() {
    // 100 ms elapsed, default 250 ms debounce → wait.
    #expect(
      CatalogSearchDebouncer.decision(
        for: "queen",
        lastFiredTerm: nil,
        elapsedSinceLastInputMS: 100,
      ) == .wait,
    )
    // Even with a different lastFired, the elapsed gate holds.
    #expect(
      CatalogSearchDebouncer.decision(
        for: "queen II",
        lastFiredTerm: "queen",
        elapsedSinceLastInputMS: 249,
      ) == .wait,
    )
  }

  @Test("leading/trailing whitespace is normalized (trimmed for fire + dedupe)")
  func whitespaceIsTrimmed() {
    // Fired term is the trimmed string, not the raw input.
    #expect(
      CatalogSearchDebouncer.decision(
        for: "  queen  ",
        lastFiredTerm: nil,
        elapsedSinceLastInputMS: 500,
      ) == .fire("queen"),
    )
    // Whitespace-padded duplicate of lastFired still suppresses.
    #expect(
      CatalogSearchDebouncer.decision(
        for: "  queen  ",
        lastFiredTerm: "queen",
        elapsedSinceLastInputMS: 500,
      ) == .wait,
    )
  }

  @Test("custom debounceMS / minLength values are honored")
  func customParametersHonored() {
    // 500 ms debounce, 3-char minimum.
    #expect(
      CatalogSearchDebouncer.decision(
        for: "qu",
        lastFiredTerm: nil,
        elapsedSinceLastInputMS: 1000,
        minLength: 3,
        debounceMS: 500,
      ) == .wait,
    )
    #expect(
      CatalogSearchDebouncer.decision(
        for: "queen",
        lastFiredTerm: nil,
        elapsedSinceLastInputMS: 400,
        minLength: 3,
        debounceMS: 500,
      ) == .wait,
    )
    #expect(
      CatalogSearchDebouncer.decision(
        for: "queen",
        lastFiredTerm: nil,
        elapsedSinceLastInputMS: 500,
        minLength: 3,
        debounceMS: 500,
      ) == .fire("queen"),
    )
  }

}
