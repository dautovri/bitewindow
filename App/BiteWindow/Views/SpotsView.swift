import BiteCore
import Charts
import SwiftData
import SwiftUI

extension WaterType {
    var localizedName: String {
        switch self {
        case .warmFreshwater: return String(localized: "Warm freshwater")
        case .coldFreshwater: return String(localized: "Cold freshwater")
        case .inshoreSalt: return String(localized: "Inshore saltwater")
        case .offshore: return String(localized: "Offshore")
        }
    }
}

/// The Forecast tab: one card per saved spot with today's index, best window and the weather now.
struct SpotsView: View {
    var onAddSpot: () -> Void = {}
    @Query(sort: \Spot.createdAt) private var spots: [Spot]
    @Environment(\.modelContext) private var modelContext
    @State private var opened: Spot?
    @Environment(EntitlementManager.self) private var entitlements
    @State private var showPlanner = false
    @State private var showTrialOffer = false

    var body: some View {
        NavigationStack {
            Group {
                if spots.isEmpty {
                    ContentUnavailableView {
                        Label("No spots yet", systemImage: "mappin.and.ellipse")
                    } description: {
                        Text("Add a fishing spot from the Map tab to see its bite windows.")
                    } actions: {
                        Button("Add your first spot", action: onAddSpot)
                            .buttonStyle(.borderedProminent)
                    }
                    .background(Theme.background.ignoresSafeArea())
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: Theme.readableWidth), spacing: Theme.gap)],
                                  spacing: Theme.gap) {
                            ForEach(spots) { spot in
                                Button {
                                    opened = spot
                                } label: {
                                    SpotCard(spot: spot)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        modelContext.delete(spot)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .accessibilityAction(named: Text("Delete")) { modelContext.delete(spot) }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        // The cards show WeatherKit readings (5.2.5). Outside the cards: each card is
                        // one button, and a link inside it could not be tapped on its own.
                        AppleWeatherAttribution()
                            .frame(maxWidth: Theme.readableWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                    }
                    .screenBackground()
                }
            }
            .navigationTitle("Forecast")
            .navigationDestination(item: $opened) { spot in
                SpotDetailView(spot: spot)
            }
            .navigationDestination(isPresented: $showPlanner) { PlannerView() }
            .toolbar {
                if !spots.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showPlanner = true
                        } label: {
                            Label("Planner", systemImage: "calendar")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onAddSpot) {
                        Label("Add spot", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showTrialOffer) { PaywallView() }
            // A spot added, removed or changed: the widgets and alerts follow.
            .task(id: spots.map { "\($0.id)\($0.name)\($0.waterRaw)\($0.speciesRaw)\($0.waterTempC ?? -999)" }.joined()) {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                await WidgetSnapshotWriter.update()
                await BiteAlerts.reschedule()
            }
            // Once, for someone who came through the welcome screen: after their first spot
            // has had time to show its forecast, offer the Pro trial.
            .task(id: spots.count) {
                guard spots.count == 1, !entitlements.isPro,
                      UserDefaults.standard.bool(forKey: WelcomeView.offerTrialKey) else { return }
                try? await Task.sleep(for: .seconds(8))
                // Not over a spot or the planner: wait until the list is in front again.
                while !Task.isCancelled, opened != nil || showPlanner {
                    try? await Task.sleep(for: .seconds(2))
                }
                guard !Task.isCancelled, !entitlements.isPro else { return }
                UserDefaults.standard.set(false, forKey: WelcomeView.offerTrialKey)
                showTrialOffer = true
            }
        }
    }
}

/// What a spot card shows, worked out from one forecast.
private struct SpotSnapshot {
    var today: BiteWindow?
    var tomorrow: BiteWindow?
    /// Today's curve, for the small chart.
    var points: [ScorePoint] = []
    var conditions: Conditions?
    /// Why the card shows a saved forecast; nil while it is live (or still loading).
    var unavailable: Forecast.Unavailable?
    var savedAt: Date?

    init() {}

