import BiteCore
import SwiftData
import SwiftUI

/// Where and when to go: every spot against the days ahead, coloured by the day's bite index.
/// Free shows today and tomorrow; the rest of the ten days are Pro.
struct PlannerView: View {
    @Query(sort: \Spot.createdAt) private var spots: [Spot]
    @Environment(EntitlementManager.self) private var entitlements
    @AppStorage(ForecastService.lastPrefetchKey) private var lastPrefetch = 0.0
    @State private var rows: [UUID: [DayOutlook]] = [:]
    @State private var loaded = false
    @State private var target: Target?
    @State private var showPaywall = false

    static let horizonDays = 10
    static let freeDays = EntitlementManager.freeDays

    /// A spot on a day, to open its forecast.
    struct Target: Hashable {
        let spotID: UUID
        let day: Date
    }

    private let nameWidth: CGFloat = 112
    private let cell = CGSize(width: 48, height: 48)
    private let gap: CGFloat = 6

    private var visibleDays: Int { entitlements.isPro ? Self.horizonDays : Self.freeDays }

    /// The days in the header: calendar dates, starting with the phone's today. A spot in
    /// another time zone puts each of its days under the same calendar date (see `day(for:)`),
    /// so a spot that is already in tomorrow starts one column to the right.
    private var dayLabels: [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<Self.horizonDays).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
    }

    /// Locked columns of the coming week that fall on a weekend: a free user planning
    /// Saturday on a Wednesday is looking exactly here.
    private var lockedWeekend: [Int] {
        guard !entitlements.isPro else { return [] }
        // The coming weekend only: it starts within the week, and may run a day past it.
        let weekend = (Self.freeDays..<Self.horizonDays).filter { Calendar.current.isDateInWeekend(dayLabels[$0]) }
        guard let first = weekend.first, first < 7 else { return [] }
        return weekend.enumerated().filter { $0.element == first + $0.offset }.map(\.element)
    }

    /// True when any spot has a strong window on a locked weekend day. Says no more than that.
    private var weekendLooksStrong: Bool {
        lockedWeekend.contains { column in
            spots.contains { (day(for: $0, column: column)?.index ?? 0) >= BiteAlerts.defaultThreshold }
        }
    }

    /// The single best spot-and-day in view.
    private var best: (spot: Spot, day: DayOutlook)? {
        var out: (spot: Spot, day: DayOutlook)?
        for spot in spots {
            for column in 0..<visibleDays where !isLocked(spot, column: column) {
                guard let day = day(for: spot, column: column), let index = day.index else { continue }
                if out == nil || index > (out?.day.index ?? 0) { out = (spot, day) }
            }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                if let best, let window = best.day.window {
                    Button {
                        target = Target(spotID: best.spot.id, day: best.day.date)
                    } label: {
                        BestDayCard(spotName: best.spot.name, day: best.day.date, window: window, timeZone: best.spot.timeZone)
                    }
                    .buttonStyle(.plain)
                }

                if spots.isEmpty {
                    Text("Add a fishing spot from the Map tab to see its bite windows.")
                        .foregroundStyle(.secondary)
                        .card()
                } else {
                    grid.card(padding: 12)
                    legend
                    // The day scores come from WeatherKit forecasts (5.2.5).
                    AppleWeatherAttribution()
                        .padding(.horizontal, 4)
                    if !entitlements.isPro {
                        if weekendLooksStrong {
                            Label("A strong bite is forecast this weekend", systemImage: BiteScale.symbol(BiteAlerts.defaultThreshold))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(BiteScale.color(BiteAlerts.defaultThreshold))
                                .frame(maxWidth: .infinity)
                        }
                        Button {
                            showPaywall = true
                        } label: {
                            Group {
                                if lockedWeekend.isEmpty {
                                    Label("Unlock all 10 days with BiteCurve Pro", systemImage: "lock.open.fill")
                                } else {
                                    Label("See the weekend with BiteCurve Pro", systemImage: "lock.open.fill")
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(Theme.accent)
                    }
                }
            }
            .frame(maxWidth: Theme.readableWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .screenBackground()
        .navigationTitle("Planner")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: "\(lastPrefetch)|\(entitlements.isPro)|\(spots.map { "\($0.id)\($0.waterRaw)\($0.speciesRaw)\($0.waterTempC ?? -999)" }.joined())") {
            let inputs = await DayOutlooks.inputs(for: spots)
            rows = await DayOutlooks.compute(inputs, days: Self.horizonDays + 1)
            loaded = true
        }
        .navigationDestination(item: $target) { target in
            if let spot = spots.first(where: { $0.id == target.spotID }) {
                SpotDetailView(spot: spot, initialDay: target.day)
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    /// Spot names stay put on the left; the days scroll sideways under their headers.
    private var grid: some View {
        HStack(alignment: .top, spacing: gap) {
            VStack(alignment: .leading, spacing: gap) {
                Color.clear.frame(width: nameWidth, height: 34)
                ForEach(spots) { spot in
                    Text(verbatim: spot.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(width: nameWidth, height: cell.height, alignment: .leading)
                }
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: gap) {
                    HStack(spacing: gap) {
                        ForEach(Array(dayLabels.enumerated()), id: \.offset) { offset, date in
                            VStack(spacing: 1) {
                                Text(verbatim: date.formatted(.dateTime.weekday(.abbreviated)))
                                    .font(.caption2.weight(.semibold))
                                    .textCase(.uppercase)
                                    .foregroundStyle(offset == 0 ? Theme.accent : .secondary)
                                Text(verbatim: date.formatted(.dateTime.day()))
                                    .font(.footnote.weight(.bold))
                                    .monospacedDigit()
                            }
                            .frame(width: cell.width, height: 34)
                        }
                    }
                    ForEach(spots) { spot in
                        HStack(spacing: gap) {
                            ForEach(0..<Self.horizonDays, id: \.self) { offset in
                                dayCell(spot: spot, offset: offset)
                            }
                        }
                    }
                }
                .padding(.trailing, 12)
            }
            .scrollIndicators(.hidden)
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 12)
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(spot: Spot, offset: Int) -> some View {
        let day = day(for: spot, column: offset)
        if isLocked(spot, column: offset) {
            Button {
                showPaywall = true
            } label: {
                let weekend = lockedWeekend.contains(offset)
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(weekend ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    .frame(width: cell.width, height: cell.height)
                    .background(Theme.well.opacity(0.6), in: .rect(cornerRadius: Theme.cellRadius, style: .continuous))
                    .overlay {
                        if weekend {
                            RoundedRectangle(cornerRadius: Theme.cellRadius, style: .continuous)
                                .strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1.5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("BiteCurve Pro"))
        } else if let day, let index = day.index {
            let isBest = best.map { $0.spot.id == spot.id && $0.day.date == day.date } ?? false
            Button {
                target = Target(spotID: spot.id, day: day.date)
            } label: {
                // Solid, outlined, dashed or flat by step, with its shape: readable without colour.
                ScoreTile(index: index, size: cell)
                    .overlay {
                        if isBest {
                            RoundedRectangle(cornerRadius: Theme.cellRadius + 3, style: .continuous)
                                .strokeBorder(Color.primary, lineWidth: 2)
                                .padding(-3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "\(spot.name), \(day.date.formatted(.dateTime.weekday(.wide).month().day(), in: spot.timeZone))"))
            .accessibilityValue(Text(verbatim: "\(Int(index.rounded())), \(BiteScale.label(index))"))
        } else {
            Text(verbatim: loaded ? "–" : "")
                .foregroundStyle(.secondary)
                .frame(width: cell.width, height: cell.height)
                .background(Theme.well.opacity(0.4), in: .rect(cornerRadius: Theme.cellRadius, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    /// Free users see the spot's own today and tomorrow, as on its detail screen. A spot whose
    /// clock is behind the phone's can put its day after tomorrow under the phone's tomorrow.
    private func isLocked(_ spot: Spot, column: Int) -> Bool {
        if column >= visibleDays { return true }
        guard !entitlements.isPro, let day = day(for: spot, column: column) else { return false }
        let calendar = spot.calendar
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()),
                                             to: calendar.startOfDay(for: day.date)).day ?? 0
        return offset >= Self.freeDays
    }

    /// The spot's day that falls on the header column's calendar date.
    private func day(for spot: Spot, column: Int) -> DayOutlook? {
        guard column < dayLabels.count else { return nil }
        let wanted = Calendar.current.dateComponents([.year, .month, .day], from: dayLabels[column])
        let calendar = spot.calendar
        return rows[spot.id]?.first { calendar.dateComponents([.year, .month, .day], from: $0.date) == wanted }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach([70.0, 57, 42, 20], id: \.self) { sample in
                HStack(spacing: 5) {
                    Image(systemName: BiteScale.symbol(sample))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(BiteScale.color(sample))
                    Text(verbatim: BiteScale.label(sample))
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 4)
        .accessibilityHidden(true)
    }
}

/// The best day in the planner, spelled out.
private struct BestDayCard: View {
    let spotName: String
    let day: Date
    let window: BiteWindow
    let timeZone: TimeZone

    var body: some View {
        HStack(spacing: 14) {
            IndexGauge(index: window.meanIndex, size: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text("Best in view")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(verbatim: spotName)
                    .font(.headline)
                    .lineLimit(1)
                Text(verbatim: "\(day.formatted(.dateTime.weekday(.wide).month().day(), in: timeZone)) · \(window.start.clock(in: timeZone)) – \(window.end.clock(in: timeZone))")
                    .font(.subheadline)
                    .foregroundStyle(BiteScale.color(window.meanIndex))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .card()
        .contentShape(.rect(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .combine)
    }
}
