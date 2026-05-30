import SwiftUI

#if DEBUG || PROFILE_RECORDER
import Logging
import ProfileRecorderServer
#endif

// MARK: - PlaylistPlayerApp

@main
struct PlaylistPlayerApp: App {

  // MARK: Lifecycle

  init() {
    #if DEBUG || PROFILE_RECORDER
    // In-process sampling profiler (apple/swift-profile-recorder), for the
    // perf investigations documented in plans/profiling.md. This is
    // **inert** unless `PROFILE_RECORDER_SERVER_URL_PATTERN` (or
    // `PROFILE_RECORDER_SERVER_URL`) is set at launch: with neither,
    // `parseFromEnvironment()` returns `.default` (no bind target) and the
    // server never listens. Compiled only in DEBUG builds, or release builds
    // explicitly opted in with `-Xswiftc -DPROFILE_RECORDER` (for
    // release-accurate profiles); the normal release / notarized `make dist`
    // build defines neither, so it never references or starts it.
    // `Task.detached` (not GCD) is the correct way to launch this
    // process-lifetime background service from a synchronous `App.init`;
    // `runIgnoringFailures` swallows any bind error (e.g. sandbox) so it can
    // never affect the app.
    Task.detached(priority: .utility) {
      do {
        let configuration = try await ProfileRecorderServerConfiguration.parseFromEnvironment()
        await ProfileRecorderServer(configuration: configuration)
          .runIgnoringFailures(logger: Logger(label: "profile-recorder"))
      } catch {
        // Only reached for a malformed PROFILE_RECORDER_SERVER_URL* value.
        // Never started → never affects the app; nothing else to do.
      }
    }
    #endif
  }

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

      // The native File-menu home for document import/export
      // (`plans/snapshot-export-import.md`). No shortcuts: Apple's own
      // apps leave import/export unbound and the app's shortcut space is
      // already dense (⌘R/⇧⌘R/⌥⌘A/⌘N/⌘[). "Revert" is enabled only while
      // a pre-import backup exists (also surfaced as the post-import
      // `.status` chip).
      CommandGroup(after: .importExport) {
        Button("Export Library Snapshot…") {
          Task { await controller.beginSnapshotExport() }
        }
        Button("Import Library Snapshot…") {
          controller.isPresentingSnapshotImporter = true
        }
        Button("Revert Last Snapshot Import") {
          Task { await controller.revertSnapshotImport() }
        }
        .disabled(!controller.canRevertSnapshot)
        Divider()
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

        Button("Reimport Everything") {
          Task { await controller.reimportEverything() }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])

        Divider()

        // Sibling of "Reimport Everything": both rebuild derived state
        // wholesale from the library. ⌥⌘A — ⌘A/⇧⌘A are reserved
        // (Select All / Deselect); ⌥⌘A is free and mnemonic ("Analyze").
        // Stays bound for the v6 genre-graph rebuild path; Phase B of
        // the tree plan keeps the shortcut free for development-time
        // manual graph rebuilds (the auto-rebuild hook on import covers
        // the user-facing trigger).
        Button("Analyze Genre Graph") {
          Task { await controller.analyzeGenreGraph() }
        }
        .keyboardShortcut("a", modifiers: [.command, .option])

        // ⌥⇧⌘A reveals the bottom dock pane on the Genre Map tab.
        // Per user direction 2026-05-22 the genre map is an inline
        // pane (not a sheet); per user direction 2026-05-29 it shares
        // that pane with the DJ Roomba assistant via tabs, so this
        // command both expands the pane AND selects the genre-map
        // tab via the controller's `showGenreMap()` funnel.
        Button("Show Genre Map") {
          controller.showGenreMap()
        }
        .keyboardShortcut("a", modifiers: [.command, .option, .shift])

        // ⌥⌘\ used to open a standalone Assistant window; the
        // assistant moved into the shared bottom dock pane on
        // 2026-05-29, so the same shortcut now expands the dock onto
        // the DJ Roomba tab (the mirror of "Show Genre Map" above,
        // same `MusicController` funnel).
        Button("Show DJ Roomba") {
          controller.showAssistant()
        }
        .keyboardShortcut("\\", modifiers: [.command, .option])

