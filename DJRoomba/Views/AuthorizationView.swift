import SwiftUI

/// First-run / no-access screen. Drives the user to authorize Apple Music,
/// or explains why access isn't available. Centered, calm, one clear action.
struct AuthorizationView: View {
    enum Mode { case request, denied, restricted }

    let state: Mode
    @Environment(MusicController.self) private var controller
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("DJ Roomba")
                .font(.largeTitle.weight(.semibold))

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            actionButton
                .padding(.top, 4)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var message: String {
        switch state {
        case .request:
            "DJ Roomba plays the playlists in your Apple Music library. Allow access to get started."
        case .denied:
            "DJ Roomba doesn't have permission to use Apple Music. Enable it in System Settings → Privacy & Security → Media & Apple Music, then reopen the app."
        case .restricted:
            "Apple Music access is restricted on this Mac, for example by Screen Time or device management."
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .request:
            Button(action: requestAccess) {
                Text(isRequesting ? "Requesting…" : "Allow Apple Music Access")
                    .frame(minWidth: 200)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(isRequesting)

        case .denied:
            Button("Open System Settings", action: openMediaPrivacySettings)
                .controlSize(.large)

        case .restricted:
            EmptyView()
        }
    }

    private func requestAccess() {
        isRequesting = true
        Task {
            await controller.requestAuthorization()
            isRequesting = false
        }
    }

    private func openMediaPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
