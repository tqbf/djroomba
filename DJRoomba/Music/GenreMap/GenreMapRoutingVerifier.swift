// swiftformat:disable preferForLoop
//
// SwiftUI's `Path` is not `Sequence`-conforming, so the
// `preferForLoop` rule would rewrite `path.forEach { … }` into a
// `for-in` loop that fails to compile. Disable the rule for this
// file (same hatch as `GenreMapRoutingActor.swift` and
// `Tests/DJRoombaTests/GenreMapRoutingTests.swift`).

import CoreGraphics
import Foundation
import SwiftUI

// MARK: - GenreMapRoutingVerifier

/// Phase-4-gate (2026-05-21) DEBUG-only per-strand label-crossing
/// verifier. Lives outside `GenreMapRoutingActor` so the actor stays
/// focused on routing + caching; this file owns the post-route
/// "every routed polyline clears every non-member label rect" check
/// that mirrors the gate's headline unit-test invariant
/// (`rendered centripetal Catmull-Rom clears the non-member label
/// rectangle`) on the LIVE library at runtime.
///
/// Compiled only under `#if DEBUG`. Release builds drop the verifier
/// entirely (no symbol, no call). The actor calls
/// `GenreMapRoutingVerifier.runIfDebug(…)` as a one-line entry; the
/// fan-out lives here.
#if DEBUG
enum GenreMapRoutingVerifier {

  // MARK: Internal

  /// **Phase-4-gate entry point.** For each bundled strand polyline,
  /// render through the renderer's centripetal Catmull-Rom
  /// (`StrandSpline.catmullRomPath`), densely sample the resulting
  /// Bezier, and confirm no sample lies inside any non-member label
  /// rect. Emits one stderr line per strand:
  /// `[GenreMapRouting] strand=ID name='<label>' CLEAN|DEFECT cross='<label>'`.
  /// Fire-and-forget — runs on a background detached task so the
  /// caller's actor queue isn't held. Never throws, never affects
  /// routing output.
  static func runIfDebug(
    bundled: [GenreMapBundling.BundledStrand],
    labels: [GenreMapRouting.LabelObstacle],
    strandLabels: [GenreMapStrandInference.Strand],
  ) {
    Task.detached(priority: .background) {
      Self.verifyStrandsClearLabels(
        bundled: bundled,
        labels: labels,
        strandLabels: strandLabels,
      )
    }
  }

  // MARK: Private

  private static func verifyStrandsClearLabels(
    bundled: [GenreMapBundling.BundledStrand],
    labels: [GenreMapRouting.LabelObstacle],
    strandLabels: [GenreMapStrandInference.Strand],
  ) {
    let strandByID = Dictionary(uniqueKeysWithValues: strandLabels.map { ($0.id, $0) })
    // Use the same insetBy(-2, -2) the test uses so a sub-pixel graze
    // at the pill chrome doesn't false-positive but a real crossing does.
    let labelsByGenre = Dictionary(
      uniqueKeysWithValues: labels.map { ($0.genre, $0.rect.insetBy(dx: -2, dy: -2)) }
    )
    for routed in bundled {
      let memberGenres = Set(strandByID[routed.strandID]?.memberGenres ?? [])
      let strandLabel = strandByID[routed.strandID]?.label ?? "strand-\(routed.strandID)"
      guard routed.polyline.count >= 2 else { continue }
      let path = StrandSpline.catmullRomPath(points: routed.polyline)
      var samples = [CGPoint]()
      var pen = CGPoint.zero
      path.forEach { element in
        switch element {
        case .move(let to):
          pen = to
          samples.append(to)

        case .line(let to):
          samples.append(to)
          pen = to

        case .quadCurve(let to, let control):
          let from = pen
          for step in 1 ... 24 {
            let t = Double(step) / 24.0
            let next = StrandSpline.quadBezier(from: from, control: control, to: to, t: t)
            samples.append(next)
            pen = next
          }

        case .curve(let to, let control1, let control2):
          let from = pen
          for step in 1 ... 48 {
            let t = Double(step) / 48.0
            let next = StrandSpline.cubicBezier(
              from: from,
              control1: control1,
              control2: control2,
              to: to,
              t: t,
            )
            samples.append(next)
            pen = next
          }

        case .closeSubpath:
          break
        }
      }
      var crossings = [String]()
      // Build the set of member-station label rects so the verifier
      // doesn't false-positive when a member station's pill happens to
      // overlap a non-member station's pill in world coordinates (the
      // drag-relax pass can produce post-drag layouts where member +
      // non-member labels overlap; the polyline endpoint sits at the
      // member station's position, which can fall inside a non-member's
      // rect even though A* routed it cleanly). The headline criterion
      // is "the polyline doesn't pass through a non-member label";
      // a sample point that's a member station endpoint shouldn't count.
      let memberRects: [CGRect] = memberGenres.compactMap { labelsByGenre[$0] }
      for (genre, rect) in labelsByGenre where !memberGenres.contains(genre) {
        let crossed = samples.contains { point in
          guard rect.contains(point) else { return false }
          // Exclude sample points that lie inside a MEMBER pill too —
          // those are endpoint / member-station pixels, not a label-
          // crossing event the user would perceive.
          for memberRect in memberRects where memberRect.contains(point) {
            return false
          }
          return true
        }
        if crossed {
          crossings.append(genre)
        }
      }
      let line: String
      if crossings.isEmpty {
        line = "[GenreMapRouting] strand=\(routed.strandID) name='\(strandLabel)' CLEAN samples=\(samples.count)\n"
      } else {
        let names = crossings.sorted().joined(separator: ",")
        // Phase-4-gate diagnostic: dump the first offending sample for
        // each crossing label so the gate can localise which segment
        // of the polyline strayed into the obstacle.
        var details = [String]()
        for genre in crossings.sorted() {
          guard let rect = labelsByGenre[genre] else { continue }
          if let badSample = samples.first(where: rect.contains) {
            details.append(
              "\(genre)@(\(Int(badSample.x)),\(Int(badSample.y)))rect(\(Int(rect.minX))..<\(Int(rect.maxX)),\(Int(rect.minY))..<\(Int(rect.maxY)))"
            )
          }
        }
        line = "[GenreMapRouting] strand=\(routed.strandID) name='\(strandLabel)' DEFECT crossings='\(names)' samples=\(samples.count) details=[\(details.joined(separator: "; "))]\n"
      }
      FileHandle.standardError.write(Data(line.utf8))
    }
  }
}
#endif
