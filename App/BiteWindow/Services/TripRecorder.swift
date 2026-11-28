import BiteCore
import Foundation
import StoreKit
import SwiftData
import os

/// Ends trips and stores what the forecast said about them. One place for the Log tab's button
/// and anything else that finishes a trip.
@MainActor
enum TripRecorder {
    /// Ends the trip at `finish` and stores what the model expected for it, so the trip can train
    /// the personal catch rate later; with timed fish, also the forecast-check record and the
    /// on-device fit record. Shared trips go out afterwards when sharing is on.
    /// `keepsForecastRecords: false` stores only the expected catch: for trips whose hours are
    /// assumed (logged from a notification), which must not feed the forecast check or a refit.
    @discardableResult
    static func end(_ trip: Trip, at finish: Date = Date(), keepsForecastRecords: Bool = true) -> Task<Void, Never> {
        let start = trip.startedAt
        // Neutral estimate first, so the trip counts even if the app quits now.
        trip.expectedCatch = CatchModel.expectedCatch(points: [], from: start, to: finish)
        trip.endedAt = finish
        guard finish.timeIntervalSince(start) <= CatchModel.maxTripHours * 3600 else { return Task {} }
        let base = trip.spot?.context
        let water = trip.spot?.waterReading
        return Task { @MainActor in
            var context = base
            if let c = base, c.water.isSalt {
                context?.tide = await ForecastService.shared.tideStation(latitude: c.latitude, longitude: c.longitude)
            }
            let points = await ForecastService.shared.tripPoints(context: context, from: start, to: finish)
            trip.expectedCatch = CatchModel.expectedCatch(points: points, from: start, to: finish)
            if keepsForecastRecords, let times = trip.completeCatchTimes,
               let record = Scorecard.record(points: points, from: start, to: finish, catchTimes: times) {
                trip.bandHours = record.hours
                trip.bandCatches = record.catches
                trip.forecastIndex = record.meanIndex
                // Kept on the phone: the only form in which this trip could ever tune the weights.
                if let context,
                   let slices = Scorecard.slices(points: points, weights: Weights.prior(water: context.water, species: context.species),
                                                 from: start, to: finish, catchTimes: times) {
                    let fit = TripFitRecord(water: context.water.rawValue, species: context.species.rawValue,
                                            waterTempC: water?.tempC, waterSource: water?.sourceName,
                                            hasBank: context.bankBearingDeg != nil, hasTideStation: context.tide != nil,
                                            slices: slices, planned: trip.planned)
                    trip.fitRecord = try? JSONEncoder().encode(fit)
                    Logger(subsystem: "com.dautovri.bitecurve", category: "log")
                        .info("trip fit record: \(slices.count) slices, \(trip.fitRecord?.count ?? 0) bytes")
                }
            }
            // Saved here too: launched in the background for a notification, nothing else saves.
            try? trip.modelContext?.save()
            await TripSharing.sendPending()
            if keepsForecastRecords { await BiteAlerts.reschedule() }
        }
    }

    /// Logs a finished trip over a bite window from the "How did it go?" notification. Does
    /// nothing when the spot is gone or a trip there already covers part of the window. The
    /// hours are assumed and the fish untimed, so the trip feeds the personal catch rate only.
    @discardableResult
    static func logWindow(spotID: UUID, start: Date, end: Date, catches: Int) async -> Trip? {
        let context = OfflineStore.container.mainContext
        guard end > start,
              let spot = (try? context.fetch(FetchDescriptor<Spot>(predicate: #Predicate { $0.id == spotID })))?.first else { return nil }
        let overlaps = (spot.trips ?? []).contains { $0.startedAt < end && ($0.endedAt ?? .distantFuture) > start }
        guard !overlaps, spot.activeTrip == nil else { return nil }
        let trip = Trip(spot: spot)
        trip.startedAt = start
        trip.catchCount = min(max(catches, 0), 500)
        context.insert(trip)
        let ending = Self.end(trip, at: end, keepsForecastRecords: false)
        // Saved with its end time before the downloads: if iOS suspends the app meanwhile, the
        // trip is already finished, not left running.
        try? context.save()
        // Waited for: iOS may suspend the app as soon as the notification action returns.
        await ending.value
        return trip
    }
}

/// When to ask for an App Store rating: after a finished trip with fish, from the second such
/// trip on, at most once per app version and once in 90 days. Never during a trip and never
/// for a trip logged from a notification.
@MainActor
enum ReviewPrompt {
    private static let versionKey = "reviewLastVersion"
    private static let dateKey = "reviewLastPromptAt"

    /// True when `ended` earns the prompt now; stamps the gate so it is not asked again soon.
    static func isDue(after ended: Trip, now: Date = Date()) -> Bool {
        guard !BiteWindowApp.isHostingTests, ended.catchCount >= 1,
              (0.25...CatchModel.maxTripHours).contains(ended.hours) else { return false }
        let context = OfflineStore.container.mainContext
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        guard !trips.contains(where: \.isActive),
              trips.filter({ !$0.isActive && $0.hours <= CatchModel.maxTripHours }).count >= 2 else { return false }
        let defaults = UserDefaults.standard
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let last = defaults.double(forKey: dateKey)
        guard defaults.string(forKey: versionKey) != version, now.timeIntervalSince1970 - last >= 90 * 86_400 else { return false }
        defaults.set(version, forKey: versionKey)
        defaults.set(now.timeIntervalSince1970, forKey: dateKey)
        return true
    }
}
