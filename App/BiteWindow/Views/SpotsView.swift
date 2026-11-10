import BiteCore
import Charts
import SwiftData
import SwiftUI

struct SpotsView: View {
    @Query(sort: \Spot.createdAt) private var spots: [Spot]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            Group {
                if spots.isEmpty {
                    ContentUnavailableView("No spots yet", systemImage: "mappin.and.ellipse",
                                           description: Text("Add a fishing spot from the Map tab to see its bite windows."))
                } else {
                    List {
                        ForEach(spots) { spot in
                            NavigationLink {
                                SpotDetailView(spot: spot)
                            } label: {
                                SpotRow(spot: spot)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { modelContext.delete(spots[index]) }
                        }
                    }
                }
            }
            .navigationTitle("Forecast")
        }
    }
}

/// List row: today's best window and its index for one spot.
private struct SpotRow: View {
    let spot: Spot
    @State private var window: BiteWindow?
    @State private var loaded = false

    private var subtitle: String {
        if let window {
            return "Best today \(window.start.formatted(date: .omitted, time: .shortened)) – \(window.end.formatted(date: .omitted, time: .shortened))"
        }
        return loaded ? "No forecast available" : "Loading…"
    }

    var body: some View {
        HStack(spacing: 12) {
            IndexGauge(index: window?.meanIndex, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(spot.name).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                Text(spot.species.displayName).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .task(id: "\(spot.waterRaw)|\(spot.speciesRaw)|\(spot.waterTempC ?? -999)") { await load() }
    }

    private func load() async {
        var context = spot.context
        if spot.isSalt {
            context.tide = await ForecastService.shared.tideStation(latitude: spot.latitude, longitude: spot.longitude)
        }
        let forecast = await ForecastService.shared.forecast(latitude: spot.latitude, longitude: spot.longitude)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if let end = calendar.date(byAdding: .day, value: 1, to: today) {
            let points = Forecaster.curve(context: context, hours: forecast.hours, from: today, to: end)
                .filter { $0.time < end }
            window = Forecaster.bestWindow(in: points)
        }
        loaded = true
    }
}

private struct DaySummary: Identifiable {
    let id: Date
    let window: BiteWindow?
    let points: [ScorePoint]
}

struct SpotDetailView: View {
    @Bindable var spot: Spot
    @Environment(EntitlementManager.self) private var entitlements
    @Query(sort: \PressureSample.time) private var samples: [PressureSample]
    @State private var forecast: Forecast?
    @State private var tide: TideStation?
    @State private var showPaywall = false

    private var isSalt: Bool { spot.isSalt }

    /// Spot context with tide attached for saltwater spots.
    private var context: SpotContext {
        var c = spot.context
        if isSalt { c.tide = tide }
        return c
    }

    /// Free: today and tomorrow. Pro: the full 10-day horizon.
    private func computeDays(pressure: Terms.PressureSeries?) -> [DaySummary] {
        guard let forecast, !forecast.hours.isEmpty else { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let count = entitlements.isPro ? 10 : 2
        guard let end = calendar.date(byAdding: .day, value: count, to: today) else { return [] }
        let points = Forecaster.curve(context: context, hours: forecast.hours, from: today, to: end,
                                      pressure: pressure)
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

    private func timeRange(_ window: BiteWindow) -> String {
        "\(window.start.formatted(date: .omitted, time: .shortened)) – \(window.end.formatted(date: .omitted, time: .shortened))"
    }

    private func expectedCatchText(_ day: DaySummary, _ window: BiteWindow) -> String {
        let fish = CatchModel.expectedCatch(points: day.points, from: window.start, to: window.end)
            * spot.catchMultiplier.mean
        return "\(fish.formatted(.number.precision(.fractionLength(1)))) fish"
    }

    /// Mean weighted contribution of each active factor over the window.
    private func factors(_ day: DaySummary, _ window: BiteWindow) -> [FactorBreakdown.Factor] {
        let inside = day.points.filter { $0.time >= window.start && $0.time <= window.end }
        guard !inside.isEmpty else { return [] }
        let n = Double(inside.count)
        func mean(_ pick: (Contributions) -> Double) -> Double {
            inside.reduce(0) { $0 + pick($1.contributions) } / n
        }
        var out: [FactorBreakdown.Factor] = [.init(name: "Light", value: mean { $0.light })]
        if spot.waterTempC != nil { out.append(.init(name: "Water temperature", value: mean { $0.thermal })) }
        out.append(.init(name: "Wind", value: mean { $0.wind }))
        out.append(.init(name: "Pressure trend", value: mean { $0.pressure }))
        out.append(.init(name: "Moon", value: mean { $0.solunar }))
        if isSalt, tide != nil { out.append(.init(name: "Tide", value: mean { $0.tide })) }
        return out
    }

    var body: some View {
        let pressure = livePressure
        let days = computeDays(pressure: pressure)
        List {
            statusSection(livePressure: pressure != nil)

            if let today = days.first {
                Section {
                    if let window = today.window {
                        HStack(spacing: 16) {
                            IndexGauge(index: window.meanIndex, size: 78)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Best window").font(.subheadline).foregroundStyle(.secondary)
                                Text(timeRange(window)).font(.title2.weight(.semibold)).monospacedDigit()
                                Text(BiteScale.label(window.meanIndex))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(BiteScale.color(window.meanIndex))
                            }
                        }
                        .padding(.vertical, 6)
                    } else {
                        Text("Not enough forecast left for today.").foregroundStyle(.secondary)
                    }
                    dayDetail(today)
                } header: {
                    Text(today.id.formatted(.dateTime.weekday(.wide).month().day()))
                }
            }

            if days.count > 1 {
                Section("Coming up") {
                    ForEach(Array(days.dropFirst())) { day in
                        if entitlements.isPro {
                            DisclosureGroup {
                                dayDetail(day)
                            } label: {
                                dayLabel(day)
                            }
                        } else {
                            dayLabel(day)
                        }
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
        .navigationBarTitleDisplayMode(.inline)
        .task { forecast = await ForecastService.shared.forecast(latitude: spot.latitude, longitude: spot.longitude) }
        .task(id: spot.waterRaw) {
            guard isSalt, tide == nil else { return }
            tide = await ForecastService.shared.tideStation(latitude: spot.latitude, longitude: spot.longitude)
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    @ViewBuilder
    private func statusSection(livePressure: Bool) -> some View {
        if let forecast {
            if forecast.source == .sample {
                Label("Sample weather — backend not configured", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if forecast.source == .cached {
                Label(forecast.hours.isEmpty ? "No forecast available offline" : "Offline — showing last saved forecast",
                      systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
            }
            if livePressure {
                Label("Pressure trend from your phone's barometer", systemImage: "barometer")
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack {
                ProgressView()
                Text("Loading forecast…").foregroundStyle(.secondary)
            }
        }
    }

    private func dayLabel(_ day: DaySummary) -> some View {
        HStack(spacing: 12) {
            IndexGauge(index: day.window?.meanIndex, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(day.id.formatted(.dateTime.weekday(.wide).month().day()))
                Text(day.window.map(timeRange) ?? "No forecast")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Pro: expected catch, hourly curve and factor breakdown. Everyone: tide times.
    @ViewBuilder
    private func dayDetail(_ day: DaySummary) -> some View {
        if entitlements.isPro {
            if let window = day.window {
                LabeledContent("Expected catch in window", value: expectedCatchText(day, window))
            }
            BiteCurveChart(points: day.points, window: day.window)
                .frame(height: 150)
                .padding(.vertical, 4)
            if let window = day.window {
                FactorBreakdown(factors: factors(day, window))
            }
        }
        if isSalt, let tide {
            let end = day.id.addingTimeInterval(86400)
            let extremes = tide.extremes(from: day.id, to: end)
            if !extremes.isEmpty {
                LabeledContent("Tides") {
                    Text(extremes.map { "\($0.isHigh ? "H" : "L") \($0.time.formatted(date: .omitted, time: .shortened))" }
                        .joined(separator: "  "))
                        .font(.footnote.monospacedDigit())
                }
            }
            if entitlements.isPro {
                TideChart(samples: tide.curve(from: day.id, to: end))
                    .frame(height: 100)
                    .padding(.vertical, 4)
            }
        }
    }
}
