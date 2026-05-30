import MusicKit
import SwiftUI

/// Re-resolves a live `MusicKit.Artwork` from a stored `MusicItemID`, cached
/// process-wide. This is the **D2 corrective**, extended by
/// `plans/catalog-playlists.md` Phase 4 to cover catalog rows.
///
/// Background: the local-first store keeps only the `MusicItemID` (+
/// namespace), never a live MusicKit object. Phase 3 had tried to persist
/// `Artwork.url(...)`, but for *library* items on macOS that yields a private
/// `musicKit://…` scheme `URLSession` cannot fetch — so every thumbnail
/// regressed to the placeholder. Phase 1 displayed real cover art by handing
/// a live `Artwork` to MusicKit's own `ArtworkImage` view (which fetches +
/// caches the bitmap itself, including the private scheme). This restores
/// exactly that: we lazily re-fetch the owning item by id, cache its
/// `Artwork`, and `ArtworkThumbnail` renders it via `ArtworkImage` — the
/// macos-design–recommended idiom, Phase-1-identical look.
///
/// Per-namespace branching (Phase 4). `resolve` dispatches by the stored
/// `Song.IDNamespace`:
/// - `.library` + `.song` → `MusicLibraryRequest<Song>` (the dev-signed
///   path Phase 1 proved). Library artwork URLs are the private
///   `musicKit://` scheme; only `ArtworkImage` can render them.
/// - `.catalog` + `.song` → `MusicCatalogResourceRequest<Song>(matching:
///   \.id, memberOf: [id])` — the same shape `PlaybackResolver
///   .fetchCatalogSongs` uses for playback. Catalog `Artwork.url(...)` is
///   a public HTTPS URL, but we still hand the `Artwork` to `ArtworkImage`
///   so the renderer is one path for both namespaces (MusicKit picks the
///   right transport internally; the consumer view doesn't fork).
/// - `.library` + `.playlist` → `MusicLibraryRequest<Playlist>` (imported
///   Apple playlists; their own id is a library `MusicItemID`).
/// - `.catalog` + `.playlist` → returns nil by design. The app doesn't
///   import catalog *playlists* (only catalog songs, via the catalog-
///   search surface), so this combination never arises; the explicit nil
///   documents that as a deliberate non-goal rather than an oversight.
///
/// Local-first preserved: only the id is stored; `Artwork` is decorative and
/// re-derived on demand. Offline-friendly: a failed re-resolve degrades to
/// the same native placeholder (never a broken image); once `ArtworkImage`
/// has shown a bitmap, MusicKit's own on-disk artwork cache serves it again.
///
/// Concurrency: an `actor` (no GCD, no locks). It serializes an in-memory
/// cache and de-dupes concurrent re-resolves for the same key so each id is
/// fetched at most once per process; subsequent asks are an immediate cache
/// hit (no re-fetch, no scroll flicker — the hard requirement). Only
/// `Sendable` values cross the actor boundary (`Artwork` is `Sendable`).
actor ArtworkProvider {

  // MARK: Lifecycle

  private init() { }

  // MARK: Internal

  /// What kind of library item owns the artwork (drives which
  /// `MusicLibraryRequest` is issued).
  enum Kind: Hashable, Sendable {
    case song
    case playlist
  }

  static let shared = ArtworkProvider()

  /// Resolve the `Artwork` for a stored id, fetching+caching on first use.
  /// Returns `nil` for an empty id, a `(.catalog, .playlist)` combination
  /// (a deliberate non-goal — see the type doc; we don't import catalog
  /// playlists), or any re-resolve miss/failure; the caller then shows the
  /// shared placeholder. The `Key` includes `namespace`, so a library
  /// and a catalog row that happen to share a `musicItemID` cache
  /// independently — neither can evict or contaminate the other.
  func artwork(
    forMusicItemID musicItemID: String,
    namespace: Song.IDNamespace,
    kind: Kind,
  ) async -> Artwork? {
    guard !musicItemID.isEmpty else { return nil }

    let key = Key(musicItemID: musicItemID, namespace: namespace, kind: kind)
    if let cached = cache[key] { return cached }
    if let existing = inFlight[key] { return await existing.value }

    // Bounded-concurrency permit lives INSIDE the task so the actor's
    // `inFlight` dedupe upstream still works — without a suspension
    // between the `inFlight[key]` check and the assignment below, a
    // burst of concurrent requests for the same key all see the
    // first task and share its result. Cap: see `maxConcurrentResolves`.
    // On macOS 14.4 a real crash reproduced with ~20 parallel
    // `MPModelLibraryRequest`s — MusicKit's underlying
    // `MRMediaRemoteServiceIsMusicAppInstalled` synchronous XPC
    // over-releases an autoreleased object under load and the next
    // pool pop hits a dangling pointer. Bounding fixes that without
    // a measurable UI slowdown (artwork is renderable out-of-order;
    // rows just resolve a hair later).
    let task = Task<Artwork?, Never> { [weak self] in
      guard let self else { return nil }
      await acquirePermit()
      let result = await Self.resolve(
        musicItemID: musicItemID,
        namespace: namespace,
        kind: kind,
      )
      await releasePermit()
      return result
    }
    inFlight[key] = task
    let resolved = await task.value
    inFlight[key] = nil
    store(resolved, for: key)
    return resolved
  }

  // MARK: Private

  private struct Key: Hashable, Sendable {
    let musicItemID: String
    let namespace: Song.IDNamespace
    let kind: Kind
  }

  /// Phase B residency ceiling (`plans/memory-and-laziness.md`): cap the
  /// process-wide cache (positives **and** negatives) so a marathon scroll
  /// over a large library can't grow it without bound. `Artwork` is a small
  /// handle and MusicKit owns the bitmap cache, so the ceiling is generous
  /// and eviction is plain FIFO — a re-scroll of an evicted old item just
  /// re-resolves cheaply (MusicKit's own on-disk cache still serves the
  /// bitmap). Far larger than any on-screen working set, so it never
  /// evicts something actively visible.
  private static let cacheCeiling = 1024

  /// Maximum number of concurrent `MusicLibraryRequest` /
  /// `MusicCatalogResourceRequest`s in flight at once. Chosen because
  /// MusicKit on macOS 14.4 was observed crashing (over-release on an
  /// XPC-returned autoreleased object in the next pool drain) when
  /// ~20+ concurrent `MPModelLibraryRequest`s were issued together —
  /// see the crash dump on this PR. Four is well below that bound,
  /// large enough that artwork still streams visibly while scrolling,
  /// and SwiftUI's own per-row task lifecycle cancels off-screen
  /// resolves so we don't pile up dead work behind the permit.
  private static let maxConcurrentResolves = 4

  /// `.some(nil)` = resolved-but-no-artwork (cache the negative so we don't
  /// re-request a known-artless item every scroll). Absent = never tried.
  private var cache = [Key: Artwork?]()
  private var inFlight = [Key: Task<Artwork?, Never>]()
  /// Insertion order for the FIFO bound below.
  private var insertionOrder = [Key]()

  /// Current count of resolves in flight. Held on the actor; the
  /// permit acquire/release pair is the only thing that touches it.
  private var liveResolves = 0

  /// FIFO of awaiters when all permits are taken. Each entry is the
  /// continuation that's parked in `acquirePermit()` waiting for
  /// `releasePermit()` to hand back a slot.
  private var permitWaiters = [CheckedContinuation<Void, Never>]()

  /// Re-fetch the owning item by id and return its `Artwork`. Dispatches
  /// on `(namespace, kind)`:
  /// - `(.library, .song)` and `(.library, .playlist)` use
  ///   `MusicLibraryRequest<…>` — the dev-signed path Phase 1 proved (no
  ///   MusicKit App Service needed; library artwork URLs are the private
  ///   `musicKit://` scheme that only `ArtworkImage` can render).
  /// - `(.catalog, .song)` uses `MusicCatalogResourceRequest<Song>(
  ///   matching: \.id, memberOf: [id])` — the same shape
  ///   `PlaybackResolver.fetchCatalogSongs` uses, requires the MusicKit
  ///   App Service (LIVE since Phase 0 of `plans/catalog-playlists.md`).
  /// - `(.catalog, .playlist)` returns nil: the app doesn't import
  ///   catalog playlists (only catalog songs); this combination never
  ///   arises and the explicit nil documents that as a deliberate non-
  ///   goal rather than an oversight.
  ///
  /// `nonisolated static` so it captures nothing actor-isolated.
  private nonisolated static func resolve(
    musicItemID: String,
    namespace: Song.IDNamespace,
    kind: Kind,
  ) async -> Artwork? {
    let id = MusicItemID(musicItemID)
    do {
      switch (namespace, kind) {
      case (.library, .song):
        var request = MusicLibraryRequest<MusicKit.Song>()
        request.filter(matching: \.id, memberOf: [id])
        let response = try await request.response()
        return response.items.first?.artwork

      case (.library, .playlist):
        var request = MusicLibraryRequest<MusicKit.Playlist>()
        request.filter(matching: \.id, memberOf: [id])
        let response = try await request.response()
        return response.items.first?.artwork

      case (.catalog, .song):
        let request = MusicCatalogResourceRequest<MusicKit.Song>(
          matching: \.id,
          memberOf: [id],
        )
        let response = try await request.response()
        return response.items.first?.artwork

      case (.catalog, .playlist):
        // Deliberate non-goal: we don't import catalog playlists. Caller
        // gets the same `nil` → placeholder fallback any miss yields.
        return nil
      }
    } catch {
      return nil
    }
  }

  /// Park until a resolve slot is free, then take it. Cheap path:
  /// when there's headroom we increment and return synchronously.
  private func acquirePermit() async {
    if liveResolves < Self.maxConcurrentResolves {
      liveResolves += 1
      return
    }
    await withCheckedContinuation { continuation in
      permitWaiters.append(continuation)
    }
    liveResolves += 1
  }

  /// Hand the slot back to the next awaiter (or just decrement when
  /// nobody is waiting). Symmetric with `acquirePermit`; every taken
  /// permit must be returned exactly once.
  private func releasePermit() {
    liveResolves -= 1
    if !permitWaiters.isEmpty {
      let next = permitWaiters.removeFirst()
      next.resume()
    }
  }

  /// Insert with the FIFO bound applied. Re-storing an existing key keeps
  /// its original position (it was already counted) — only genuinely new
  /// keys grow the cache and can trigger an eviction.
  private func store(_ artwork: Artwork?, for key: Key) {
    if cache.index(forKey: key) == nil { insertionOrder.append(key) }
    cache[key] = artwork
    while cache.count > Self.cacheCeiling, !insertionOrder.isEmpty {
      let oldest = insertionOrder.removeFirst()
      cache[oldest] = nil
    }
  }

}
