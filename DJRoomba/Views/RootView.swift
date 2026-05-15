import SwiftUI
import MusicKit

/// Switches on authorization status. The authorized happy path goes straight
/// to the playlist shell; everything else explains itself inline.
struct RootView: View {
    @Environment(MusicController.self) private var controller

    var body: some View {
        switch controller.authorization.status {
        case .authorized:
            MainShellView()
        case .notDetermined:
            AuthorizationView(state: .request)
        case .denied:
            AuthorizationView(state: .denied)
        case .restricted:
            AuthorizationView(state: .restricted)
        @unknown default:
            AuthorizationView(state: .denied)
        }
    }
}
