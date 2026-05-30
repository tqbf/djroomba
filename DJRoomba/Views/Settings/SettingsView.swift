import SwiftUI

/// The app's Settings window (⌘,). Two panes — **Advanced** (genre-analysis
/// thresholds) and **OpenAI** (GPT API key + connection test) — in the
/// standard macOS tabbed-Settings chrome. Fixed size: a Settings window
/// doesn't resize to content the way a document window does.
struct SettingsView: View {
  var body: some View {
    TabView {
      GenreAnalysisAdvancedPane()
        .tabItem {
          Label("Advanced", systemImage: "slider.horizontal.3")
        }
      OpenAISettingsPane()
        .tabItem {
          Label("OpenAI", systemImage: "sparkles")
        }
    }
    .frame(width: 520, height: 440)
  }
}
