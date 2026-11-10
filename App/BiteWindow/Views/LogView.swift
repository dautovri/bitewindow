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
            List {
                if let trip = active {
                    Section("Current trip") {
                        ActiveTripRow(trip: trip)
                    }
                } else {
                    Section {
                        Menu {
                            ForEach(spots) { spot in
                                Button(spot.name) { modelContext.insert(Trip(spot: spot)) }
                            }
                            Button("No spot") { modelContext.insert(Trip(spot: nil)) }
                        } label: {
                            Label("Start trip", systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                if !finished.isEmpty {
                    Section("Totals") {
                        let fish = finished.reduce(0) { $0 + $1.catchCount }
                        let blanks = finished.filter { $0.catchCount == 0 }.count
                        HStack {
                            StatTile(value: "\(finished.count)", label: String(localized: "Trips"))
                            StatTile(value: "\(fish)", label: String(localized: "Fish"))
                            StatTile(value: "\(Int((Double(blanks) / Double(finished.count) * 100).rounded()))%", label: String(localized: "Blank trips"))
                        }
                    }
                }

                Section("History") {
                    if finished.isEmpty {
                        Text("No finished trips yet. Log every trip, blank ones included.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(finished) { trip in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: trip.spot?.name ?? String(localized: "No spot"))
                                Text(verbatim: "\(trip.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(Measurement(value: trip.hours, unit: UnitDuration.hours).formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1)))))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if trip.catchCount == 0 {
                                Text("Blank").font(.subheadline).foregroundStyle(.secondary)
                            } else {
                                Label { Text(verbatim: "\(trip.catchCount)") } icon: { Image(systemName: "fish.fill") }
                                    .font(.headline)
                                    .monospacedDigit()
                                    .foregroundStyle(.teal)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .onDelete { offsets in
                        let rows = finished
                        for index in offsets { modelContext.delete(rows[index]) }
                    }
                }
            }
            .navigationTitle("Log")
        }
    }
}

private struct ActiveTripRow: View {
    @Bindable var trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: trip.spot?.name ?? String(localized: "No spot")).font(.headline)
            Text(trip.startedAt, style: .timer)
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text("Started \(trip.startedAt.formatted(date: .omitted, time: .shortened))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        Stepper(value: $trip.catchCount, in: 0...500) {
            Label("Fish caught: \(trip.catchCount)", systemImage: "fish.fill")
                .font(.title3.weight(.medium))
                .monospacedDigit()
        }
        Button {
            end()
        } label: {
            Group {
                if trip.catchCount == 0 { Text("End trip — no fish") } else { Text("End trip") }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
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
