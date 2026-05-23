import Testing
@testable import DJRoomba

/// `GenreEdit` — the pure rename/add transforms. The merge correctness
/// lives here (no DB): rename rewrites + de-dupes preserving order, and
/// returns nil when nothing changes so the store writes only changed rows.
struct GenreEditTests {

  @Test
  func `rename rewrites the matching tag`() {
    #expect(GenreEdit.renaming(["Rok", "Pop"], from: "Rok", to: "Rock") == ["Rock", "Pop"])
  }

  @Test
  func `rename merges and de-dupes preserving first-occurrence order`() {
    // A song carrying BOTH old and new collapses to a single `new`,
    // positioned where it first occurred.
    #expect(
      GenreEdit.renaming(["Alt", "Rock", "Indie"], from: "Indie", to: "Rock")
        == ["Alt", "Rock"]
    )
    #expect(
      GenreEdit.renaming(["Indie", "Alt", "Rock"], from: "Indie", to: "Rock")
        == ["Rock", "Alt"]
    )
  }

  @Test
  func `rename is trim-insensitive on match and trims the new value`() {
    #expect(GenreEdit.renaming([" Rok "], from: "Rok", to: "  Rock  ") == ["Rock"])
  }

  @Test
  func `rename returns nil when nothing changes`() {
    #expect(GenreEdit.renaming(["Rock", "Pop"], from: "Jazz", to: "Blues") == nil)
    #expect(GenreEdit.renaming(["Rock"], from: "Rock", to: "Rock") == nil)
    #expect(GenreEdit.renaming([], from: "A", to: "B") == nil)
  }

  @Test
  func `rename rejects empty endpoints`() {
    #expect(GenreEdit.renaming(["Rock"], from: "", to: "X") == nil)
    #expect(GenreEdit.renaming(["Rock"], from: "Rock", to: "   ") == nil)
  }

  @Test
  func `add appends when absent`() {
    #expect(GenreEdit.adding(["Rock"], "Jazz") == ["Rock", "Jazz"])
    #expect(GenreEdit.adding([], "Jazz") == ["Jazz"])
  }

  @Test
  func `add is idempotent (nil when already present, trim-insensitive)`() {
    #expect(GenreEdit.adding(["Rock", "Jazz"], "Jazz") == nil)
    #expect(GenreEdit.adding([" Jazz "], "Jazz") == nil)
    #expect(GenreEdit.adding(["Rock"], "  ") == nil)
  }

  @Test
  func `add trims the new value`() {
    #expect(GenreEdit.adding(["Rock"], "  Jazz  ") == ["Rock", "Jazz"])
  }
}
