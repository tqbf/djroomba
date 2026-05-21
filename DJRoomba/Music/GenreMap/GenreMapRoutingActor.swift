import CoreGraphics
import Foundation
import os

// MARK: - GenreMapRoutingActor

/// Background actor that computes obstacle-aware routed strands
/// (`plans/genre-metro-map.md` Phase 4, step 5). Same shape as
/// `ArtworkProvider` — pure `actor`, no GCD, no locks; deterministic
/// inputs ⇒ deterministic outputs. The `GenreMapService` kicks a
/// `Task` against this actor when the model's `layoutRevision` bumps
/// (geographic change), drops it on the floor mid-drag, and reapplies
/// the result on the main actor once it's ready.
///
/// Cache: `[(strand.id, layoutRevision): RoutedStrand]`. A revision
/// bump invalidates the slice for every strand at the old revision;
/// the actor keeps only the latest revision's results so memory is
/// bounded.
///
/// Concurrency: only `Sendable` values cross the actor boundary
/// (`Snapshot` is pure; `[Int: GenreMapRoutedStrand]` is a value type).
/// The renderer reads through `GenreMapModel.routedStrands` (main
/// actor); the actor never touches SwiftUI state.
actor GenreMapRoutingActor {

  // MARK: Lifecycle

  init() { }

  // MARK: Internal

  /// One routing input — a deterministic snapshot of every input
  /// `GenreMapRouting.route` reads. Built on the main actor from the
  /// current `GenreMapModel` and handed off `Sendable` so the actor
  /// can re-route without retaining the model itself.
  struct Snapshot: Sendable {
    struct Node: Sendable, Equatable {
      var genre: String
      var position: CGPoint
      var labelSize: CGSize
    }

    var layoutRevision: Int
    var strands: [GenreMapStrandInference.Strand]
    var nodes: [Node]
    var configuration: GenreMapRouting.Configuration

  }

  /// Result of a routing pass. Carries instrumentation fields that
  /// the side panel + `PROGRESS.md` perf gate read.
  struct Result: Sendable {
    var layoutRevision: Int
    var routedByStrand: [Int: GenreMapRoutedStrand]
    var corridorCount: Int
    var bundledCorridorCount: Int
    var maxStrandsPerCorridor: Int
    var crossingCount: Int
    var transferCrossingCount: Int
    /// Wall-clock total routing time, in seconds. Surfaced for the
    /// performance gate (< 200 ms on the real library).
    var elapsedSeconds: TimeInterval
  }

  /// Recompute routing for `snapshot`. Idempotent under concurrent
  /// triggers for the same `layoutRevision` (returns the cached
  /// result). A snapshot with a stale `layoutRevision` is discarded
  /// silently — only the latest revision's cache survives.
  func route(_ snapshot: Snapshot) -> Result {
    if cachedRevision == snapshot.layoutRevision, let cached = cachedResult {
      return cached
    }
    // Phase-4-gate (2026-05-21): instrument the routing pass with an
    // `os_signpost` + a `Logger.debug` stderr line so the perf gate
    // can pin the real-library drag-release-rebuild cost. The
    // signpost interval brackets the whole route pass; the debug log
    // emits one line per rebuild with the strand count + node count
    // + elapsed ms — searchable in Console.app under subsystem
    // `org.sockpuppet.djroomba`, category `GenreMapRouting`, and
    // visible on stderr while running the unsigned dev build.
    let signpostID = OSSignpostID(log: Self.signpostLog)
    os_signpost(
      .begin,
      log: Self.signpostLog,
      name: "GenreMapRouting.route",
      signpostID: signpostID,
      "revision=%{public}d strands=%{public}d nodes=%{public}d",
      snapshot.layoutRevision, snapshot.strands.count, snapshot.nodes.count,
    )
    let started = Date()
    defer {
      let elapsedMs = Date().timeIntervalSince(started) * 1000
      os_signpost(
        .end,
        log: Self.signpostLog,
        name: "GenreMapRouting.route",
        signpostID: signpostID,
        "elapsed=%{public}.2fms",
        elapsedMs,
      )
      Self.logger.debug(
        "[GenreMapRouting] route revision=\(snapshot.layoutRevision, privacy: .public) strands=\(snapshot.strands.count, privacy: .public) nodes=\(snapshot.nodes.count, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms",
      )
    }

    // Build the obstacle context inputs.
    let labels = snapshot.nodes.map { node -> GenreMapRouting.LabelObstacle in
      let halfWidth = node.labelSize.width / 2
      let halfHeight = node.labelSize.height / 2
      return GenreMapRouting.LabelObstacle(
        genre: node.genre,
        rect: CGRect(
          x: node.position.x - halfWidth,
          y: node.position.y - halfHeight,
          width: node.labelSize.width,
          height: node.labelSize.height,
        ),
      )
    }
    let stations = snapshot.nodes.map {
      GenreMapRouting.StationCentre(genre: $0.genre, position: $0.position)
    }
    let positionByGenre = Dictionary(
      uniqueKeysWithValues: snapshot.nodes.map { ($0.genre, $0.position) }
    )

    // Build per-strand route requests. Caller order = strand rank
    // (heaviest first) so the first strand routes into the clearest
    // grid. Branches share the parent's corridor at render time but
    // still get their own A* run here — the cell-set may differ.
    var requests = [GenreMapRouting.StrandRouteRequest]()
    requests.reserveCapacity(snapshot.strands.count)
    for strand in snapshot.strands {
      let positions = strand.pathStations.compactMap { positionByGenre[$0] }
      guard positions.count >= 2 else { continue }
      requests.append(GenreMapRouting.StrandRouteRequest(
        strandID: strand.id,
        stationPositions: positions,
        memberGenres: Set(strand.memberGenres),
      ))
    }

    let routed = GenreMapRouting.route(
      strands: requests,
      labels: labels,
      stationCentres: stations,
      configuration: snapshot.configuration,
    )

    // Compute the set of "transfer-station cells" — cells containing
    // a station that two or more strands serve. Bundling reads this
    // for the intentional-crossing discount.
    var membershipByGenre = [String: Set<Int>]()
    for strand in snapshot.strands {
      for member in strand.memberGenres {
        membershipByGenre[member, default: []].insert(strand.id)
      }
    }
    let grid = GenreMapRouting.Grid(configuration: snapshot.configuration)
    var transferCells = Set<GenreMapRouting.GridCell>()
    for (genre, strandIDs) in membershipByGenre where strandIDs.count >= 2 {
      if let position = positionByGenre[genre] {
        transferCells.insert(grid.cell(for: position))
      }
    }

    let bundling = GenreMapBundling.bundle(
      routed: routed,
      memberGenresByStrand: Dictionary(
        uniqueKeysWithValues: snapshot.strands.map { ($0.id, Set($0.memberGenres)) }
      ),
      transferStationCells: transferCells,
    )

    var routedByStrand = [Int: GenreMapRoutedStrand]()
    routedByStrand.reserveCapacity(bundling.bundled.count)
    for bundled in bundling.bundled {
      routedByStrand[bundled.strandID] = GenreMapRoutedStrand(
        strandID: bundled.strandID,
        polyline: bundled.polyline,
        corridorID: bundled.corridorID,
        slot: bundled.slot,
        isBundled: bundled.isBundled,
      )
    }
    let elapsed = Date().timeIntervalSince(started)
    let result = Result(
      layoutRevision: snapshot.layoutRevision,
      routedByStrand: routedByStrand,
      corridorCount: bundling.corridorCount,
      bundledCorridorCount: bundling.bundledCorridorCount,
      maxStrandsPerCorridor: bundling.maxStrandsPerCorridor,
      crossingCount: bundling.crossingCount,
      transferCrossingCount: bundling.transferCrossingCount,
      elapsedSeconds: elapsed,
    )
    cachedRevision = snapshot.layoutRevision
    cachedResult = result
    return result
  }

  /// Drop the cache (test affordance + the rare "user re-Analyzed,
  /// no node positions are even on disk yet" path).
  func clearCache() {
    cachedRevision = nil
    cachedResult = nil
  }

  // MARK: Private

  /// Unified-logging handles for the Phase-4-gate perf instrumentation.
  /// Subsystem is the app's bundle id so `log show` / Console.app
  /// filter cleanly; category lets future routing-related signposts
  /// share one channel.
  private static let logger = Logger(
    subsystem: "org.sockpuppet.djroomba",
    category: "GenreMapRouting",
  )
  private static let signpostLog = OSLog(
    subsystem: "org.sockpuppet.djroomba",
    category: "GenreMapRouting",
  )

  private var cachedRevision: Int?
  private var cachedResult: Result?
}
