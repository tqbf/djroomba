import SwiftUI

@main
struct PlaylistPlayerApp: App {
    @State private var controller = MusicController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(controller)
                .frame(minWidth: 920, minHeight: 600)
                .task { await controller.bootstrap() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 720)
        .commands {
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
}
