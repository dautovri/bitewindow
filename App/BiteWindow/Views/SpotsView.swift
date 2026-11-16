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
    var isOffline = false

    init() {}

    init(spot: Spot, context: SpotContext, forecast: Forecast, now: Date = Date(), calendar: Calendar = .current) {
        let days = DayOutlooks.days(context: context, hours: forecast.hours, calendar: calendar, days: 2, now: now)
        guard days.count == 2 else { return }
        points = days[0].points
        self.today = days[0].window
        self.tomorrow = days[1].window
        conditions = Conditions(at: now, hours: forecast.hours, latitude: spot.latitude, longitude: spot.longitude, calendar: calendar)
        isOffline = forecast.source == .cached
    }
}

/// One spot on the Forecast tab.
private struct SpotCard: View {
    let spot: Spot
    @Environment(EntitlementManager.self) private var entitlements
    @State private var snapshot = SpotSnapshot()
    @State private var loaded = false
    /// Changes when forecasts are downloaded again, so the card reloads.
    @AppStorage(ForecastService.lastPrefetchKey) private var lastPrefetch = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: spot.name)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                    Label {
                        Text(verbatim: "\(spot.species.localizedName) · \(spot.water.localizedName)")
                    } icon: {
                        Image(systemName: spot.isSalt ? "water.waves" : "drop.fill")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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

            if let conditions = snapshot.conditions {
                if conditions.hour != nil {
                    Text("Now")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.top, 2)
                }
                ConditionsGrid(conditions: conditions)
                if snapshot.isOffline {
                    Label("Offline", systemImage: "wifi.slash")
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
                MiniCurve(points: snapshot.points, color: BiteScale.color(snapshot.today?.meanIndex))
                    .frame(minWidth: 96, maxWidth: .infinity)
                    .frame(height: 36)
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
        let tide = spot.isSalt
            ? await ForecastService.shared.tideStation(latitude: spot.latitude, longitude: spot.longitude) : nil
        let forecast = await ForecastService.shared.forecast(latitude: spot.latitude, longitude: spot.longitude)
        // The water estimate feeds the score; the context is rebuilt once it is in.
        await ForecastService.shared.waterEstimate(latitude: spot.latitude, longitude: spot.longitude, isSalt: spot.isSalt)
        context = spot.context
        context.tide = tide
        snapshot = SpotSnapshot(spot: spot, context: context, forecast: forecast, calendar: spot.calendar)
        loaded = true
        // Once the spot's zone is known the card redraws in it (the zone is part of the task id).
        await SpotTimeZone.resolveIfNeeded(spot)
    }
}

/// Today's curve without axes, with a dot at the current time.
private struct MiniCurve: View {
    let points: [ScorePoint]
    let color: Color

    var body: some View {
        let now = Date()
        let current = points.min { abs($0.time.timeIntervalSince(now)) < abs($1.time.timeIntervalSince(now)) }
        Chart {
            ForEach(points, id: \.time) { point in
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
