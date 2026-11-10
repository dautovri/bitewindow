import BackgroundTasks
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
        .modelContainer(OfflineStore.container)
        .backgroundTask(.appRefresh(OfflineStore.refreshTaskID)) {
            OfflineStore.scheduleBackgroundRefresh()
            _ = await OfflineStore.refresh()
        }
    }
}

/// Keeps every spot's forecast saved on the device for use without signal.
enum OfflineStore {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in project.yml.
    static let refreshTaskID = "com.dautovri.bitewindow.refresh"

    static let container: ModelContainer = {
        do {
            return try ModelContainer(for: Spot.self, Trip.self, PressureSample.self)
        } catch {
            fatalError("Cannot open the data store: \(error)")
        }
    }()

    static func places() -> [ForecastService.Place] {
        let context = ModelContext(container)
        let spots = (try? context.fetch(FetchDescriptor<Spot>())) ?? []
        return spots.map { .init(latitude: $0.latitude, longitude: $0.longitude, isSalt: $0.isSalt) }
    }

    /// Downloads forecasts for all spots.
    static func refresh() async -> (saved: Int, total: Int) {
        let all = places()
        let saved = await ForecastService.shared.prefetch(all)
        return (saved, all.count)
    }

    /// Asks iOS for a background refresh in about six hours. iOS decides when
    /// (and whether) it runs; opening the app with signal is the reliable path.
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}

struct RootView: View {
    @Environment(PressureSampler.self) private var sampler
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PressureSampler.enabledKey) private var livePressure = false
    @AppStorage(ForecastService.lastPrefetchKey) private var lastPrefetch = 0.0

    var body: some View {
        TabView {
            SpotsView().tabItem { Label("Forecast", systemImage: "chart.line.uptrend.xyaxis") }
            SpotMapView().tabItem { Label("Map", systemImage: "map") }
            LogView().tabItem { Label("Log", systemImage: "book") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.teal)
        .task { pruneSamples() }
        // Refresh saved forecasts whenever the app comes forward, at most hourly.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                if Date().timeIntervalSince1970 - lastPrefetch > 3600 {
                    Task { _ = await OfflineStore.refresh() }
                }
            } else if phase == .background {
                OfflineStore.scheduleBackgroundRefresh()
            }
        }
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
