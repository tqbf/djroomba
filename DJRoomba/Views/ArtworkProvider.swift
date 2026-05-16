import MusicKit
import SwiftUI

/// Re-resolves a live `MusicKit.Artwork` from a stored `MusicItemID`, cached
/// process-wide. This is the **D2 corrective**.
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
  /// Returns `nil` for an empty id, a non-library namespace (the only
  /// imported provenance today — see `ImportService`), or any re-resolve
  /// miss/failure; the caller then shows the shared placeholder.
  func artwork(
    forMusicItemID musicItemID: String,
    namespace: Song.IDNamespace,
    kind: Kind,
  ) async -> Artwork? {
    guard !musicItemID.isEmpty else { return nil }
    // Imported provenance is always `.library` (ImportService). The
    // catalog branch is dormant — there is no public per-id catalog
    // artwork re-resolve without the MusicKit App Service entitlement,
    // and nothing catalog-namespace is imported. Degrade gracefully.
    guard namespace == .library else { return nil }

    let key = Key(musicItemID: musicItemID, namespace: namespace, kind: kind)
    if let cached = cache[key] { return cached }
    if let existing = inFlight[key] { return await existing.value }

    let task = Task<Artwork?, Never> {
      await Self.resolve(musicItemID: musicItemID, kind: kind)
    }
    inFlight[key] = task
    let resolved = await task.value
    inFlight[key] = nil
    cache[key] = resolved
    return resolved
  }

  // MARK: Private

  private struct Key: Hashable, Sendable {
    let musicItemID: String
    let namespace: Song.IDNamespace
    let kind: Kind
  }

  /// `.some(nil)` = resolved-but-no-artwork (cache the negative so we don't
  /// re-request a known-artless item every scroll). Absent = never tried.
  private var cache = [Key: Artwork?]()
  private var inFlight = [Key: Task<Artwork?, Never>]()

  /// Re-fetch the owning library item by id and return its `Artwork`.
  /// `MusicLibraryRequest<Song>` is the dev-signed path Phase 1 proved
  /// (no catalog/MusicKit-App-Service entitlement needed); the same shape
  /// works for `MusicLibraryRequest<Playlist>`. `nonisolated static` so it
  /// captures nothing actor-isolated.
  private nonisolated static func resolve(
    musicItemID: String,
    kind: Kind,
  ) async -> Artwork? {
    let id = MusicItemID(musicItemID)
    do {
      switch kind {
      case .song:
        var request = MusicLibraryRequest<MusicKit.Song>()
        request.filter(matching: \.id, memberOf: [id])
        let response = try await request.response()
        return response.items.first?.artwork

      case .playlist:
        var request = MusicLibraryRequest<MusicKit.Playlist>()
        request.filter(matching: \.id, memberOf: [id])
        let response = try await request.response()
        return response.items.first?.artwork
      }
    } catch {
      return nil
    }
  }
}
