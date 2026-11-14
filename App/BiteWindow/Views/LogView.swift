import BiteCore
import SwiftData
import SwiftUI

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

            Stepper(value: $trip.catchCount, in: 0...500) {
                Label("Fish caught: \(trip.catchCount)", systemImage: "fish.fill")
                    .font(.title3.weight(.medium))
                    .monospacedDigit()
                    .padding(.vertical, 4)
            }
            .controlSize(.large)
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
        let ended = trip
        Task { @MainActor in
            var context = base
            if let c = base, c.water == .inshoreSalt || c.water == .offshore {
                context?.tide = await ForecastService.shared.tideStation(latitude: c.latitude, longitude: c.longitude)
            }
            ended.expectedCatch = await ForecastService.shared.expectedCatch(context: context, from: start, to: finish)
        }
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

