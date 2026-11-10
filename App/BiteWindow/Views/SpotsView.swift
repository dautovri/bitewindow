import BiteCore
import Charts
import SwiftData
import SwiftUI

struct SpotsView: View {
    @Query(sort: \Spot.createdAt) private var spots: [Spot]

    var body: some View {
        NavigationStack {
            Group {
                if spots.isEmpty {
                    ContentUnavailableView("No spots yet", systemImage: "mappin.and.ellipse",
                                           description: Text("Add a fishing spot from the Map tab to see its bite windows."))
                } else {
                    List(spots) { spot in
                        NavigationLink(spot.name) { SpotDetailView(spot: spot) }
                    }
                }
            }
            .navigationTitle("Forecast")
        }
    }
}

struct SpotDetailView: View {
    @Bindable var spot: Spot
    @Environment(EntitlementManager.self) private var entitlements
    @Query(sort: \PressureSample.time) private var samples: [PressureSample]
    @State private var forecast: Forecast?
    @State private var tide: TideStation?
    @State private var showPaywall = false

    private var isSalt: Bool { spot.water == .inshoreSalt || spot.water == .offshore }

    /// Spot context with tide attached for saltwater spots.
    private var context: SpotContext {
        var c = spot.context
        if isSalt { c.tide = tide }
        return c
    }

    private struct DaySummary: Identifiable {
        let id: Date
        let window: BiteWindow?
        let points: [ScorePoint]
    }

    /// Free: today and tomorrow. Pro: the full 10-day horizon.
    private var days: [DaySummary] {
        guard let forecast, !forecast.hours.isEmpty else { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let count = entitlements.isPro ? 10 : 2
        guard let end = calendar.date(byAdding: .day, value: count, to: today) else { return [] }
        let points = Forecaster.curve(context: context, hours: forecast.hours, from: today, to: end,
                                      pressure: livePressure)
        return Dictionary(grouping: points) { calendar.startOfDay(for: $0.time) }
            .filter { $0.key < end }
            .map { DaySummary(id: $0.key, window: Forecaster.bestWindow(in: $0.value), points: $0.value) }
            .sorted { $0.id < $1.id }
    }

    /// Phone barometer readings can stand in for the forecast only while a trip
    /// is running here: that is the only time the phone is known to be at the spot.
    private var livePressure: Terms.PressureSeries? {
        guard let forecast, forecast.source != .sample, let trip = spot.activeTrip else { return nil }
        let device = samples.filter { $0.time >= trip.startedAt }.map { (time: $0.time, hPa: $0.stationHPa) }
        let base = forecast.hours.map { (time: $0.time, hPa: $0.pressureHPa) }
        let fused = Barometry.fuse(forecast: base, device: device)
        // `fuse` hands back the forecast untouched when the readings are unusable.
        let forecastTimes = Set(base.map(\.time))
        return fused.contains { !forecastTimes.contains($0.time) } ? Terms.PressureSeries(fused) : nil
    }

    private var tripCount: Int { spot.fittedTrips.count }

    private func expectedCatchText(_ day: DaySummary, _ window: BiteWindow) -> String {
        let fish = CatchModel.expectedCatch(points: day.points, from: window.start, to: window.end)
            * spot.catchMultiplier.mean
        return "\(fish.formatted(.number.precision(.fractionLength(1)))) fish"
    }

    var body: some View {
        List {
            if let forecast {
                if forecast.source == .sample {
                    Label("Sample weather — backend not configured", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if forecast.source == .cached {
                    Label(forecast.hours.isEmpty ? "No forecast available offline" : "Offline — showing last saved forecast",
                          systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                }
                if livePressure != nil {
                    Label("Pressure trend from your phone's barometer", systemImage: "barometer")
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }

            ForEach(days) { day in
                Section(day.id.formatted(date: .complete, time: .omitted)) {
                    if let window = day.window {
                        LabeledContent("Best window") {
                            Text("\(window.start.formatted(date: .omitted, time: .shortened)) – \(window.end.formatted(date: .omitted, time: .shortened))")
                        }
                        LabeledContent("Bite index", value: "\(Int(window.meanIndex.rounded())) / 100")
                    }
                    if entitlements.isPro, let window = day.window {
                        LabeledContent("Expected catch in window", value: expectedCatchText(day, window))
                    }
                    if isSalt, let tide {
                        let next = tide.extremes(from: day.id, to: day.id.addingTimeInterval(86400))
                        if !next.isEmpty {
                            LabeledContent("Tides") {
                                Text(next.map { "\($0.isHigh ? "H" : "L") \($0.time.formatted(date: .omitted, time: .shortened))" }
                                    .joined(separator: "  "))
                                    .font(.footnote.monospacedDigit())
                            }
                        }
                        if entitlements.isPro {
                            Chart(tide.curve(from: day.id, to: day.id.addingTimeInterval(86400)), id: \.time) { sample in
                                LineMark(x: .value("Time", sample.time), y: .value("Tide (m)", sample.height))
                                    .interpolationMethod(.catmullRom)
                            }
                            .foregroundStyle(.teal)
                            .frame(height: 100)
                        }
                    }
                    if entitlements.isPro {
                        Chart(day.points, id: \.time) { point in
                            LineMark(x: .value("Time", point.time), y: .value("Index", point.index))
                        }
                        .chartYScale(domain: 0...100)
                        .frame(height: 140)
                    }
                }
            }

            if !entitlements.isPro {
                Section {
                    Button {
                        showPaywall = true
                    } label: {
                        Label("Unlock hourly curve, tide curve, expected catch and 10-day outlook", systemImage: "lock")
                    }
                }
            }

            Section {
                LabeledContent("Trips logged here", value: "\(tripCount)")
                if tripCount > 0 {
                    LabeledContent("Your catch rate here",
                                   value: "×\(spot.catchMultiplier.mean.formatted(.number.precision(.fractionLength(2))))")
                }
            } header: {
                Text("Your record")
            } footer: {
                Text(tripCount == 0
                     ? "Log trips here, blank ones included, and the expected catch adapts to you."
                     : "Relative to the starting estimate. It moves slowly until about 20 trips are logged.")
            }

            Section("Spot") {
                Picker("Target species", selection: $spot.species) {
                    ForEach(Species.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Water", selection: $spot.water) {
                    Text("Warm freshwater").tag(WaterType.warmFreshwater)
                    Text("Cold freshwater").tag(WaterType.coldFreshwater)
                    Text("Inshore saltwater").tag(WaterType.inshoreSalt)
                    Text("Offshore").tag(WaterType.offshore)
                }
                TextField("Water temperature °C (optional)", value: $spot.waterTempC, format: .number)
                    .keyboardType(.decimalPad)
            }

            if isSalt {
                Section {
                    if let tide {
                        LabeledContent("Tide station", value: tide.name)
                    } else {
                        Text("No tide station found near this spot. The score runs without tide.")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Tide predictions from NOAA harmonic constants. Not for navigation.")
                }
            }

            Section {
                Link("Weather data: Apple Weather — legal attribution",
                     destination: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!)
                    .font(.footnote)
            }
        }
        .navigationTitle(spot.name)
        .task { forecast = await ForecastService.shared.forecast(latitude: spot.latitude, longitude: spot.longitude) }
        .task(id: spot.waterRaw) {
            guard isSalt, tide == nil else { return }
            tide = await ForecastService.shared.tideStation(latitude: spot.latitude, longitude: spot.longitude)
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }
}
