import SwiftUI

/// The app's Settings window (⌘,). One pane today — **Advanced** — in the
/// standard macOS tabbed-Settings chrome, so it reads as a real Settings
/// window now and adding more panes later is a one-liner. Fixed size: a
/// Settings window doesn't resize to content the way a document window does.
struct SettingsView: View {
  var body: some View {
    TabView {
      GenreAnalysisAdvancedPane()
        .tabItem {
          Label("Advanced", systemImage: "slider.horizontal.3")
        }
    }
    .frame(width: 520, height: 320)
  }
}