        // A `Toggle` in a menu is the native checkmark-menu-item idiom.
        // Bound through `Bindable` (the modern Observation binding —
        // avoids a `Binding(get:set:)`); `MusicController`'s `didSet`
        // writes the change straight to `UserPreferencesStore`. A setting,
        // not a primary action, so no keyboard shortcut.
        Toggle(
          "Reanalyze Automatically",
          isOn: Bindable(controller).autoReanalyzeGenreGraph,
        )
      }

      CommandGroup(after: .sidebar) {
        Button("Playlists", action: controller.requestSidebarFocus)
          .keyboardShortcut("1", modifiers: .command)

        Button("Focus Playlist Sidebar", action: controller.requestSidebarFocus)
          .keyboardShortcut("l", modifiers: .command)
      }

      // Phase-2 catalog search surface (`plans/catalog-playlists.md`).
      // Top-level **Search** menu — discoverable, doesn't compete with
      // the busy toolbar.
      //
      // Shortcut: **⌥⌘F**. The natural choice ⌘F is already bound by
      // `.searchable` on the playlist sidebar + track-table filters.
      // ⇧⌘F was also tried and rejected after live verification: the
      // vendored `ForceGraph`'s `KeyCaptureView` swallows EVERY
      // command-F combo that lacks Option/Control (`Vendor/ForceGraph/
      // Sources/ForceGraph/Interaction/KeyCaptureView.swift:127–132`) —
      // so ⇧⌘F summons the graph's search HUD instead of this sheet.
      // ⌥⌘F is free, explicitly excluded from the graph's gate, and
      // mnemonic enough ("Option+Find" → catalog find).
      CommandMenu("Search") {
        Button("Search Apple Music…") {
          controller.presentCatalogSearch()
        }
        .keyboardShortcut("f", modifiers: [.command, .option])
      }

      // Clearly labelled developer affordance: seed synthetic plays so
      // the Recently Played surface is testable without listening to 500
      // songs. Intentionally NOT `#if DEBUG`-gated — the user's normal
      // `make` build is debug-config and they want this button.
      CommandMenu("Debug") {
        Button("Seed 500 Random Plays") {
          Task { await controller.seedSyntheticHistory(count: 500) }
        }
        Button("Catalog Access Probe (Phase 0)") {
          Task { await controller.runCatalogAccessProbe() }
        }
        // Developer / computer-use affordance for quickly populating
        // the Up Next queue without right-clicking individual tracks.
        // Pulls the first three tracks from the currently-selected
        // playlist's detail (already loaded) or, if nothing's selected,
        // from the Recently Played landing. Kept past Phase 3 as a
        // permanent debug convenience; the user-facing routes are the
        // track-context-menu "Add to Up Next" item and the sidebar
        // landing's drop target.
        Button("Seed Up Next from Current Selection (3 tracks)") {
          Task { await controller.seedUpNextFromCurrentSelection(count: 3) }
        }
        Divider()
        // Manual rebuild affordance for the genre tree. The user-
        // facing "Show Genre Tree…" command auto-rebuilds on demand;
        // this entry is a developer escape hatch for re-running the
        // pipeline without leaving the menu.
        Button("Re-Analyze Genre Map") {
          Task { await controller.analyzeGenreTree() }
        }
        // Trunk-selection metric A/B — a development comparison knob,
        // not a user-facing control. Lived in the panel header as a
        // segmented picker through Phase B; demoted here (2026-05-22)
        // because it read as inscrutable jargon in the main UI. The
        // shipping default is `.highestTransferness`.
        Picker("Trunk Metric", selection: Bindable(controller.genreTreeService).metric) {
          Text("Transferness").tag(TrunkSelectionMetric.highestTransferness)
          Text("Weight").tag(TrunkSelectionMetric.highestWeight)
          Text("Centrality").tag(TrunkSelectionMetric.highestCentrality)
        }
      }
    }

    // The standard macOS Settings window (⌘, — SwiftUI wires the menu
    // item + shortcut automatically for a `Settings` scene). The **OpenAI**
    // pane reads `controller.gpt` so we inject the controller into this
    // scene's environment; the Advanced pane stays self-contained on
    // `@AppStorage`.
    Settings {
      SettingsView()
        .environment(controller)
    }

    // (The standalone "DJ Roomba Assistant" `Window` scene retired
    // 2026-05-29 — the assistant now shares the bottom dock pane with
    // the genre map via tabs. ⌥⌘\ is wired as a Playback-menu command
    // above and routes through `MusicController.showAssistant()`.)
  }

  // MARK: Private

  @State private var controller = MusicController()

}
