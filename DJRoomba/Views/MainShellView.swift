import SwiftUI

/// The authorized shell: sidebar + detail split, persistent now-playing bar
/// pinned to the bottom (never gated behind navigation state), refresh in the
/// unified toolbar, and the collapsible extension `.inspector()` (the M3
/// `MusicContext`/`MusicCommand` boundary, realized in Phase 5) — collapsed by
/// default, toggled from the toolbar.
struct MainShellView: View {

  // MARK: Internal

  var body: some View {
    // `@Bindable` over the `@Environment` controller so the snapshot
    // pickers bind to its presentation flags directly (swiftui-pro: no
    // `Binding(get:set:)`); same instance, just made bindable.
    @Bindable var controller = controller

    return NavigationSplitView(columnVisibility: $columnVisibility) {
      PlaylistSidebar()
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    } detail: {
      DetailPaneView()
        .navigationSplitViewColumnWidth(min: 480, ideal: 660)
    }
    .onAppear {
      columnVisibility = sidebarCollapsed ? .detailOnly : .all
    }
    .onChange(of: columnVisibility) { _, newValue in
      sidebarCollapsed = (newValue == .detailOnly)
    }
    .inspector(isPresented: $inspectorPresented) {
      ExtensionInspectorView()
        // Native macOS inspectors sit ~270–360pt. min:300 gives the
        // grouped `Form`'s `LabeledContent` rows (label + value) and
        // the wrapping footer explainer enough width to lay out
        // cleanly even at the inspector's narrowest. The window can
        // never be narrower than sidebarMin + detailMin + this
        // (≈ 220+480+300 = 1000) because the scene uses
        // `.windowResizability(.contentSize)` (see PlaylistPlayerApp)
        // — so the inspector column always gets its full min width
        // *inside* the window and its content fits without clipping
        // at either edge (the deeper Phase-5 D2 fix).
        .inspectorColumnWidth(min: 300, ideal: 320, max: 420)
    }
    .toolbar {
      // Leading navigation Back control for the top pane's in-session
      // history (playlist / genre / the Recently-Played landing). Native
      // macOS idiom: a `chevron.backward` glyph at the toolbar's leading
      // edge, disabled when there's nothing to return to, with ⌘[ — the
      // standard "navigate back" shortcut.
      ToolbarItem(placement: .navigation) {
        Button {
          controller.goBack()
        } label: {
          Label("Back", systemImage: "chevron.backward")
        }
        .help("Back (⌘[)")
        .disabled(!controller.canGoBack)
        .keyboardShortcut("[", modifiers: .command)
        .accessibilityLabel("Back")
      }
      // The always-on import surface (the defect fix). `.status` is the
      // native macOS centered activity slot Mail/Music use for sync state —
      // a quiet indicator, not a primary action. It carries exactly one of:
      // an in-flight import/genre spinner+text, a tappable failure affordance
      // (so a populated-library import/genre error is finally visible +
      // readable instead of silent), or nothing when idle.
      ToolbarItem(placement: .status) {
        if let probe = controller.catalogProbeResult {
          // Phase-0 catalog access probe verdict. Takes priority in the
          // slot: it is an explicit, user-invoked one-shot the user is
          // waiting to see, so it must not be masked by ambient
          // import/library state. Same calm dismissible-popover idiom as
          // the genre notice; the chip label is fixed (the verdict is
          // multi-line — the full, selectable text lives in the popover).
          Button {
            showingCatalogProbe = true
          } label: {
            Label("Catalog probe result", systemImage: "info.circle")
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .help("Phase-0 catalog access probe result")
          .popover(isPresented: $showingCatalogProbe, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
              Text(probe)
                .font(.callout)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
              Button("Dismiss") {
                showingCatalogProbe = false
                controller.dismissCatalogProbeResult()
              }
            }
            .frame(width: 360, alignment: .leading)
            .padding()
          }
          .accessibilityLabel("Catalog access probe result")
          // `activityText` (not `importActivity`) — the snapshot branch
          // unified the activity source so MusicKit-import AND snapshot
          // export/import progress share this slot.
        } else if let activity = controller.activityText {
          HStack(spacing: 6) {
            ProgressView()
              .controlSize(.small)
            Text(activity)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(activity)
        } else if let problem = controller.libraryProblem {
          Button {
            showingProblem = true
          } label: {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .font(.callout)
              .lineLimit(1)
          }
          .help(problem)
          .popover(isPresented: $showingProblem, arrowEdge: .bottom) {
            Text(problem)
              .font(.callout)
              .textSelection(.enabled)
              .multilineTextAlignment(.leading)
              .frame(width: 320, alignment: .leading)
              .padding()
          }
          .accessibilityLabel("Library problem")
        } else if let notice = controller.genreImportNotice {
          // A completed, non-errored full/first genre pass that tagged zero
          // songs. Quiet secondary info (NOT a warning — the orange branch
          // above owns errors): a tappable `info.circle` chip whose popover
          // shows the full self-diagnosis + a Dismiss. macos-design: a
          // calm, dismissible status note, not an alert.
          Button {
            showingGenreNotice = true
          } label: {
            Label(notice, systemImage: "info.circle")
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .help(notice)
          .popover(isPresented: $showingGenreNotice, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
              Text(notice)
                .font(.callout)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
              Button("Dismiss") {
                showingGenreNotice = false
                controller.dismissGenreImportNotice()
              }
            }
            .frame(width: 320, alignment: .leading)
            .padding()
          }
          .accessibilityLabel("Genre import notice")
        } else if let result = controller.snapshotResult {
          // A completed snapshot metadata-merge. Same calm, dismissible
          // chip idiom as the genre notice (macos-design: a status note,
          // not an alert) — its popover shows the full tally and the
          // Revert action that "appears after the import completes".
          Button {
            showingSnapshotResult = true
          } label: {
            Label(result.headline, systemImage: "clock.arrow.circlepath")
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .help(result.headline)
          .popover(isPresented: $showingSnapshotResult, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
              Text(result.details)
                .font(.callout)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
              HStack {
                if controller.canRevertSnapshot {
                  Button("Revert This Import", role: .destructive) {
                    showingSnapshotResult = false
                    Task { await controller.revertSnapshotImport() }
                  }
                }
                Spacer()
                Button("Dismiss") {
                  showingSnapshotResult = false
                  controller.dismissSnapshotResult()
                }
              }
            }
            .frame(width: 360, alignment: .leading)
            .padding()
          }
          .accessibilityLabel("Snapshot import result")
        }
        // No `else`: when idle the ToolbarItem renders nothing, so the
        // toolbar stays clean (the spec's EmptyView intent — an empty
        // ViewBuilder branch already produces no content; an explicit
        // `else { EmptyView() }` is redundant per swiftformat).
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          Task { await controller.refreshLibrary() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Refresh playlists (⌘R)")
        .disabled(controller.isLibraryBusy)
      }
      // The discoverable reveal affordance for the genre-graph panel. The
      // panel's own header chevron collapses it, but once collapsed a
      // faint chevron in a slim bottom bar is easy to miss — a toolbar
      // toggle is the discoverable, always-present control (mirroring the
      // inspector toggle below, the native Xcode/Numbers idiom). Bound to
      // the SAME `@SceneStorage` key as `GenreGraphPanel.collapsed`, so the
      // two controls stay in sync automatically within the scene.
      ToolbarItem(placement: .automatic) {
        Button {
          genreGraphCollapsed.toggle()
        } label: {
          Label("Genre Graph", systemImage: "point.3.connected.trianglepath.dotted")
        }
        .help(genreGraphCollapsed ? "Show the genre graph" : "Hide the genre graph")
      }
      // Standard macOS inspector toggle placement (trailing edge of the
      // toolbar, the side the panel slides from) — the native idiom
      // (Xcode / Freeform / Numbers). Reflects + flips presentation.
      ToolbarItem(placement: .automatic) {
        Button {
          inspectorPresented.toggle()
        } label: {
          Label("Inspector", systemImage: "sidebar.trailing")
        }
        .help("Show or hide the extension inspector")
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      NowPlayingBar()
    }
    // Catalog search sheet — the subordinate Phase-2 surface
    // (`plans/catalog-playlists.md`). Triggered by the Search menu
    // command ⇧⌘F via `controller.catalogSearchPresented`; the sheet
    // owns its own focus + dismiss. Sheet (not pane): macos-design
    // "appear when needed, get out of the way" — playlists stay first.
    .sheet(isPresented: Bindable(controller).catalogSearchPresented) {
      CatalogSearchSheet(isPresented: Bindable(controller).catalogSearchPresented)
    }
    // The genre-tree sheet (`plans/son-of-genre-map.md` Phase B).
    // Phase E retired the metro-era sibling sheet entirely; the tree
    // view is now the sole genre-visualisation surface. Reads its
    // substrate via `genreTreeService` and persists tree positions
    // back to `v9.genreMapState` after every successful build.
    .sheet(isPresented: Bindable(controller).genreTreeSheetPresented) {
      GenreTreeMapPanel()
    }
    // Document import/export (plans/snapshot-export-import.md). The
    // exporter's bytes are built off-main *before* its flag flips true
    // (`beginSnapshotExport`), so the document is always ready here.
    .fileExporter(
      isPresented: $controller.isPresentingSnapshotExporter,
      document: controller.snapshotExportDocument,
      contentType: .djroombaSnapshot,
      defaultFilename: Self.exportFilename(),
    ) { result in
      controller.completeSnapshotExport(result)
    }
    .fileImporter(
      isPresented: $controller.isPresentingSnapshotImporter,
      allowedContentTypes: [.djroombaSnapshot],
    ) { result in
      Task { await controller.completeSnapshotImport(result) }
    }
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller

  /// Per-scene persisted sidebar collapse state. Kept in the view layer
  /// (scene storage must not live inside an `@Observable`). The window
  /// frame itself is restored by macOS automatic state restoration.
  @SceneStorage("sidebarCollapsed") private var sidebarCollapsed = false
  /// Extension inspector visibility — **collapsed by default** (it's a
  /// readiness surface, not a primary feature). Per-scene persisted so a
  /// user who opens it keeps it open across relaunch.
  @SceneStorage("inspectorPresented") private var inspectorPresented = false
  /// Mirror of `GenreGraphPanel`'s collapse state — SAME `@SceneStorage`
  /// key, so the toolbar toggle and the panel's header chevron drive one
  /// shared value (SwiftUI keeps same-key scene storage in sync within the
  /// scene). Default `false` (expanded) must match the panel's default.
  @SceneStorage("genreGraphPanelCollapsed") private var genreGraphCollapsed = false

  @State private var columnVisibility = NavigationSplitViewVisibility.automatic

  /// Drives the `.status` failure affordance's popover (the full, selectable
  /// problem text). Non-modal, dismissible — a quiet readability surface, not
  /// a blocking alert.
  @State private var showingProblem = false

  /// Drives the neutral genre-import notice's popover (the full, selectable
  /// self-diagnosis + a Dismiss). Independent of `showingProblem` — the two
  /// affordances are mutually exclusive in the `.status` slot but each owns
  /// its own presentation state.
  @State private var showingGenreNotice = false

  /// Drives the Phase-0 catalog probe verdict's popover. Independent state,
  /// same calm idiom as `showingGenreNotice`; the probe branch takes priority
  /// in the `.status` slot so an explicitly-invoked diagnostic is never
  /// masked by ambient import/library state.
  @State private var showingCatalogProbe = false

  /// Drives the snapshot-import result chip's popover (the full tally +
  /// Revert / Dismiss). Independent of the other `.status` popovers.
  @State private var showingSnapshotResult = false

  /// "DJ Roomba Library 2026-05-18" — ISO date so it sorts and has no
  /// path-illegal `/`. `.fileExporter` appends the `djroomba` extension
  /// from the content type.
  private static func exportFilename() -> String {
    "DJ Roomba Library \(Date.now.ISO8601Format(.iso8601Date(timeZone: .current)))"
  }

}
