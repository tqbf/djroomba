import Foundation

// MARK: - TrunkSelectionMetric

/// Pluggable per-community trunk-selection metric (`plans/son-of-genre-map.md`
/// Phase A — "Trunk selection"). One representative per medium-resolution
/// community (γ = 0.85), capped at k ≤ 7; the variant decides *which*
/// member of the community wins the trunk slot.
///
/// The user has explicitly deferred picking a default: "I won't know what
/// metric is best until I see it." The three variants ship behind this enum
/// so the panel + Debug menu can A/B them live on the real library.
///
/// - `.highestWeight`: pick the community's heaviest member by per-genre
///   `weight`. Risk: generic giants (Rock, Pop, Country) dominate the
///   trunks.
/// - `.highestTransferness`: pick the member with the highest composite
///   transferness (Phase 2 of the metro plan; strand-count slot is zero
///   in this plan because strands retire). Picks the most *connective*
///   member of each community. Risk: a community's most-bridging genre
///   may feel obscure even if its trunk role is important.
/// - `.highestCentrality`: pick the member with the highest normalised
///   betweenness centrality inside the community's induced subgraph.
///   Mid-ground between weight and transferness.
///
/// Tie-break across communities (when more than 7 communities exist) is
/// always **highest community weight** (sum of per-genre weights of
/// members) — that's the cap rule, not a per-variant decision.
enum TrunkSelectionMetric: String, CaseIterable, Equatable, Sendable {
  case highestWeight
  case highestTransferness
  case highestCentrality
}
