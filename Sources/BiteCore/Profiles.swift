import Foundation

public struct ThermalParameters: Sendable, Equatable {
    public let optimum: Double
    public let sigmaLow: Double
    public let criticalMax: Double
}

/// Species thermal parameters are PLACEHOLDERS (heuristic). Replace with values
/// sourced from the bioenergetics literature before launch.
public enum Species: String, CaseIterable, Codable, Sendable {
    case largemouthBass, walleye, northernPike, rainbowTrout

    public var displayName: String {
        switch self {
        case .largemouthBass: return "Largemouth bass"
        case .walleye: return "Walleye"
        case .northernPike: return "Northern pike"
        case .rainbowTrout: return "Rainbow trout"
        }
    }

    public var thermal: ThermalParameters {
        switch self {
        case .largemouthBass: return .init(optimum: 27, sigmaLow: 8, criticalMax: 36)
        case .walleye: return .init(optimum: 22, sigmaLow: 7, criticalMax: 31)
        case .northernPike: return .init(optimum: 20, sigmaLow: 7, criticalMax: 29)
        case .rainbowTrout: return .init(optimum: 16, sigmaLow: 6, criticalMax: 25)
        }
    }

    public var defaultWater: WaterType {
        self == .rainbowTrout ? .coldFreshwater : .warmFreshwater
    }
}

public enum WaterType: String, CaseIterable, Codable, Sendable {
    case warmFreshwater, coldFreshwater, inshoreSalt, offshore
}

/// Prior factor weights. The ordering is evidence-informed; the numbers are heuristic.
public struct Weights: Sendable, Equatable {
    public var light: Double
    public var thermal: Double
    public var wind: Double
    public var pressure: Double
    public var solunar: Double
    public var tide: Double

    public init(light: Double, thermal: Double, wind: Double, pressure: Double, solunar: Double, tide: Double) {
        self.light = light; self.thermal = thermal; self.wind = wind
        self.pressure = pressure; self.solunar = solunar; self.tide = tide
    }

    public static func prior(water: WaterType, species: Species? = nil) -> Weights {
        switch water {
        case .warmFreshwater:
            // Lunar evidence exists for walleye/muskie, not for bass.
            let solunar = species == .largemouthBass ? 0.05 : 0.10
            return .init(light: 0.25, thermal: 0.20, wind: 0.20, pressure: 0.15, solunar: solunar, tide: 0)
        case .coldFreshwater:
            // Trout: solunar tables did not predict catch rate; keep near zero.
            return .init(light: 0.25, thermal: 0.25, wind: 0.15, pressure: 0.10, solunar: 0.02, tide: 0)
        case .inshoreSalt:
            return .init(light: 0.20, thermal: 0.15, wind: 0.10, pressure: 0.10, solunar: 0.05, tide: 0.35)
        case .offshore:
            return .init(light: 0.20, thermal: 0.25, wind: 0.10, pressure: 0.05, solunar: 0.05, tide: 0.10)
        }
    }
}
