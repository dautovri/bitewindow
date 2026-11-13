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
    static let refreshTaskID = "com.dautovri.bitecurve.refresh"

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
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            SpotsView(onAddSpot: { selectedTab = 1 })
                .tabItem { Label("Forecast", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(0)
            SpotMapView()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(1)
            LogView()
                .tabItem { Label("Log", systemImage: "book") }
                .tag(2)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(3)
        }
        .tint(.teal)
        .task {
            pruneSamples()
            #if DEBUG
            seedSampleSpotsIfAsked()
            #endif
        }
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

#if DEBUG
extension RootView {
    /// `-BCSeedSpots YES` fills an empty install with three sample spots and a
    /// short trip log, for screenshots and UI checks. Debug builds only.
    func seedSampleSpotsIfAsked() {
        guard UserDefaults.standard.bool(forKey: "BCSeedSpots"),
              ((try? modelContext.fetchCount(FetchDescriptor<Spot>())) ?? 0) == 0 else { return }
        let minnetonka = Spot(name: "Lake Minnetonka", latitude: 44.933, longitude: -93.563)
        minnetonka.species = .walleye
        minnetonka.water = .warmFreshwater
        let fork = Spot(name: "Lake Fork", latitude: 32.84, longitude: -95.58)
        fork.species = .largemouthBass
        fork.water = .warmFreshwater
        let montauk = Spot(name: "Lake Taneycomo", latitude: 36.66, longitude: -93.23)
        montauk.species = .rainbowTrout
        montauk.water = .coldFreshwater
        [minnetonka, fork, montauk].forEach(modelContext.insert)
        let day: TimeInterval = 86_400
        for (spot, daysAgo, hours, fish) in [(minnetonka, 2.0, 3.0, 4), (minnetonka, 9.0, 2.5, 0),
                                             (fork, 5.0, 4.0, 6), (montauk, 12.0, 3.5, 2)] {
            let trip = Trip(spot: spot)
            trip.startedAt = Date().addingTimeInterval(-daysAgo * day)
            trip.endedAt = trip.startedAt.addingTimeInterval(hours * 3600)
            trip.catchCount = fish
            modelContext.insert(trip)
        }
        try? modelContext.save()
    }
}
#endif