    init(spot: Spot, context: SpotContext, forecast: Forecast, now: Date = Date(), calendar: Calendar = .current) {
        let days = DayOutlooks.days(context: context, hours: forecast.hours, calendar: calendar, days: 2, now: now)
        guard days.count == 2 else { return }
        points = days[0].points
        self.today = days[0].window
        self.tomorrow = days[1].window
        conditions = Conditions(at: now, hours: forecast.hours, latitude: spot.latitude, longitude: spot.longitude, calendar: calendar)
        if forecast.source == .cached {
            unavailable = forecast.unavailable
            savedAt = forecast.fetchedAt
        }
    }
}

/// One spot on the Forecast tab.
private struct SpotCard: View {
    let spot: Spot
    @Environment(EntitlementManager.self) private var entitlements
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var snapshot = SpotSnapshot()
    @State private var loaded = false
    /// Changes when forecasts are downloaded again, so the card reloads.
    @AppStorage(ForecastService.lastPrefetchKey) private var lastPrefetch = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: spot.name)
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if spot.species != .general {
                            spot.species.image
                                .resizable()
                                .scaledToFit()
                                .frame(width: 34, height: 18)
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: spot.isSalt ? "water.waves" : "drop.fill")
                                .foregroundStyle(Theme.ink2)
                                .accessibilityHidden(true)
                        }
                        Text(verbatim: "\(spot.species.localizedName) · \(spot.water.localizedName)")
                            // One line normally; at accessibility text sizes it wraps rather than cuts off.
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            .minimumScaleFactor(0.8)
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink2)
                }
                Spacer(minLength: 8)
                IndexGauge(index: snapshot.today?.meanIndex, size: 60)
            }

            // The verdict first: today's window, with the day's shape (Pro) or tomorrow (free) beside it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    windowPill.fixedSize()
                    Spacer(minLength: 0)
                    trailingPreview
                }
                VStack(alignment: .leading, spacing: 10) {
                    windowPill
                    trailingPreview
                }
            }
            .padding(6)
            .background(Theme.well.opacity(0.6), in: .rect(cornerRadius: Theme.wellRadius + 6, style: .continuous))

            if let conditions = snapshot.conditions {
                VStack(alignment: .leading, spacing: 8) {
                    if conditions.hour != nil {
                        Text("Now")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.ink2)
                            .textCase(.uppercase)
                            .tracking(0.5)
                    }
                    WeatherStrip(conditions: conditions)
                    SunMoonStrip(conditions: conditions)
                }
                if let unavailable = snapshot.unavailable {
                    Group {
                        if let saved = snapshot.savedAt {
                            let ago = saved.formatted(.relative(presentation: .named))
                            if unavailable == .serviceBusy {
                                Label("Weather service busy — forecast saved \(ago)", systemImage: "clock.arrow.circlepath")
                            } else {
                                Label("Offline — forecast saved \(ago)", systemImage: "wifi.slash")
                            }
                        } else if unavailable == .serviceBusy {
                            Label("Weather service busy — no saved forecast. Sun, moon and tide only.", systemImage: "clock.arrow.circlepath")
                        } else {
                            // Nothing saved: the index on this card is sun and moon only, so say so.
                            Label("No weather data — sun, moon and tide only", systemImage: "wifi.slash")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .card()
        .contentShape(.rect(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .combine)
        .task(id: "\(spot.waterRaw)|\(spot.speciesRaw)|\(spot.waterTempC ?? -999)|\(spot.timeZoneID ?? "")|\(lastPrefetch)") { await load() }
    }

    /// Today's best window, or why there is none.
    @ViewBuilder private var windowPill: some View {
        if let window = snapshot.today {
            let color = BiteScale.color(window.meanIndex)
            Label {
                Text(verbatim: "\(window.start.clock(in: spot.timeZone)) – \(window.end.clock(in: spot.timeZone))")
                    .monospacedDigit()
            } icon: {
                Image(systemName: "clock.fill")
            }
            .font(.callout.weight(.bold))
            .foregroundStyle(color)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(color.opacity(0.14), in: .capsule)
            .accessibilityLabel(Text("Best today \(window.start.clock(in: spot.timeZone)) – \(window.end.clock(in: spot.timeZone))"))
        } else {
            // Sun and moon fill any gap in the weather, so a missing window means the day is nearly over.
            Text(loaded ? "Not enough forecast left for today." : "Loading…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// Pro: today's curve in small. Free: tomorrow's index, which the free tier includes.
    @ViewBuilder private var trailingPreview: some View {
        if entitlements.isPro {
            if snapshot.points.count > 1 {
                MiniCurve(points: snapshot.points, window: snapshot.today, color: BiteScale.color(snapshot.today?.meanIndex))
                    .frame(minWidth: 96, maxWidth: .infinity)
                    .frame(height: 36)
                    .padding(.trailing, 8)
            }
        } else if let tomorrow = snapshot.tomorrow {
            HStack(spacing: 6) {
                Text("Tomorrow").foregroundStyle(.secondary)
                Circle().fill(BiteScale.color(tomorrow.meanIndex)).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(verbatim: "\(Int(tomorrow.meanIndex.rounded()))")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.subheadline)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Theme.well, in: .capsule)
            .fixedSize()
        }
    }

    private func load() async {
        var context = spot.context
        // Saved forecast first, so the card fills at once with weak or no signal;
        // the network result (up to the 10 s timeout) replaces it.
        if let saved = ForecastService.shared.cached(latitude: spot.latitude, longitude: spot.longitude) {
            snapshot = SpotSnapshot(spot: spot, context: context, forecast: saved, calendar: spot.calendar)
            loaded = true
        }
        // Tide and forecast at the same time: with no signal each can take the full timeout.
        let (latitude, longitude, isSalt) = (spot.latitude, spot.longitude, spot.isSalt)
        async let tideRequest = isSalt ? ForecastService.shared.tideStation(latitude: latitude, longitude: longitude) : nil
        async let forecastRequest = ForecastService.shared.forecast(latitude: latitude, longitude: longitude)
        let (tide, forecast) = await (tideRequest, forecastRequest)
        // Shown now, not after the water estimate's own wait; redrawn once that is in.
        context.tide = tide
        snapshot = SpotSnapshot(spot: spot, context: context, forecast: forecast, calendar: spot.calendar)
        loaded = true
        // The water estimate feeds the score; the context is rebuilt once it is in.
        await ForecastService.shared.waterEstimate(latitude: latitude, longitude: longitude, isSalt: isSalt)
        context = spot.context
        context.tide = tide
        snapshot = SpotSnapshot(spot: spot, context: context, forecast: forecast, calendar: spot.calendar)
        // Once the spot's zone is known the card redraws in it (the zone is part of the task id).
        await SpotTimeZone.resolveIfNeeded(spot)
    }
}

/// Today's curve without axes: the best window shaded, so the peak lines up with the times
/// beside it, a dashed neutral 50, and a dot at the current time.
private struct MiniCurve: View {
    let points: [ScorePoint]
    let window: BiteWindow?
    let color: Color

    var body: some View {
        let now = Date()
        let current = points.min { abs($0.time.timeIntervalSince(now)) < abs($1.time.timeIntervalSince(now)) }
        Chart {
            if let window {
                RectangleMark(xStart: .value("Window start", window.start), xEnd: .value("Window end", window.end))
                    .foregroundStyle(color.opacity(0.16))
            }
            RuleMark(y: .value("Neutral", 50))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .foregroundStyle(Color.secondary.opacity(0.45))
            ForEach(points, id: \.time) { point in
                AreaMark(x: .value("Time", point.time), y: .value("Index", point.index))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.25), color.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.time), y: .value("Index", point.index))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            if let current, abs(current.time.timeIntervalSince(now)) < 3600 {
                PointMark(x: .value("Time", current.time), y: .value("Index", current.index))
                    .symbolSize(36)
                    .foregroundStyle(color)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }
}
