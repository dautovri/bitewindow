import BiteCore
import SwiftData
import SwiftUI
import os

/// Trip log. Ending a trip with zero fish is a single tap, because blank trips
/// are what make the catch-rate model honest.
struct LogView: View {
    @Query(sort: \Trip.startedAt, order: .reverse) private var trips: [Trip]
    @Query(sort: \Spot.createdAt) private var spots: [Spot]
    @Environment(\.modelContext) private var modelContext

    private var active: Trip? { trips.first { $0.isActive } }
    private var finished: [Trip] { trips.filter { !$0.isActive } }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.gap) {
                    if let trip = active {
                        VStack(alignment: .leading, spacing: 8) {
                            CardHeader(title: "Current trip")
                            ActiveTripRow(trip: trip)
                        }
                    } else {
                        StartTripMenu(spots: spots) { spot in
                            modelContext.insert(Trip(spot: spot))
                        }
                    }

                    if !finished.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            CardHeader(title: "Totals")
                            TotalsGrid(finished: finished)
                        }
                    }

                    if !finished.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            CardHeader(title: "Was the forecast right?")
                            ForecastCheckCard(summary: Scorecard.summary(finished.compactMap(\.scoreRecord)))
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        CardHeader(title: "History")
                        if finished.isEmpty {
                            Text("No finished trips yet. Log every trip, blank ones included.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .card()
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(finished) { trip in
                                    TripHistoryCard(trip: trip) {
                                        modelContext.delete(trip)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.cardPadding)
                .padding(.top, 8)
                .frame(maxWidth: Theme.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .screenBackground()
            .navigationTitle("Log")
        }
    }
}

private struct StartTripMenu: View {
    let spots: [Spot]
    let onStart: (Spot?) -> Void

    var body: some View {
        Menu {
            ForEach(spots) { spot in
                Button(spot.name) { onStart(spot) }
            }
            Button("No spot") { onStart(nil) }
        } label: {
            Label("Start trip", systemImage: "play.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 16)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Theme.accent, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
                .contentShape(.rect(cornerRadius: Theme.cardRadius, style: .continuous))
        }
    }
}

private struct ActiveTripRow: View {
    @Bindable var trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: trip.spot?.name ?? String(localized: "No spot"))
                    .font(.headline)
                Text(trip.startedAt, style: .timer)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                Text("Started \(trip.startedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                // Each tap on plus stamps the fish with the time, for the forecast check.
                Stepper {
                    Label("Fish caught: \(trip.catchCount)", systemImage: "fish.fill")
                        .font(.title3.weight(.medium))
                        .monospacedDigit()
                        .padding(.vertical, 4)
                } onIncrement: {
                    if trip.catchCount < 500 { trip.logCatch() }
                } onDecrement: {
                    trip.removeLastCatch()
                }
                .controlSize(.large)
                if let times = trip.completeCatchTimes, !times.isEmpty {
                    CatchTimesLine(times: times, timeZone: trip.spot?.timeZone ?? .current)
                }
            }
            .well()

            Button {
                end()
            } label: {
                Group {
                    if trip.catchCount == 0 { Text("End trip — no fish") } else { Text("End trip") }
                }
                .font(.headline)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.accent)
        }
        .card()
    }

    /// Ends the trip and stores what the model expected for it, so the trip
    /// can train the personal catch rate later.
    private func end() {
        let start = trip.startedAt, finish = Date()
        // Neutral estimate first, so the trip counts even if the app quits now.
        trip.expectedCatch = CatchModel.expectedCatch(points: [], from: start, to: finish)
        trip.endedAt = finish
        guard finish.timeIntervalSince(start) <= CatchModel.maxTripHours * 3600 else { return }
        let base = trip.spot?.context
        let water = trip.spot?.waterReading
        let ended = trip
        Task { @MainActor in
            var context = base
            if let c = base, c.water.isSalt {
                context?.tide = await ForecastService.shared.tideStation(latitude: c.latitude, longitude: c.longitude)
            }
            let points = await ForecastService.shared.tripPoints(context: context, from: start, to: finish)
            ended.expectedCatch = CatchModel.expectedCatch(points: points, from: start, to: finish)
            if let times = ended.completeCatchTimes,
               let record = Scorecard.record(points: points, from: start, to: finish, catchTimes: times) {
                ended.bandHours = record.hours
                ended.bandCatches = record.catches
                ended.forecastIndex = record.meanIndex
                // Kept on the phone: the only form in which this trip could ever tune the weights.
                if let context,
                   let slices = Scorecard.slices(points: points, weights: Weights.prior(water: context.water, species: context.species),
                                                 from: start, to: finish, catchTimes: times) {
                    let fit = TripFitRecord(water: context.water.rawValue, species: context.species.rawValue,
                                            waterTempC: water?.tempC, waterSource: water?.sourceName,
                                            hasBank: context.bankBearingDeg != nil, hasTideStation: context.tide != nil,
                                            slices: slices)
                    ended.fitRecord = try? JSONEncoder().encode(fit)
                    Logger(subsystem: "com.dautovri.bitecurve", category: "log")
                        .info("trip fit record: \(slices.count) slices, \(ended.fitRecord?.count ?? 0) bytes")
                }
            }
            await TripSharing.sendPending()
        }
    }
}

