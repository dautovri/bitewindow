import BiteCore
import Foundation
import SwiftData

// CloudKit-compatible schema: every property has a default or is optional,
// relationships are optional, and there are no unique constraints.

@Model
final class Spot {
    var id: UUID = UUID()
    var name: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var waterRaw: String = WaterType.warmFreshwater.rawValue
    var speciesRaw: String = Species.defaultSpecies().rawValue
    /// Bearing from open water to the fished bank.
    var bankBearingDeg: Double?
    var waterTempC: Double?
    /// The spot's own time zone (looked up once from its coordinates); nil until known.
    var timeZoneID: String?
    var createdAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \Trip.spot)
    var trips: [Trip]? = []

    init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.speciesRaw = Species.defaultSpecies().rawValue
    }

    /// The fish in the picker for this spot's water; a species that does not live in it
    /// (after the water was changed) falls back to the default for that water.
    func alignSpeciesWithWater(regionCode: String? = Locale.current.region?.identifier) {
        if !species.lives(in: water) {
            species = Species.defaultSpecies(forRegion: regionCode, water: water)
        }
    }

    var water: WaterType {
        get { WaterType(rawValue: waterRaw) ?? .warmFreshwater }
        set { waterRaw = newValue.rawValue }
    }

    var species: Species {
        get { Species(rawValue: speciesRaw) ?? Species.defaultSpecies() }
        set { speciesRaw = newValue.rawValue }
    }

    /// The water temperature the score uses, and where it came from: the angler's own reading
    /// when there is one, else the saved estimate (satellite at sea, modelled from air inland).
    enum WaterReading: Equatable {
        case measured(Double), satellite(Double), modelled(Double)

        var tempC: Double {
            switch self {
            case .measured(let t), .satellite(let t), .modelled(let t): return t
            }
        }

        var isMeasured: Bool { if case .measured = self { return true } else { return false } }
    }

    var waterReading: WaterReading? {
        if let waterTempC { return .measured(waterTempC) }
        guard let estimate = ForecastService.shared.cachedWaterEstimate(latitude: latitude, longitude: longitude, isSalt: isSalt) else {
            return nil
        }
        return estimate.source == .sst ? .satellite(estimate.tempC) : .modelled(estimate.tempC)
    }

    var context: SpotContext {
        SpotContext(latitude: latitude, longitude: longitude, water: water, species: species,
                    bankBearingDeg: bankBearingDeg, waterTempC: waterReading?.tempC)
    }

    var isSalt: Bool { water.isSalt }

    /// Times at a spot are shown in the spot's zone, not the phone's: a window at a lake two
    /// zones away is planned on that lake's clock. The phone's zone until the lookup answers.
    var timeZone: TimeZone { timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current }

    /// Days at the spot begin at its own midnight.
    var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar
    }

    var activeTrip: Trip? { trips?.first { $0.isActive } }

    /// Finished trips that count toward the personal fit.
    var fittedTrips: [Trip] {
        (trips ?? []).filter { !$0.isActive && $0.hours > 0 && $0.hours <= CatchModel.maxTripHours }
    }

    /// Your catch rate at this spot relative to the global model. Trips ended
    /// before expectations were stored count as neutral-weather trips.
    var catchMultiplier: CatchRateMultiplier {
        CatchRateMultiplier.fitted(to: fittedTrips.map {
            .init(catches: $0.catchCount,
                  expected: $0.expectedCatch ?? CatchModel.baselineFishPerHour * $0.hours)
        })
    }
}

/// A trip records effort as well as fish: zero-catch trips are kept on purpose,
/// because a model trained only on successful trips learns survivorship.
@Model
final class Trip {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    var endedAt: Date?
    var catchCount: Int = 0
    var notes: String = ""
    /// Catch the global model expected for this trip, fixed when the trip ends
    /// (the weather for it is not available later). Nil for older trips.
    var expectedCatch: Double?
    /// When each fish was caught, in order. Nil for trips logged before fish were timed.
    var catchTimes: [Date]?
    /// Hours fished and fish caught in each forecast band (see `Scorecard`), and the mean bite
    /// index over the trip. Fixed when the trip ends, like `expectedCatch`; nil when the real
    /// forecast did not cover the trip or the fish were not timed.
    var bandHours: [Double]?
    var bandCatches: [Int]?
    var forecastIndex: Double?
    var spot: Spot?

    init(spot: Spot?) {
        self.spot = spot
    }

    var isActive: Bool { endedAt == nil }

    var hours: Double {
        (endedAt ?? Date()).timeIntervalSince(startedAt) / 3600
    }

    /// One more fish, stamped now.
    func logCatch(at time: Date = Date()) {
        // A trip that already has untimed fish stays untimed: half a record would mislead.
        if catchCount == (catchTimes?.count ?? 0) { catchTimes = (catchTimes ?? []) + [time] }
        catchCount += 1
    }

    /// Takes back the last fish.
    func removeLastCatch() {
        guard catchCount > 0 else { return }
        if let times = catchTimes, times.count == catchCount { catchTimes = Array(times.dropLast()) }
        catchCount -= 1
    }

    /// The catch times, when every fish of the trip has one.
    var completeCatchTimes: [Date]? {
        let times = catchTimes ?? []
        return times.count == catchCount ? times : nil
    }

    /// This trip filed under the forecast bands, if it was stored when the trip ended.
    var scoreRecord: Scorecard.TripRecord? {
        guard let bandHours, let bandCatches, let forecastIndex,
              bandHours.count == Scorecard.bandFloors.count, bandCatches.count == Scorecard.bandFloors.count else { return nil }
        return Scorecard.TripRecord(hours: bandHours, catches: bandCatches, meanIndex: forecastIndex)
    }
}

/// Raw station pressure from the phone barometer. Stays on the device.
@Model
final class PressureSample {
    var time: Date = Date()
    var stationHPa: Double = 0

    init(time: Date, stationHPa: Double) {
        self.time = time
        self.stationHPa = stationHPa
    }
}
