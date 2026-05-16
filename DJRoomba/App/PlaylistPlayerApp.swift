import SwiftUI

@main
struct PlaylistPlayerApp: App {

  // MARK: Internal

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(controller)
        // NO outer `.frame(minWidth:)` here. RootView wraps a
        // `NavigationSplitView` + `.inspector()`; that split view owns
        // its own column-based layout. A hard clamping outer frame is
        // an anti-pattern (swiftui-pro: avoid fixed frames a split
        // view can't fit neatly inside) — when macOS state
        // restoration pins a frame narrower than the clamp, the
        // `.frame(minWidth:)` forces the content to that width
        // *inside the smaller window*, so the split view overflows
        // and clips on BOTH edges instead of widening the window
        // (the deeper Phase-5 D2 root cause). The window minimum is
        // instead derived from the split-view column minimums via
        // `.windowResizability(.contentSize)` below.
        .task { await controller.bootstrap() }
    }
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified)
    // Opens comfortably above the three columns' ideals with the
    // inspector open: sidebar ideal 260 + detail ~660 + inspector ideal
    // 320 ≈ 1240. (Restoration overrides this after first launch, but the
    // content-derived minimum below still floors any restored width.)
    .defaultSize(width: 1240, height: 760)
    // `.contentSize` (not `.contentMinSize`) ties the window's resizable
    // minimum directly to the `NavigationSplitView`'s reported content
    // minimum — the SUM of the sidebar (min 220), detail (min 480) and
    // the open inspector column (min 300): ≈ 1000pt. macOS clamps a
    // restored window frame up to that content-derived minimum, so a
    // stale narrow saved frame can no longer defeat the fix and the
    // window is *never* allowed narrower than all three columns combined
    // (Phase-5 D2 deeper fix). The split view manages the layout; the
    // scene just refuses to be smaller than it.
    .windowResizability(.contentSize)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Playlist") {
          Task { await controller.createAppPlaylist() }
        }
        .keyboardShortcut("n", modifiers: .command)
      }

      CommandMenu("Playback") {
        Button("Play / Pause") {
          Task { await controller.togglePlayPause() }
        }
        .keyboardShortcut(.space, modifiers: [])

        Button("Next") {
          Task { await controller.skipNext() }
        }
        .keyboardShortcut(.rightArrow, modifiers: .command)

        Button("Previous") {
          Task { await controller.skipPrevious() }
        }
        .keyboardShortcut(.leftArrow, modifiers: .command)

        Divider()

        Button("Refresh Playlists") {
          Task { await controller.refreshLibrary() }
        }
        .keyboardShortcut("r", modifiers: .command)
      }

      CommandGroup(after: .sidebar) {
        Button("Playlists", action: controller.requestSidebarFocus)
          .keyboardShortcut("1", modifiers: .command)

        Button("Focus Playlist Sidebar", action: controller.requestSidebarFocus)
          .keyboardShortcut("l", modifiers: .command)
      }
    }
  }

  // MARK: Private

  @State private var controller = MusicController()

}
