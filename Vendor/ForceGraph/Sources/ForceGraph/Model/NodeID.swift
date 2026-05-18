import Foundation

/// Identity for a graph node.
///
/// Node identity is a plain `String` (e.g. `"g:family:rock"` in the corpus).
/// A typealias keeps call sites readable while staying a value type that is
/// trivially `Hashable`, `Sendable`, and `Codable`.
public typealias NodeID = String
