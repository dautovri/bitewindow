import BiteCore
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
    @Environment(PressureSampler.self) private var sampler
    @Environment(\.modelContext) private var modelContext
    @AppStorage(PressureSampler.enabledKey) private var livePressure = false

    var body: some View {
        TabView {
            SpotsView().tabItem { Label("Forecast", systemImage: "chart.line.uptrend.xyaxis") }
            SpotMapView().tabItem { Label("Map", systemImage: "map") }
            LogView().tabItem { Label("Log", systemImage: "book") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.teal)
        .task { pruneSamples() }
        // `initial: true` restarts sampling on launch when the toggle was left on.
        .onChange(of: livePressure, initial: true) { _, on in
            if on {
                let context = modelContext
                sampler.start { hPa in
                    context.insert(PressureSample(time: Date(), stationHPa: hPa))
                }
            } else {
                sampler.stop()
            }
        }
    }

    private func pruneSamples() {
        let cutoff = Date().addingTimeInterval(-Barometry.sampleRetention)
        try? modelContext.delete(model: PressureSample.self, where: #Predicate { $0.time < cutoff })
    }
}
