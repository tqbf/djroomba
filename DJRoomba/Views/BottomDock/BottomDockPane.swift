import SwiftUI

// MARK: - BottomDockPane

/// The bottom-docked pane sitting under the track list, hosting the
/// DJ Roomba assistant chat and the Genre Map as two tabs. Owns the
/// collapse/resize wrapper + the shared header (chevron + segmented
/// tab picker); the per-tab bodies (`AssistantPaneView` /
/// `GenreTreeMapBody`) own their own internal headers, content, and
/// any tab-specific affordances.
///
/// Replaces the standalone `GenreTreeMapPanel` (which only hosted the
/// genre map) and the standalone Assistant `Window` scene (⌥⌘\), per
/// user direction 2026-05-29 — "the AI conversation and the genre map
/// share a pane, switched by tabs; the AI is 'DJ Roomba'."
///
/// **Pane container idiom** (kept from `GenreTreeMapPanel`):
///
/// - A top divider, then a resize handle when expanded, then the
///   shared header bar; collapsed, only the slim header bar remains
///   so the pane is always re-discoverable.
/// - Height is `@SceneStorage`-persisted (key `genreTreePanelHeight`
///   kept verbatim to preserve users' existing resize).
/// - Collapse state and tab selection live on `MusicController` so
///   the toolbar buttons + menu commands + this header all drive one
///   shared value.
///
/// **Tab picker auto-expand:** clicking a segment on the collapsed
/// bar both switches tabs AND expands the pane — the segmented picker
/// is the primary "show me this" affordance, the chevron is just the
/// hide control.
struct BottomDockPane: View {

  // MARK: Internal

  var body: some View {
    VStack(spacing: 0) {
      Divider()
      if collapsed {
        // Slim, fixed-height bar — the only thing left when collapsed,
        // so the pane is always re-discoverable. Clicking a tab here
        // auto-expands (see `tabBinding`).
        sharedHeader
          .frame(height: 36)
      } else {
        BottomDockResizeHandle(
          height: $panelHeight,
          range: Self.minBodyHeight ... Self.maxBodyHeight,
        )
        sharedHeader
          .frame(height: 36)
        Divider()
        tabContent
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .frame(height: CGFloat(panelHeight))
      }
    }
    .background(.background)
    .animation(.easeOut(duration: 0.22), value: collapsed)
  }

  // MARK: Private

  /// The pane body's resizable bounds. The min keeps either tab
  /// readable; the max stops the pane from swallowing the track list
  /// above it on a tall window (the user can still collapse it).
  private static let minBodyHeight: Double = 240
  private static let maxBodyHeight: Double = 900

  /// Pane body height — view-layer concern, scene-persisted so a
  /// resize survives relaunch (scene state must not live inside an
  /// `@Observable`). Key reused from the predecessor
  /// `GenreTreeMapPanel` so existing users keep their setting.
  @SceneStorage("genreTreePanelHeight") private var panelHeight = 440.0

  @Environment(MusicController.self) private var controller

  private var collapsed: Bool {
    controller.bottomDockCollapsed
  }

  /// Tab binding that auto-expands the pane when the user picks a
  /// segment while collapsed. Reading the tab is a plain controller
  /// read; writing both flips the tab and clears the collapse so the
  /// segmented picker is a one-click "show me this" affordance.
  private var tabBinding: Binding<BottomDockTab> {
    Binding(
      get: { controller.bottomDockTab },
      set: { newValue in
        controller.bottomDockTab = newValue
        if controller.bottomDockCollapsed { controller.bottomDockCollapsed = false }
      },
    )
  }

  /// The shared header bar — chevron + segmented tab picker.
  /// Identical layout collapsed or expanded so the controls don't
  /// jump as the pane opens/closes.
  private var sharedHeader: some View {
    HStack(spacing: 12) {
      collapseChevron
      Picker("Bottom Pane Tab", selection: tabBinding) {
        ForEach(BottomDockTab.allCases) { tab in
          Label(tab.label, systemImage: tab.systemImage)
            .tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .accessibilityLabel("Bottom pane tab")
      Spacer()
    }
    .padding(.horizontal, 16)
    .contentShape(Rectangle())
  }

  private var collapseChevron: some View {
    Button {
      controller.bottomDockCollapsed.toggle()
    } label: {
      Image(systemName: collapsed ? "chevron.up" : "chevron.down")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(collapsed ? "Show the \(controller.bottomDockTab.label.lowercased()) pane" : "Hide the pane")
  }

  /// The currently-selected tab's body. Plain `switch` rather than
  /// `TabView` — we want the surrounding header + collapse/resize
  /// chrome the dock owns, not `TabView`'s own (which would either
  /// duplicate the picker or hide it but still impose its own
  /// container chrome).
  @ViewBuilder
  private var tabContent: some View {
    switch controller.bottomDockTab {
    case .djroomba:
      AssistantPaneView()
    case .genreMap:
      GenreTreeMapBody()
    }
  }
}
