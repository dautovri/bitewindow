import BiteCore
import Charts
import SwiftData
import SwiftUI

private struct DaySummary: Identifiable {
    let id: Date
    let window: BiteWindow?
    let points: [ScorePoint]
    /// A day past the free horizon: the date is real, the forecast is not shown.
    var isLocked = false

    /// No weather covered any part of the day: the score is sun, moon and tide only.
    var weatherless: Bool { !points.contains { $0.hasWeather } }
}

struct SpotDetailView: View {
    @Bindable var spot: Spot
    /// The day to open on (from the planner); nil opens on today.
    var initialDay: Date? = nil
    @Environment(EntitlementManager.self) private var entitlements
    @Query(sort: \PressureSample.time) private var samples: [PressureSample]
    @State private var forecast: Forecast?
    @State private var tide: TideStation?
    @State private var showPaywall = false
    /// The day the screen explains; nil means today.
    @State private var selectedDay: Date?
    /// Where the water temperature in the score comes from; set again when an estimate arrives,
    /// which also redraws the screen with it.
    @State private var waterReading: Spot.WaterReading?
    /// What is typed in the water temperature field (see `storeWaterTemperature`).
    @State private var waterText = ""
    /// A small picture of the share card for the share sheet's header.
    @State private var shareThumbnail: Image?
    @AppStorage(ForecastService.lastPrefetchKey) private var lastPrefetch = 0.0
    @AppStorage(CrossPromo.launchCountKey) private var launchCount = 0
    @AppStorage(CrossPromo.promoDoneKey) private var houbyPromoDone = false
    @AppStorage("didOnboard") private var didOnboard = false
    @State private var showHouby = false

    /// How far the day strip reaches.
    private static let horizonDays = 10
    /// Free: today and tomorrow.
    private static let freeDays = EntitlementManager.freeDays

    private var isSalt: Bool { spot.isSalt }

    /// Spot context with tide attached for saltwater spots.
    private var context: SpotContext {
        var c = spot.context
        if isSalt { c.tide = tide }
        return c
    }

