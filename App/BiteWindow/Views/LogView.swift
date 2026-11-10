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

    var body: some View {
        NavigationStack {
            List {
                if let trip = active {
                    Section("Current trip") {
                        ActiveTripRow(trip: trip)
                    }
                } else {
                    Section {
                        Menu("Start trip") {
                            ForEach(spots) { spot in
                                Button(spot.name) { modelContext.insert(Trip(spot: spot)) }
                            }
                            Button("No spot") { modelContext.insert(Trip(spot: nil)) }
                        }
                    }
                }

                Section("History") {
                    ForEach(trips.filter { !$0.isActive }) { trip in
                        VStack(alignment: .leading) {
                            Text(trip.spot?.name ?? "No spot")
                            Text("\(trip.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(trip.hours.formatted(.number.precision(.fractionLength(1)))) h · \(trip.catchCount) fish")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        let finished = trips.filter { !$0.isActive }
                        for index in offsets { modelContext.delete(finished[index]) }
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
        Text(trip.spot?.name ?? "No spot")
        Text("Started \(trip.startedAt.formatted(date: .omitted, time: .shortened))")
            .foregroundStyle(.secondary)
        Stepper("Fish caught: \(trip.catchCount)", value: $trip.catchCount, in: 0...500)
        Button(trip.catchCount == 0 ? "End trip — no fish" : "End trip") { end() }
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
