import SwiftUI

// MARK: - CommunityHull

/// Subtle background tint per community (`plans/genre-metro-map.md` Phase 1
/// step 7 — "subtle community hulls (or tint background)"). Drawn beneath
/// the layout edges + station labels; very low opacity so it reads as a
/// region, not a feature.
///
/// Phase 1 deliberately avoids a true convex hull — that needs a deferred
/// geometry pass + careful obstacle padding (the realm of Phase 4). Here
/// each community draws as a soft radial fill at its member-cloud centroid,
/// sized to its members' AABB. That conveys neighbourhood without
/// promising precision the rest of the renderer can't yet honour.
struct CommunityHull: View {

  // MARK: Internal

  var community: GenreMapCommunity
  var nodes: [GenreMapNode]
  var hullColour: Color

  var body: some View {
    let (centre, radius) = hullBounds()
    return Circle()
      .fill(
        RadialGradient(
          colors: [hullColour.opacity(0.18), hullColour.opacity(0.0)],
          center: .center,
          startRadius: 1,
          endRadius: radius,
        )
      )
      .frame(width: radius * 2, height: radius * 2)
      .position(centre)
      .allowsHitTesting(false)
  }

  // MARK: Private

  private func hullBounds() -> (centre: CGPoint, radius: CGFloat) {
    let positions = nodes
      .filter { community.members.contains($0.genre) }
      .map(\.position)
    guard !positions.isEmpty else { return (.zero, 1) }
    let centre = CGPoint(
      x: positions.map(\.x).reduce(0, +) / CGFloat(positions.count),
      y: positions.map(\.y).reduce(0, +) / CGFloat(positions.count),
    )
    let radius = positions.map { hypot($0.x - centre.x, $0.y - centre.y) }
      .max() ?? 1
    // Pad the visible radius so the gradient extends beyond the
    // outermost member — the eye reads the soft edge as the boundary.
    return (centre, max(60, radius * 1.4))
  }
}