    /// Free: today and tomorrow, then locked dates. Pro: the full 10-day horizon.
    private func computeDays(pressure: Terms.PressureSeries?) -> [DaySummary] {
        guard let forecast else { return [] }
        let calendar = spot.calendar
        let today = calendar.startOfDay(for: Date())
        let count = entitlements.isPro ? Self.horizonDays : Self.freeDays
        // Today's window starts no earlier than now; the curve still covers the whole day.
        var days = DayOutlooks.days(context: context, hours: forecast.hours, calendar: calendar, days: count, pressure: pressure)
            .filter { !$0.points.isEmpty }
            .map { DaySummary(id: $0.date, window: $0.window, points: $0.points) }
        if !entitlements.isPro {
            for offset in Self.freeDays..<Self.horizonDays {
                if let date = calendar.date(byAdding: .day, value: offset, to: today) {
                    days.append(DaySummary(id: date, window: nil, points: [], isLocked: true))
                }
            }
        }
        return days
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

    /// The side of the water the angler stands on, as the bearing from open water to that bank.
    private static let banks: [(degrees: Double, name: LocalizedStringKey)] = [
        (0, "North bank"), (45, "Northeast bank"), (90, "East bank"), (135, "Southeast bank"),
        (180, "South bank"), (225, "Southwest bank"), (270, "West bank"), (315, "Northwest bank"),
    ]

    /// The unit the forecast shows temperatures in (°F in the US), so the field matches it.
    private var temperatureUnit: UnitTemperature { UnitTemperature(forLocale: .current, usage: .weather) }

    /// The measured water temperature as the angler types it, in that unit. Kept as text
    /// while typing ("68." must not lose its dot); every valid state is stored in °C at once,
    /// and an empty field goes back to the estimate. Comma and dot both count as the decimal mark.
    private func storeWaterTemperature(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if trimmed.isEmpty {
            spot.waterTempC = nil
        } else if let value = Double(trimmed) {
            let celsius = Measurement(value: value, unit: temperatureUnit).converted(to: .celsius).value
            // Liquid water an angler can fish in.
            if (-3...40).contains(celsius) { spot.waterTempC = celsius }
        }
    }

    private func waterTemperatureString() -> String {
        guard let celsius = spot.waterTempC else { return "" }
        let value = Measurement(value: celsius, unit: UnitTemperature.celsius).converted(to: temperatureUnit).value
        return value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    }

    /// The estimate in use, shown greyed in the empty field ("≈ 6").
    private var estimatePrompt: String? {
        guard let waterReading, !waterReading.isMeasured else { return nil }
        let value = Measurement(value: waterReading.tempC, unit: UnitTemperature.celsius).converted(to: temperatureUnit).value
        return "≈ " + value.formatted(.number.precision(.fractionLength(0)))
    }

    /// Says where the temperature in the score comes from.
    private var waterSourceNote: LocalizedStringKey? {
        switch waterReading {
        case .satellite: return "Estimated from NOAA satellite sea-surface data. Type your own reading to replace it."
        case .modelled: return "Estimated from the last 30 days of air temperature. Type your own reading to replace it."
        case .measured: return "Your reading. Clear the field to go back to the estimate."
        case nil: return nil
        }
    }

    private func timeRange(_ window: BiteWindow) -> String {
        "\(window.start.clock(in: spot.timeZone)) – \(window.end.clock(in: spot.timeZone))"
    }

    private func expectedCatchText(_ day: DaySummary, _ window: BiteWindow) -> String {
        let fish = CatchModel.expectedCatch(points: day.points, from: window.start, to: window.end)
            * spot.catchMultiplier.mean
        return fish.formatted(.number.precision(.fractionLength(1)))
    }

    /// The moment a day's readings describe: the middle of its best window, now for today
    /// without one, otherwise midday.
    private func moment(_ day: DaySummary) -> Date {
        if let window = day.window { return window.start.addingTimeInterval(window.end.timeIntervalSince(window.start) / 2) }
        return spot.calendar.isDateInToday(day.id) ? Date() : day.id.addingTimeInterval(12 * 3600)
    }

    private func conditions(_ day: DaySummary) -> Conditions {
        Conditions(at: moment(day), hours: forecast?.hours ?? [], latitude: spot.latitude, longitude: spot.longitude,
                   calendar: spot.calendar)
    }

    /// Mean weighted contribution of each active factor over the window, with the reading behind it.
    private func factors(_ day: DaySummary, _ window: BiteWindow, _ conditions: Conditions) -> [FactorBreakdown.Factor] {
        let inside = day.points.filter { $0.time >= window.start && $0.time <= window.end }
        guard !inside.isEmpty else { return [] }
        let n = Double(inside.count)
        func mean(_ pick: (Contributions) -> Double) -> Double {
            inside.reduce(0) { $0 + pick($1.contributions) } / n
        }
        var out: [FactorBreakdown.Factor] = [
            .init(name: String(localized: "Light"), value: mean { $0.light }, symbol: conditions.cloudSymbol, reading: conditions.cloud)
        ]
        if let water = spot.waterReading {
            // In the same unit as the field it was typed into (°F in the US); "≈" marks an estimate.
            let degrees = Measurement(value: water.tempC, unit: UnitTemperature.celsius)
                .formatted(.measurement(width: .abbreviated, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
            let reading = water.isMeasured ? degrees : "≈ " + degrees
            out.append(.init(name: String(localized: "Water temperature"), value: mean { $0.thermal }, symbol: "thermometer.medium", reading: reading))
        }
        if !day.weatherless {
            out.append(.init(name: String(localized: "Wind"), value: mean { $0.wind }, symbol: "wind", reading: conditions.wind))
            out.append(.init(name: String(localized: "Pressure trend"), value: mean { $0.pressure }, symbol: "barometer",
                             reading: conditions.pressure, readingSymbol: conditions.pressureTrendSymbol))
        }
        out.append(.init(name: String(localized: "Moon"), value: mean { $0.solunar }, symbol: conditions.moonSymbol, reading: nil))
        // Without a station the tide term still counts: the moon phase stands in for spring and neap
        // tides. Its name says so, so the estimate never reads as tide data.
        if isSalt {
            out.append(.init(name: tide == nil ? String(localized: "Tide (moon-phase estimate)") : String(localized: "Tide"),
                             value: mean { $0.tide }, symbol: tide == nil ? conditions.moonSymbol : "water.waves", reading: nil))
        }
        return out
    }

    var body: some View {
        let pressure = livePressure
        let days = computeDays(pressure: pressure)
        let today = days.first
        let day = days.first { !$0.isLocked && $0.id == selectedDay } ?? today
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                statusBanner(livePressure: pressure != nil)

                if !days.isEmpty {
                    DayStrip(days: days.map { .init(date: $0.id, index: $0.window?.meanIndex, isLocked: $0.isLocked) },
                             selected: day?.id, timeZone: spot.timeZone) { tapped in
                        if tapped.isLocked {
                            showPaywall = true
                        } else {
                            withAnimation(.snappy) { selectedDay = tapped.date }
                        }
                    }
                    .padding(.horizontal, -16)
                }

                if let day {
                    let conditions = conditions(day)
                    heroCard(day, conditions)
                    conditionsCard(day, conditions)
                    AppleWeatherAttribution()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    if entitlements.isPro, let window = day.window {
                        FactorBreakdown(factors: factors(day, window, conditions)).card()
                    }
                    tideCard(day)
                    if CrossPromo.offersOnSpot(windowIndex: day.window?.meanIndex, launches: launchCount,
                                               didOnboard: didOnboard, done: houbyPromoDone) {
                        HoubySpotPromo {
                            houbyPromoDone = true
                            showHouby = true
                        } onDismiss: {
                            withAnimation { houbyPromoDone = true }
                        }
                    }
                }

                recordCard
                spotCard
                footer
            }
            .frame(maxWidth: Theme.readableWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .screenBackground()
        .navigationTitle(spot.name)
        .navigationBarTitleDisplayMode(.inline)
        // A pushed screen gets the full height; the tab bar comes back with the list.
        .toolbar(.hidden, for: .tabBar)
        // Also when forecasts are downloaded again while this screen is open.
        .task(id: lastPrefetch) {
            // Saved forecast first, so the screen fills at once with weak or no signal.
            if forecast == nil {
                forecast = ForecastService.shared.cached(latitude: spot.latitude, longitude: spot.longitude)
            }
            forecast = await ForecastService.shared.forecast(latitude: spot.latitude, longitude: spot.longitude)
            // In case this screen opened before the card on the Forecast tab had asked.
            await SpotTimeZone.resolveIfNeeded(spot)
        }
        .task(id: spot.waterRaw) {
            // A water changed to another habitat cannot keep its fish.
            spot.alignSpeciesWithWater()
            waterReading = spot.waterReading
            await ForecastService.shared.waterEstimate(latitude: spot.latitude, longitude: spot.longitude, isSalt: isSalt)
            waterReading = spot.waterReading
            guard isSalt, tide == nil else { return }
            tide = await ForecastService.shared.tideStation(latitude: spot.latitude, longitude: spot.longitude)
        }
        .onChange(of: spot.waterTempC) { waterReading = spot.waterReading }
        .onChange(of: waterText) { storeWaterTemperature(waterText) }
        .onAppear {
            waterText = waterTemperatureString()
            if selectedDay == nil { selectedDay = initialDay }
        }
        .toolbar {
            if let day, let window = day.window {
                ToolbarItem(placement: .primaryAction) {
                    let share = ForecastShare(spotName: spot.name, day: day.id, window: window, timeZone: spot.timeZone)
                    ShareLink(item: share, preview: SharePreview(Text(verbatim: spot.name), image: shareThumbnail ?? Image(systemName: "fish.fill"))) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    // Drawn once per day shown, not on every redraw of the screen.
                    .task(id: "\(day.id.timeIntervalSince1970)|\(window.start.timeIntervalSince1970)|\(Int(window.meanIndex))") {
                        shareThumbnail = share.thumbnail
                    }
                    #if DEBUG
                    // `-BCDumpShare YES` writes the card to the temp folder, to look at it in UI checks.
                    .task(id: day.id) {
                        if UserDefaults.standard.bool(forKey: "BCDumpShare"), let data = share.uiImage(scale: 2)?.pngData() {
                            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("share.png"))
                        }
                    }
                    #endif
                }
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .appStoreOverlay(isPresented: $showHouby) { CrossPromo.overlayConfiguration }
    }

    // MARK: Cards

    @ViewBuilder
    private func statusBanner(livePressure: Bool) -> some View {
        if let forecast {
            VStack(alignment: .leading, spacing: 6) {
                if forecast.source == .sample {
                    Label("Sample weather — backend not configured", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if forecast.source == .cached, forecast.unavailable != nil {
                    // Not for the saved copy shown while the download is still on its way.
                    Group {
                        if let saved = forecast.fetchedAt, !forecast.hours.isEmpty {
                            let ago = saved.formatted(.relative(presentation: .named))
                            if forecast.unavailable == .serviceBusy {
                                Label("Weather service busy — forecast saved \(ago)", systemImage: "clock.arrow.circlepath")
                            } else {
                                Label("Offline — forecast saved \(ago)", systemImage: "wifi.slash")
                            }
                        } else if forecast.unavailable == .serviceBusy {
                            Label("Weather service busy — no saved forecast. Sun, moon and tide only.", systemImage: "clock.arrow.circlepath")
                        } else {
                            Label("No weather data — sun, moon and tide only", systemImage: "wifi.slash")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                if livePressure {
                    Label("Pressure trend from your phone's barometer", systemImage: "barometer")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .padding(.horizontal, 4)
        } else {
            HStack {
                ProgressView()
                Text("Loading forecast…").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    /// The day's index and best window, the expected catch, and the weather in that window.
    private func heroCard(_ day: DaySummary, _ conditions: Conditions) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Away from the phone's own zone, say whose clock the times are on.
            Text(verbatim: day.id.formatted(.dateTime.weekday(.wide).month().day(), in: spot.timeZone)
                 + (spot.timeZone.secondsFromGMT(for: day.id) == TimeZone.current.secondsFromGMT(for: day.id)
                    ? "" : " · " + (spot.timeZone.abbreviation(for: day.id) ?? spot.timeZone.identifier)))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let window = day.window {
                HStack(spacing: 16) {
                    IndexGauge(index: window.meanIndex, size: 76)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Best window").font(.subheadline).foregroundStyle(.secondary)
                        Text(verbatim: timeRange(window))
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Text(BiteScale.label(window.meanIndex))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(BiteScale.color(window.meanIndex))
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                Text(spot.calendar.isDateInToday(day.id) ? "Not enough forecast left for today." : "No forecast")
                    .foregroundStyle(.secondary)
            }

            // The banner at the top already says so when there is no weather at all.
            if day.weatherless, forecast?.hours.isEmpty == false {
                Label("No weather data — sun, moon and tide only", systemImage: "moon.stars")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            chart(day, conditions)

            if let window = day.window {
                Divider().overlay(Theme.stroke)
                expectedCatchRow(day, window)
            }
        }
        .card()
    }

    /// The weather, sun and moon in the middle of the best window (now, without one).
    private func conditionsCard(_ day: DaySummary, _ conditions: Conditions) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if conditions.hour != nil {
                // The readings are for the middle of the window, not for now.
                Label {
                    Text(verbatim: moment(day).clock(in: spot.timeZone))
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            ConditionsGrid(conditions: conditions)
        }
        .card()
    }

    /// Pro: the number, with the personal multiplier it includes. Free: the label and a lock, no number.
    private func expectedCatchRow(_ day: DaySummary, _ window: BiteWindow) -> some View {
        HStack(spacing: 8) {
            Label("Expected fish in window", systemImage: "fish.fill")
                .font(.subheadline)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if entitlements.isPro {
                if tripCount > 0 {
                    Text(verbatim: "×\(spot.catchMultiplier.mean.formatted(.number.precision(.fractionLength(2))))")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 7)
                        .background(Theme.well, in: .capsule)
                        .accessibilityLabel(Text("Your catch rate here"))
                        .accessibilityValue(Text(verbatim: spot.catchMultiplier.mean.formatted(.number.precision(.fractionLength(2)))))
                }
                Text(verbatim: expectedCatchText(day, window))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            } else {
                Button {
                    showPaywall = true
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(8)
                        .background(Theme.well, in: .circle)
                }
                .accessibilityLabel(Text("See Pro plans"))
            }
        }
    }

    /// Pro: the day's curve, with the tide under it at saltwater spots. Free: the day's real
    /// frame (daylight, best window) with the curve withheld, never a made-up one.
    @ViewBuilder
    private func chart(_ day: DaySummary, _ conditions: Conditions) -> some View {
        let dayEnd = spot.calendar.date(byAdding: .day, value: 1, to: day.id) ?? day.id.addingTimeInterval(86_400)
        if entitlements.isPro {
            VStack(alignment: .leading, spacing: 16) {
                BiteCurveChart(points: day.points, window: day.window, sunrise: conditions.sunrise, sunset: conditions.sunset,
                               timeZone: spot.timeZone, showsTimeLabels: !(isSalt && tide != nil))
                    .frame(height: 190)
                if isSalt, let tide {
                    TideChart(samples: tide.curve(from: day.id, to: dayEnd), timeZone: spot.timeZone)
                        .frame(height: 84)
                }
            }
        } else {
            Button {
                showPaywall = true
            } label: {
                BiteCurveChart(points: [], window: day.window, sunrise: conditions.sunrise, sunset: conditions.sunset,
                               domain: day.id...dayEnd, timeZone: spot.timeZone)
                    .frame(height: 170)
                    .overlay {
                        Label("Unlock hourly curve, tide curve, expected catch and 10-day outlook", systemImage: "lock.fill")
                            .font(.footnote.weight(.semibold))
                            .multilineTextAlignment(.leading)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke, lineWidth: 1))
                            .padding(.horizontal, 24)
                    }
            }
            .buttonStyle(.plain)
        }
    }

    /// Everyone: tide times at saltwater spots, and where they come from.
    @ViewBuilder
    private func tideCard(_ day: DaySummary) -> some View {
        if isSalt {
            VStack(alignment: .leading, spacing: 10) {
                if let tide {
                    let end = spot.calendar.date(byAdding: .day, value: 1, to: day.id) ?? day.id.addingTimeInterval(86_400)
                    let extremes = tide.extremes(from: day.id, to: end)
                    if !extremes.isEmpty {
                        LabeledContent("Tides") {
                            Text(verbatim: extremes.map { "\($0.isHigh ? "▲" : "▼") \($0.time.clock(in: spot.timeZone))" }
                                .joined(separator: "  "))
                                .font(.footnote.monospacedDigit())
                        }
                    }
                    LabeledContent("Tide station", value: tide.name)
                    Text("Tide predictions from NOAA harmonic constants. Not for navigation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    // Outside NOAA's US stations: say plainly that there is no tide data, so the
                    // moon-phase estimate in the score is not taken for one.
                    Label("No tide data here — estimate from moon phase", systemImage: "moon.haze")
                        .font(.subheadline.weight(.semibold))
                    Text("No tide station found near this spot. The score estimates tide strength from the moon phase: spring tides at new and full moon.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .card()
        }
    }

    private var recordCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "Your record")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    RecordTile(symbol: "flag.checkered", value: "\(tripCount)", label: "Trips logged here")
                    if tripCount > 0 {
                        RecordTile(symbol: "fish.fill",
                                   value: "×\(spot.catchMultiplier.mean.formatted(.number.precision(.fractionLength(2))))",
                                   label: "Your catch rate here")
                    }
                }
                Text(tripCount == 0
                     ? "Log trips here, blank ones included, and the expected catch adapts to you."
                     : "Relative to the starting estimate. It moves slowly until about 20 trips are logged.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .card()
        }
    }

    private var spotCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "Spot")
            VStack(spacing: 6) {
                LabeledContent("Target species") {
                    Picker("Target species", selection: $spot.species) {
                        ForEach(Species.choices(for: spot.water), id: \.self) { Text(verbatim: $0.localizedName).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Divider().overlay(Theme.stroke)
                LabeledContent("Water") {
                    Picker("Water", selection: $spot.water) {
                        ForEach(WaterType.allCases, id: \.self) { Text(verbatim: $0.localizedName).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Divider().overlay(Theme.stroke)
                // Wind blowing onto the bank you stand on scores higher than wind off it.
                LabeledContent("Bank you fish from") {
                    Picker("Bank you fish from", selection: $spot.bankBearingDeg) {
                        Text("Not set").tag(Double?.none)
                        ForEach(Self.banks, id: \.degrees) { bank in
                            Text(bank.name).tag(Double?.some(bank.degrees))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Divider().overlay(Theme.stroke)
                LabeledContent("Water temperature") {
                    HStack(spacing: 4) {
                        TextField(text: $waterText, prompt: Text(verbatim: estimatePrompt ?? String(localized: "Optional"))) {
                            Text("Water temperature")
                        }
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: 80)
                        Text(verbatim: temperatureUnit.symbol)
                            .foregroundStyle(.secondary)
                    }
                    // Looks like a field to type in, next to the two pickers above it.
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.well, in: .rect(cornerRadius: 10, style: .continuous))
                }
                .padding(.vertical, 6)
                if let waterSourceNote {
                    Text(waterSourceNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .tint(Theme.accent)
            .card()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            AppleWeatherAttribution()
            Text("Bite windows are estimates from weather, sun, moon and tide. Fish don't read forecasts.")
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .tint(Theme.accent)
        .padding(.horizontal, 4)
    }
}

/// A number with its label on a recessed tile.
private struct RecordTile: View {
    let symbol: String
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(verbatim: value)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .well()
        .accessibilityElement(children: .combine)
    }
}

/// The days ahead as a row of capsules: weekday, date and the day's index. Days past the free
/// horizon show their real date and a lock, never a number.
struct DayStrip: View {
    struct Day: Identifiable, Equatable {
        let date: Date
        let index: Double?
        let isLocked: Bool
        var id: Date { date }
    }

    let days: [Day]
    let selected: Date?
    var timeZone: TimeZone = .current
    let onTap: (Day) -> Void

    var body: some View {
        let best = days.compactMap(\.index).max()
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(days) { day in
                    Button {
                        onTap(day)
                    } label: {
                        VStack(spacing: 5) {
                            Text(verbatim: day.date.formatted(.dateTime.weekday(.abbreviated), in: timeZone))
                                .font(.caption2.weight(.semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(day.date == selected ? Theme.accent : .secondary)
                            Text(verbatim: day.date.formatted(.dateTime.day(), in: timeZone))
                                .font(.callout.weight(.bold))
                                .monospacedDigit()
                            if day.isLocked {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 42, height: 34)
                                    .overlay(RoundedRectangle(cornerRadius: Theme.cellRadius, style: .continuous)
                                        .strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
                            } else if let index = day.index {
                                ScoreTile(index: index, size: CGSize(width: 42, height: 34), showsShape: false)
                            } else {
                                Text(verbatim: "–")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 42, height: 34)
                                    .background(Theme.well, in: .rect(cornerRadius: Theme.cellRadius, style: .continuous))
                            }
                            // The best day in view.
                            Circle()
                                .fill(day.index != nil && day.index == best ? BiteScale.color(day.index) : .clear)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }
                        .frame(minWidth: 48)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                        // Only the chosen day is marked; the rest sit on the background unboxed.
                        .background(day.date == selected ? Theme.accent.opacity(0.14) : .clear,
                                    in: .rect(cornerRadius: 16, style: .continuous))
                        .overlay {
                            if day.date == selected {
                                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5)
                            }
                        }
                        .contentShape(.rect(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: day.date.formatted(.dateTime.weekday(.wide).month().day(), in: timeZone)))
                    .accessibilityValue(day.isLocked
                                        ? Text("BiteCurve Pro")
                                        : Text(verbatim: day.index.map { "\(Int($0.rounded()))" } ?? "–"))
                    .accessibilityAddTraits(day.date == selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }
}
