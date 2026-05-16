import SwiftUI

/// The user-owned "My Playlists" sidebar section (Phase 4): inline create
/// from the section header, modal rename, destructive delete confirmation,
/// drag-to-reorder. Per-row affordances (context menu, song drop target) live
/// in `AppPlaylistRowItem`. SQLite-only — never written back to Apple Music.
///
/// Phase-4 D1: rename moved from an inline-in-`List` `TextField` to the modal
/// `RenamePlaylistSheet`. The inline editor's `@FocusState` competed with the
/// `List`'s own first-responder/selection handling so commit-on-blur was
/// inconsistent across triggers, and a double-click-to-rename gesture
/// collided with the `List`'s double-click/Return "play" behavior. The sheet
/// is trigger-independent and commits identically every time; the trigger is
/// now context-menu-only.
struct AppPlaylistSidebarSection: View {
    let summaries: [PlaylistSummary]
    @Environment(MusicController.self) private var controller

    /// The playlist being renamed (nil = no sheet). `sheet(item:)` so the
    /// optional is safely unwrapped (swiftui-pro).
    @State private var renameRequest: PlaylistRenameRequest?
    /// A just-created playlist whose rename sheet should open as soon as it
    /// appears in `summaries` (the native "new untitled item, rename it"
    /// flow). Deferred via `summaries` change so it's deterministic — the
    /// store reload is async, so the new row may not be in `summaries` yet
    /// when `create` returns.
    @State private var pendingRenameAfterCreateID: String?
    /// Pending destructive delete + whether the dialog is shown. Two fields
    /// so the `confirmationDialog` uses a clean `$Bool` binding (no
    /// `Binding(get:set:)`), with the playlist passed via `presenting:`.
    @State private var pendingDelete: PlaylistSummary?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        Section {
            ForEach(summaries) { summary in
                AppPlaylistRowItem(
                    summary: summary,
                    beginRename: { beginRename(summary) },
                    requestDelete: { requestDelete(summary) }
                )
            }
            .onMove(perform: reorder)
        } header: {
            HStack {
                Text("My Playlists")
                Spacer()
                Button("New Playlist", systemImage: "plus", action: createPlaylist)
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .help("New Playlist (⌘N)")
            }
        }
        .onChange(of: summaries) { _, newValue in
            openPendingRenameIfReady(in: newValue)
        }
        .sheet(item: $renameRequest) { request in
            RenamePlaylistSheet(
                request: request,
                onCommit: { commitRename(request.id, to: $0) },
                onCancel: { renameRequest = nil }
            )
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { summary in
            Button("Delete Playlist", role: .destructive) {
                Task { await controller.deleteAppPlaylist(summary.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the playlist from DJ Roomba. Your songs and their play counts are not affected.")
        }
    }

    private func beginRename(_ summary: PlaylistSummary) {
        renameRequest = PlaylistRenameRequest(id: summary.id, currentName: summary.name)
    }

    private func commitRename(_ id: String, to newName: String) {
        renameRequest = nil
        Task { await controller.renameAppPlaylist(id, to: newName) }
    }

    private func createPlaylist() {
        Task {
            if let id = await controller.createAppPlaylist() {
                // Open rename once the new row lands in `summaries` (the
                // store reload is async — it may not be there yet).
                pendingRenameAfterCreateID = id
                openPendingRenameIfReady(in: summaries)
            }
        }
    }

    /// If a just-created playlist is now present, open its rename sheet once.
    private func openPendingRenameIfReady(in list: [PlaylistSummary]) {
        guard let id = pendingRenameAfterCreateID,
              let created = list.first(where: { $0.id == id }) else { return }
        pendingRenameAfterCreateID = nil
        renameRequest = PlaylistRenameRequest(id: created.id, currentName: created.name)
    }

    private func requestDelete(_ summary: PlaylistSummary) {
        pendingDelete = summary
        showingDeleteConfirmation = true
    }

    private func reorder(_ indices: IndexSet, _ newOffset: Int) {
        var ordered = summaries.map(\.id)
        ordered.move(fromOffsets: indices, toOffset: newOffset)
        Task { await controller.reorderAppPlaylists(ordered) }
    }
}
