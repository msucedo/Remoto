import SwiftUI

/// The standard Settings scene with icon tabs (DESIGN §4.4, §6.2.1). Each tab
/// sizes itself; the window follows with the system animation.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ConnectionSettings()
                .tabItem { Label("Connection", systemImage: "wifi") }
            DevicesSettings()
                .tabItem { Label("Devices", systemImage: "iphone") }
            DeckSettings()
                .tabItem { Label("Deck", systemImage: "square.grid.3x2") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560)
    }
}

extension View {
    /// A grouped form page. Each tab has its own height and the Settings
    /// window animates between them.
    func settingsPage(height: CGFloat) -> some View {
        formStyle(.grouped)
            .frame(height: height)
    }
}
