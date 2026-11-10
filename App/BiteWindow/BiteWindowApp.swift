import SwiftData
import SwiftUI

@main
struct BiteWindowApp: App {
    @State private var entitlements = EntitlementManager()
    @State private var sampler = PressureSampler()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(entitlements)
                .environment(sampler)
        }
        .modelContainer(for: [Spot.self, Trip.self, PressureSample.self])
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            SpotsView().tabItem { Label("Forecast", systemImage: "chart.line.uptrend.xyaxis") }
            SpotMapView().tabItem { Label("Map", systemImage: "map") }
            LogView().tabItem { Label("Log", systemImage: "book") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
