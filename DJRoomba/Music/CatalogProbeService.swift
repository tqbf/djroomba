import Foundation
import MusicKit

/// Phase-0 access gate (`plans/catalog-playlists.md`): the smallest possible
/// proof that Apple Music **catalog** access works natively for *this* App ID.
///
/// Phase 1 only ever proved the *library* path on the dev-signed build.
/// "Native MusicKit does catalog with no developer token / web service" is
/// true of MusicKit generally but is **empirically unverified here** until a
/// signed run issues a real catalog request — that is exactly what this fires.
/// It is the catalog analogue of the Phase-1 library access proof, and the
/// hard gate the rest of the catalog work sits behind.
///
/// One `MusicCatalogSearchRequest` for a hardcoded, globally-available track.
/// It **never throws**: the whole point is to capture the outcome — including
/// a failure — as a human-readable diagnostic string the UI surfaces. If the
/// **MusicKit App Service** is not enabled (or not yet propagated) on App ID
/// `org.sockpuppet.djroomba`, the request fails authorization and that error
/// is the signal; surfacing it verbatim is the diagnostic.
///
/// The service intentionally returns the first matching catalog `Song`
/// alongside the verdict so the controller can layer the Phase-0 **playback
/// half** on top — playing that song briefly via `PlaybackService`. Keeping
/// the `MusicKit.Song` value inside the service boundary lets `MusicController`
/// stay MusicKit-free (it just hands the opaque song back to `PlaybackService`).
///
/// Deliberately tiny and self-contained: no `song` ingest, no schema, no
/// search UI (those are Phases 1–2). It will be replaced/absorbed by the real
/// `CatalogIngestService` / search surface once this gate is green.
///
/// Concurrency: `@MainActor` like the sibling MusicKit services, invoked from
/// the `@MainActor` `MusicController`. Stateless — the result is owned by the
/// controller (`catalogProbeResult`), mirroring the genre-import notice.
@MainActor
final class CatalogProbeService {

  // MARK: Internal

  /// The outcome of a single search probe. `verdict` is the human-readable
  /// diagnostic for the **search half** only (the controller appends the
  /// playback-half tail). `firstSong` is the first catalog `Song` returned on
  /// success — the controller hands it straight back to `PlaybackService` for
  /// the Phase-0 playback proof; `nil` on any failure or empty result.
  struct ProbeResult {
    var verdict: String
    var firstSong: MusicKit.Song?
  }

  /// Fire exactly one catalog search and return the verdict + first hit. A
  /// well-known, globally-licensed track so a non-empty result is strong
  /// evidence catalog access genuinely works (not a regional false-negative).
  func searchProbe() async -> ProbeResult {
    let term = "Bohemian Rhapsody Queen"
    do {
      var request = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
      request.limit = 5
      let response = try await request.response()
      guard let first = response.songs.first else {
        let verdict = """
        ⚠️ Catalog request SUCCEEDED but returned 0 songs.

        No authorization error, so the MusicKit App Service is likely live — \
        but a well-known track matching nothing is unusual. Check the \
        Apple Account's storefront / region.

        (query: “\(term)”)
        """
        return ProbeResult(verdict: verdict, firstSong: nil)
      }
      let verdict = """
      ✅ Catalog access OK — the MusicKit App Service is live for this App ID.

      MusicCatalogSearchRequest returned \(response.songs.count) song(s).
      First: “\(first.title)” — \(first.artistName)
      Catalog id: \(first.id.rawValue) (globally stable)
      """
      return ProbeResult(verdict: verdict, firstSong: first)
    } catch {
      let verdict = """
      ❌ Catalog request FAILED.

      \(error.localizedDescription)

      (\(type(of: error)))

      If this reads as a permissions / “not authorized” / developer-token \
      error, the MusicKit App Service is probably not enabled — or not yet \
      propagated — on App ID org.sockpuppet.djroomba (Team KK7E9G89GW). \
      Recheck the portal step, then re-run this probe.
      """
      return ProbeResult(verdict: verdict, firstSong: nil)
    }
  }

}