/// The times the fish came, on the spot's clock.
private struct CatchTimesLine: View {
    let times: [Date]
    let timeZone: TimeZone

    var body: some View {
        Text(verbatim: times.map { $0.clock(in: timeZone) }.joined(separator: " · "))
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .accessibilityLabel(Text("Fish caught at"))
            .accessibilityValue(Text(verbatim: times.map { $0.clock(in: timeZone) }.joined(separator: ", ")))
    }
}

/// Was the forecast right? Fishing hours and fish from the log, filed under the bite index the
/// forecast gave for each moment.
private struct ForecastCheckCard: View {
    let summary: Scorecard.Summary

    private func rate(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–"
    }

    private func hours(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)))
    }

    private var verdict: String {
        let good = rate(summary.goodRate), slow = rate(summary.slowRate)
        switch summary.verdict {
        case .notEnough:
            return String(localized: "Tap plus each time you land a fish. After three hours in good forecasts and three in slow ones, this shows whether the forecast holds for you.")
        case .tracks:
            return String(localized: "The forecast holds for you: \(good) fish per hour when it was above 50, \(slow) when it was below.")
        case .flat:
            return String(localized: "No clear difference so far: \(good) fish per hour when the forecast was above 50, \(slow) when it was below.")
        case .inverse:
            return String(localized: "So far you catch more in slow forecasts: \(slow) fish per hour below 50, \(good) above.")
        }
    }

    private var verdictSymbol: (name: String, color: Color) {
        switch summary.verdict {
        case .notEnough: return ("hourglass", .secondary)
        case .tracks: return ("checkmark.seal.fill", BiteScale.color(70))
        case .flat: return ("equal.circle.fill", .secondary)
        case .inverse: return ("arrow.up.arrow.down.circle.fill", BiteScale.color(40))
        }
    }

    var body: some View {
        let peak = Scorecard.bandFloors.indices.compactMap { summary.rate(band: $0) }.max() ?? 0
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: verdictSymbol.name)
                    .font(.title3)
                    .foregroundStyle(verdictSymbol.color)
                    .accessibilityHidden(true)
                Text(verbatim: verdict)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if summary.trips > 0 {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Forecast")
                        Text("Hours").gridColumnAlignment(.trailing)
                        Text("Fish").gridColumnAlignment(.trailing)
                        Text("Per hour").gridColumnAlignment(.trailing)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                    ForEach(Scorecard.bandFloors.indices.reversed(), id: \.self) { band in
                        let sample = Scorecard.bandFloors[band] + 1
                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Circle().fill(BiteScale.color(sample)).frame(width: 8, height: 8)
                                    Text(verbatim: BiteScale.label(sample))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                                // The bar is the catch rate, so a forecast that holds reads as a staircase.
                                GeometryReader { proxy in
                                    let share = peak > 0 ? (summary.rate(band: band) ?? 0) / peak : 0
                                    Capsule().fill(BiteScale.color(sample).opacity(0.85))
                                        .frame(width: max(share > 0 ? 4 : 0, proxy.size.width * share))
                                }
                                .frame(height: 5)
                                .accessibilityHidden(true)
                            }
                            Text(verbatim: hours(summary.hours[band]))
                            Text(verbatim: "\(summary.catches[band])")
                            Text(verbatim: rate(summary.rate(band: band)))
                                .fontWeight(.semibold)
                        }
                        .font(.subheadline)
                        .monospacedDigit()
                        // Read as one row with its column names, which VoiceOver would otherwise skip.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: BiteScale.label(sample)))
                        .accessibilityValue(Text(verbatim: "\(String(localized: "Hours")) \(hours(summary.hours[band])), \(String(localized: "Fish")) \(summary.catches[band]), \(String(localized: "Per hour")) \(rate(summary.rate(band: band)))"))
                    }
                }

                Text("Counts trips with timed fish and a saved forecast: \(summary.trips).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }
}

