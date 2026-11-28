import BiteCore
import StoreKit
import SwiftData
import SwiftUI

/// Trip log. Ending a trip with zero fish is a single tap, because blank trips
/// are what make the catch-rate model honest.
struct LogView: View {
    @Query(sort: \Trip.startedAt, order: .reverse) private var trips: [Trip]
    @Query(sort: \Spot.createdAt) private var spots: [Spot]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.requestReview) private var requestReview

    private var active: Trip? { trips.first { $0.isActive } }
    private var finished: [Trip] { trips.filter { !$0.isActive } }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.gap) {
                    if let trip = active {
                        VStack(alignment: .leading, spacing: 8) {
                            CardHeader(title: "Current trip")
                            ActiveTripRow(trip: trip) { ended in
                                // After the card has moved to the history, never over a running
                                // trip; checked right before asking.
                                Task {
                                    try? await Task.sleep(for: .milliseconds(800))
                                    if ReviewPrompt.isDue(after: ended) { requestReview() }
                                }
                            }
                        }
                    } else {
                        StartTripMenu(spots: spots) { spot in
                            modelContext.insert(Trip(spot: spot))
                            try? modelContext.save()
                            // No "how did it go?" for this spot while the trip runs.
                            Task { await BiteAlerts.reschedule() }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Told when the trip ends (the Log tab may ask for a rating).
    var onEnded: (Trip) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: trip.spot?.name ?? String(localized: "No spot"))
                    .font(.headline)
                Text(trip.startedAt, style: .timer)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                // On the spot's clock, like the fish times below it.
                Text("Started \(trip.startedAt.clock(in: trip.spot?.timeZone ?? .current))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                // Each tap stamps the fish with the time, for the forecast check. One big
                // target for wet hands on a moving boat, and a separate small one to take a fish back.
                // Side by side normally; stacked at accessibility text sizes so the count stays whole.
                let large = dynamicTypeSize.isAccessibilitySize
                (large ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))) {
                    Button {
                        if trip.catchCount < 500 { trip.logCatch() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus")
                                .font(.title3.weight(.heavy))
                            Label("Fish caught: \(trip.catchCount)", systemImage: "fish.fill")
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                                .lineLimit(large ? nil : 1)
                                .minimumScaleFactor(0.7)
                                .fixedSize(horizontal: false, vertical: large)
                        }
                        .foregroundStyle(BiteScale.onSolid)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(Theme.accent, in: .rect(cornerRadius: Theme.wellRadius, style: .continuous))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.impact, trigger: trip.catchCount)
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: if trip.catchCount < 500 { trip.logCatch() }
                        case .decrement: trip.removeLastCatch()
                        @unknown default: break
                        }
                    }

                    Button {
                        trip.removeLastCatch()
                    } label: {
                        Image(systemName: "minus")
                            .font(.title3.weight(.bold))
                            .frame(maxWidth: large ? .infinity : 52)
                            .frame(height: large ? 52 : 64)
                            .background(Theme.card, in: .rect(cornerRadius: Theme.wellRadius, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(trip.catchCount == 0)
                    // The minus symbol carries the system's own spoken label, so Voice Control
                    // and Switch Control reach it too; VoiceOver can also swipe down on the catch button.
                }
                if let times = trip.completeCatchTimes, !times.isEmpty {
                    CatchTimesLine(times: times, timeZone: trip.spot?.timeZone ?? .current)
                }
            }
            .well()

            PlannedQuestion(planned: $trip.planned)

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
            // Secondary and set apart, so a bumped thumb never ends the trip.
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Theme.ink2)
            .padding(.top, 4)
        }
        .card()
    }

    private func end() {
        let ended = trip
        TripRecorder.end(ended)
        try? ended.modelContext?.save()
        onEnded(ended)
    }
}

/// "Planned from forecast?" with Yes and No. Optional: tapping the chosen answer again clears it.
private struct PlannedQuestion: View {
    @Binding var planned: Bool?

    var body: some View {
        HStack(spacing: 8) {
            Text("Planned from forecast?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            pill(true, Text("Yes"))
            pill(false, Text("No"))
        }
        .accessibilityElement(children: .contain)
    }

    private func pill(_ value: Bool, _ label: Text) -> some View {
        let on = planned == value
        return Button {
            planned = on ? nil : value
        } label: {
            label
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .foregroundStyle(on ? BiteScale.onSolid : Theme.ink2)
                .background(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.well), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
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
                                    Image(systemName: BiteScale.symbol(sample))
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(BiteScale.color(sample))
                                    // Two lines rather than a cut-off label ("Au-dessus de la moyenne").
                                    Text(verbatim: BiteScale.label(sample))
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.85)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                // The bar is the catch rate, so a forecast that holds reads as a staircase.
                                GeometryReader { proxy in
                                    let share = peak > 0 ? (summary.rate(band: band) ?? 0) / peak : 0
                                    // On a visible track, so a band with no fish reads as zero, not as missing.
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Theme.well)
                                        Capsule().fill(BiteScale.color(sample))
                                            .frame(width: max(share > 0 ? 4 : 0, proxy.size.width * share))
                                    }
                                }
                                .frame(height: 6)
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
        let dateText = trip.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened), in: trip.spot?.timeZone ?? .current)
        let durationText = Measurement(value: trip.hours, unit: UnitDuration.hours)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
        return "\(dateText) · \(durationText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    details
                    Spacer(minLength: 8)
                    badge
                }
                VStack(alignment: .leading, spacing: 10) {
                    details
                    badge
                }
            }
            if let times = trip.completeCatchTimes, !times.isEmpty {
                CatchTimesLine(times: times, timeZone: trip.spot?.timeZone ?? .current)
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
                    Image(systemName: BiteScale.symbol(index))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(BiteScale.color(index))
                        .accessibilityHidden(true)
                    Text("Forecast \(Int(index.rounded())) · \(BiteScale.label(index))")
                    ShareLink(item: TripShare(day: trip.startedAt, timeZone: trip.spot?.timeZone ?? .current, index: index,
                                              catches: trip.catchCount, hours: trip.hours),
                              preview: SharePreview(Text(verbatim: "BiteCurve"))) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(minWidth: 44, minHeight: 32)
                            .contentShape(.rect)
                    }
                    .labelStyle(.iconOnly)
                    // The card reads as one element; this names the button among its actions.
                    .accessibilityLabel(Text("Share"))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
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

