import SwiftUI

/// The two surfaces the bottom dock pane can host. Both share the same
/// docked, collapsible/resizable container under the track list; the user
/// flips between them with a segmented picker in the pane header. The
/// label `"DJ Roomba"` carries the assistant's identity into the UI — the
/// DJ is the AI.
enum BottomDockTab: String, CaseIterable, Identifiable, Sendable {

  case djroomba
  case genreMap

  // MARK: Internal

  var id: String {
    rawValue
  }

  /// Visible label on the segmented picker + collapsed bar.
  var label: String {
    switch self {
    case .djroomba: "DJ Roomba"
    case .genreMap: "Genre Map"
    }
  }

  /// Glyph paired with the label on toolbar buttons + the segmented
  /// picker icons. SF Symbols, matched to each surface's identity (the
  /// existing toolbar idiom — sparkles for the assistant, map for the
  /// genre view).
  var systemImage: String {
    switch self {
    case .djroomba: "sparkles"
    case .genreMap: "map"
    }
  }
}
