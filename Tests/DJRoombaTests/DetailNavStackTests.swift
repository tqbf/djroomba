import Testing
@testable import DJRoomba

/// `DetailNavStack` — the pure push/cap/pop logic behind `MusicController`'s
/// top-pane Back control. Unit-tested in isolation because the
/// `@MainActor @Observable` controller opens the DB + full service graph
/// and can't be constructed in a unit test; the controller only decides
/// *what* to record/replay, the rules live here.
struct DetailNavStackTests {

  @Test
  func `push records the previous destination and pop returns it`() {
    var stack = DetailNavStack()
    #expect(!stack.canGoBack)

    stack.push(.playlist("A"))
    #expect(stack.canGoBack)
    #expect(stack.entries == [.playlist("A")])

    #expect(stack.pop() == .playlist("A"))
    #expect(!stack.canGoBack)
  }

  @Test
  func `nil is never recorded`() {
    var stack = DetailNavStack()
    stack.push(nil)
    #expect(!stack.canGoBack)
    #expect(stack.entries.isEmpty)
  }

  @Test
  func `a repeat of the current top is not recorded`() {
    var stack = DetailNavStack()
    stack.push(.genre("Rock"))
    stack.push(.genre("Rock"))
    #expect(stack.entries == [.genre("Rock")])

    // A different destination still records; then the same one again is
    // a no-op only when it's the *current* top.
    stack.push(.playlist("P"))
    stack.push(.playlist("P"))
    #expect(stack.entries == [.genre("Rock"), .playlist("P")])
  }

  @Test
  func `pop is LIFO`() {
    var stack = DetailNavStack()
    stack.push(.playlist("first"))
    stack.push(.genre("second"))
    stack.push(.playlist("third"))

    #expect(stack.pop() == .playlist("third"))
    #expect(stack.pop() == .genre("second"))
    #expect(stack.pop() == .playlist("first"))
    #expect(stack.pop() == nil)
  }

  @Test
  func `pop underflow is a harmless nil`() {
    var stack = DetailNavStack()
    #expect(stack.pop() == nil)
    #expect(!stack.canGoBack)
  }

  /// The stack is capped: pushing past the bound drops the OLDEST entries
  /// (FIFO eviction of history), keeping the most recent `capacity`.
  @Test
  func `stack caps at capacity dropping the oldest`() {
    var stack = DetailNavStack()
    let total = DetailNavStack.capacity + 25
    for i in 0..<total {
      stack.push(.playlist("p\(i)"))
    }

    #expect(stack.entries.count == DetailNavStack.capacity)
    // Oldest kept is `p25` (the first 25 were evicted); newest is the last.
    #expect(stack.entries.first == .playlist("p25"))
    #expect(stack.entries.last == .playlist("p\(total - 1)"))

    // Popping still returns the most recent first.
    #expect(stack.pop() == .playlist("p\(total - 1)"))
  }

  /// After a genre rename/merge, every `.genre(old)` history entry becomes
  /// `.genre(new)` (so Back never lands on a now-empty genre); `.playlist`
  /// entries and order/length are untouched; `old == new` is a no-op.
  @Test
  func `replacingGenre rewrites only matching genre entries`() {
    var stack = DetailNavStack()
    stack.push(.genre("Rok"))
    stack.push(.playlist("P"))
    stack.push(.genre("Rok"))
    stack.push(.genre("Jazz"))

    stack.replacingGenre("Rok", with: "Rock")
    #expect(stack.entries == [
      .genre("Rock"),
      .playlist("P"),
      .genre("Rock"),
      .genre("Jazz"),
    ])

    let before = stack.entries
    stack.replacingGenre("Pop", with: "Pop") // no-op (old == new)
    stack.replacingGenre("Nope", with: "X") // no matching entry
    #expect(stack.entries == before)
  }
}
