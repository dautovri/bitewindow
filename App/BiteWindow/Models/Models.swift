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

    var water: WaterType {
        get { WaterType(rawValue: waterRaw) ?? .warmFreshwater }
        set { waterRaw = newValue.rawValue }
    }

    var species: Species {
        get { Species(rawValue: speciesRaw) ?? Species.defaultSpecies() }
        set { speciesRaw = newValue.rawValue }
    }

    var context: SpotContext {
        SpotContext(latitude: latitude, longitude: longitude, water: water, species: species,
                    bankBearingDeg: bankBearingDeg, waterTempC: waterTempC)
    }

    var isSalt: Bool { water == .inshoreSalt || water == .offshore }

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
    var spot: Spot?

    init(spot: Spot?) {
        self.spot = spot
    }

    var isActive: Bool { endedAt == nil }

    var hours: Double {
        (endedAt ?? Date()).timeIntervalSince(startedAt) / 3600
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