private struct TotalsGrid: View {
    let finished: [Trip]

    private let columns = Array(repeating: GridItem(.flexible(minimum: 80), spacing: 10), count: 3)

    var body: some View {
        let fish = finished.reduce(0) { $0 + $1.catchCount }
        let blanks = finished.filter { $0.catchCount == 0 }.count
        let blankPercent = Int((Double(blanks) / Double(finished.count) * 100).rounded())

        LazyVGrid(columns: columns, spacing: 10) {
            TotalStatCard(symbol: "figure.fishing", value: "\(finished.count)", label: String(localized: "Trips"))
            TotalStatCard(symbol: "fish.fill", value: "\(fish)", label: String(localized: "Fish"))
            TotalStatCard(symbol: "circle.dashed", value: "\(blankPercent)%", label: String(localized: "Blank trips"))
        }
    }
}

private struct TotalStatCard: View {
    let symbol: String
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(verbatim: value)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(verbatim: label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .card(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

private struct TripHistoryCard: View {
    let trip: Trip
    let onDelete: () -> Void

    private var spotName: String {
        trip.spot?.name ?? String(localized: "No spot")
    }

    private var dateAndDuration: String {
        let dateText = trip.startedAt.formatted(date: .abbreviated, time: .shortened)
        let durationText = Measurement(value: trip.hours, unit: UnitDuration.hours)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
        return "\(dateText) · \(durationText)"
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                details
                Spacer(minLength: 8)
                badge
            }
            VStack(alignment: .leading, spacing: 10) {
                details
                badge
            }
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("Delete"), onDelete)
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: spotName)
                .font(.headline)
            Text(verbatim: dateAndDuration)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let index = trip.forecastIndex {
                HStack(spacing: 6) {
                    Circle().fill(BiteScale.color(index)).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text("Forecast \(Int(index.rounded())) · \(BiteScale.label(index))")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if let times = trip.completeCatchTimes, !times.isEmpty {
                CatchTimesLine(times: times, timeZone: trip.spot?.timeZone ?? .current)
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        if trip.catchCount == 0 {
            // Same shape as a catch badge, outlined: a blank trip counts too.
            Label {
                Text("Blank")
            } icon: {
                Image(systemName: "fish")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
        } else {
            Label {
                Text(verbatim: "\(trip.catchCount)")
            } icon: {
                Image(systemName: "fish.fill")
            }
            .font(.headline)
            .monospacedDigit()
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.accent.opacity(0.15), in: .capsule)
        }
    }
}

