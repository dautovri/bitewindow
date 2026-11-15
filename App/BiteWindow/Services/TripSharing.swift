import BiteCore
import Foundation
import SwiftData
import os

/// Opt-in sharing of finished trips, so the factor weights can one day be fitted to real
/// catches. Off unless the angler switches it on in Settings.
///
/// What leaves the phone for each trip: a random id made here, the area as a geohash-5 cell
/// (about 5 km), the month, water type, fish, the water temperature used and its source, and
/// hour by hour the fish caught and each factor's score. Never the spot's name or position,
/// the date or time, notes, or anything about the person.
@MainActor
enum TripSharing {
    static let enabledKey = "tripSharingEnabled"
    private static let anglerKey = "tripSharingAngler"
    private static let log = Logger(subsystem: "com.dautovri.bitecurve", category: "sharing")

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// The random id trips are sent under; made on first use, replaced by `deleteShared`.
    private static var angler: String {
        if let id = UserDefaults.standard.string(forKey: anglerKey) { return id }
        let id = String(format: "%016llx", UInt64.random(in: .min ... .max))
        UserDefaults.standard.set(id, forKey: anglerKey)
        return id
    }

    struct Payload: Codable, Equatable {
        var v = 1
        var angler: String
        var gh: String
        var month: Int
        var water: String
        var species: String
        var waterTempC: Double?
        var waterSource: String?
        var hasBank: Bool
        var hasTideStation: Bool
        var burst: Bool
        var slices: [FactorSlice]
    }

    /// What would be sent for a trip, or nil when it has nothing usable: no forecast record,
    /// no spot any more, or shorter than a quarter of an hour.
    nonisolated static func payload(fit: TripFitRecord, angler: String, latitude: Double, longitude: Double,
                                    month: Int, catchTimes: [Date]) -> Payload? {
        let hours = fit.slices.reduce(0) { $0 + $1.hours }
        guard !fit.slices.isEmpty, fit.slices.count <= 24, hours >= 0.25, hours <= CatchModel.maxTripHours else { return nil }
        // Several fish all logged within two minutes were probably entered at the end.
        let sorted = catchTimes.sorted()
        let burst = sorted.count >= 2 && (sorted.last ?? .distantPast).timeIntervalSince(sorted.first ?? .distantPast) <= 120
        let hasWater = fit.waterTempC != nil && fit.waterSource != nil
        return Payload(angler: angler, gh: Geohash.encode(latitude: latitude, longitude: longitude, precision: 5),
                       month: month, water: fit.water, species: fit.species,
                       waterTempC: hasWater ? fit.waterTempC : nil, waterSource: hasWater ? fit.waterSource : nil,
                       hasBank: fit.hasBank, hasTideStation: fit.hasTideStation, burst: burst, slices: fit.slices)
    }

    private static var sending = false

    /// Sends every finished trip that has a forecast record and has not been sent yet.
    /// Does nothing while sharing is off. A trip that fails stays unsent and goes next time.
    static func sendPending() async {
        guard isEnabled, !sending else { return }
        sending = true
        let context = OfflineStore.container.mainContext
        // Whatever stops the loop, what was sent is saved, so it is not sent again.
        defer {
            try? context.save()
            sending = false
        }
        let id = angler
        let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
        for trip in trips where trip.sharedAt == nil && !trip.isActive {
            guard let data = trip.fitRecord, let fit = try? JSONDecoder().decode(TripFitRecord.self, from: data),
                  let spot = trip.spot,
                  let payload = payload(fit: fit, angler: id, latitude: spot.latitude, longitude: spot.longitude,
                                        month: spot.calendar.component(.month, from: trip.startedAt),
                                        catchTimes: trip.completeCatchTimes ?? []),
                  let body = try? JSONEncoder().encode(payload) else { continue }
            // Checked before every request: the switch may have gone off in the meantime.
            guard isEnabled else { return }
            let status = await ForecastService.shared.post(path: "trip", body: body)
            guard isEnabled else { return }
            if status == 204 {
                trip.sharedAt = Date()
            } else if status == 400 {
                // Refused for good: do not send it again on every launch.
                trip.sharedAt = .distantPast
            } else {
                log.info("trip not sent, status \(status ?? -1)")
                return
            }
        }
    }

    /// Trips the server holds from this phone.
    static func sharedCount(in trips: [Trip]) -> Int {
        trips.filter { ($0.sharedAt ?? .distantPast) > .distantPast }.count
    }

    /// Asks the server to delete everything sent from this phone, then switches sharing off
    /// and forgets the id. False when the server could not be reached; nothing changes then.
    static func deleteShared() async -> Bool {
        // Sharing goes off first and any upload in the air is waited out, so nothing can
        // arrive at the server after the delete under an id this phone has forgotten.
        let wasEnabled = isEnabled
        UserDefaults.standard.set(false, forKey: enabledKey)
        for _ in 0..<300 where sending {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let id = UserDefaults.standard.string(forKey: anglerKey) {
            guard !sending, let body = try? JSONEncoder().encode(["angler": id]),
                  await ForecastService.shared.post(path: "trip/delete", body: body) == 204 else {
                UserDefaults.standard.set(wasEnabled, forKey: enabledKey)
                return false
            }
        }
        UserDefaults.standard.removeObject(forKey: anglerKey)
        let context = OfflineStore.container.mainContext
        for trip in (try? context.fetch(FetchDescriptor<Trip>())) ?? [] where trip.sharedAt != nil {
            trip.sharedAt = nil
        }
        try? context.save()
        return true
    }
}
