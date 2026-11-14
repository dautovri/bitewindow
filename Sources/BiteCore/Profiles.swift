import Foundation

public struct ThermalParameters: Sendable, Equatable {
    public let optimum: Double
    public let sigmaLow: Double
    public let criticalMax: Double
}

/// Species thermal parameters are PLACEHOLDERS (heuristic). Replace with values
/// sourced from the bioenergetics literature before launch.
public enum Species: String, CaseIterable, Codable, Sendable {
    // Raw values are stored on each spot (SwiftData): never rename a case, only add.
    case largemouthBass, walleye, northernPike, rainbowTrout
    case crucianCarp, commonCarp, europeanPerch, commonBream
    /// No particular fish: the thermal term stays neutral. The default at sea.
    case general
    case europeanSeaBass, atlanticCod, atlanticMackerel, seaTrout, flounder, stripedBass, redDrum

    public enum Habitat: Sendable { case fresh, salt, any }

    public var habitat: Habitat {
        switch self {
        case .general: return .any
        case .europeanSeaBass, .atlanticCod, .atlanticMackerel, .seaTrout, .flounder, .stripedBass, .redDrum: return .salt
        default: return .fresh
        }
    }

    /// Whether the species belongs on a spot with this water.
    public func lives(in water: WaterType) -> Bool {
        switch habitat {
        case .any: return true
        case .salt: return water.isSalt
        case .fresh: return !water.isSalt
        }
    }

    /// The fish a spot offers for its water, the general profile first.
    public static func choices(for water: WaterType) -> [Species] {
        [.general] + allCases.filter { $0 != .general && $0.lives(in: water) }
    }

    public var displayName: String {
        switch self {
        case .largemouthBass: return "Largemouth bass"
        case .walleye: return "Walleye"
        case .northernPike: return "Northern pike"
        case .rainbowTrout: return "Rainbow trout"
        case .crucianCarp: return "Crucian carp"
        case .commonCarp: return "Common carp"
        case .europeanPerch: return "Perch"
        case .commonBream: return "Bream"
        case .general: return "Any fish"
        case .europeanSeaBass: return "Sea bass"
        case .atlanticCod: return "Cod"
        case .atlanticMackerel: return "Mackerel"
        case .seaTrout: return "Sea trout"
        case .flounder: return "Flounder"
        case .stripedBass: return "Striped bass"
        case .redDrum: return "Red drum"
        }
    }

    public var thermal: ThermalParameters {
        switch self {
        case .largemouthBass: return .init(optimum: 27, sigmaLow: 8, criticalMax: 36)
        case .walleye: return .init(optimum: 22, sigmaLow: 7, criticalMax: 31)
        case .northernPike: return .init(optimum: 20, sigmaLow: 7, criticalMax: 29)
        case .rainbowTrout: return .init(optimum: 16, sigmaLow: 6, criticalMax: 25)
        case .crucianCarp: return .init(optimum: 24, sigmaLow: 6, criticalMax: 34)
        case .commonCarp: return .init(optimum: 26, sigmaLow: 6, criticalMax: 35)
        case .europeanPerch: return .init(optimum: 19, sigmaLow: 7, criticalMax: 28)
        case .commonBream: return .init(optimum: 21, sigmaLow: 6, criticalMax: 30)
        // Not used for scoring (`Terms.thermal` is neutral for it); a mild curve for depth advice.
        case .general: return .init(optimum: 20, sigmaLow: 10, criticalMax: 32)
        case .europeanSeaBass: return .init(optimum: 18, sigmaLow: 6, criticalMax: 28)
        case .atlanticCod: return .init(optimum: 10, sigmaLow: 5, criticalMax: 18)
        case .atlanticMackerel: return .init(optimum: 14, sigmaLow: 5, criticalMax: 22)
        case .seaTrout: return .init(optimum: 13, sigmaLow: 6, criticalMax: 22)
        case .flounder: return .init(optimum: 15, sigmaLow: 6, criticalMax: 25)
        case .stripedBass: return .init(optimum: 18, sigmaLow: 6, criticalMax: 27)
        case .redDrum: return .init(optimum: 24, sigmaLow: 7, criticalMax: 33)
        }
    }

    /// Carp and their kin, for which no lunar effect is documented.
    public var isCyprinid: Bool {
        self == .crucianCarp || self == .commonCarp || self == .commonBream
    }

    public var defaultWater: WaterType {
        if habitat == .salt { return .inshoreSalt }
        return self == .rainbowTrout ? .coldFreshwater : .warmFreshwater
    }

    private static let northAmericanRegions: Set<String> = [
        "AG", "AI", "AW", "BB", "BL", "BM", "BQ", "BS", "BZ", "CA", "CR", "CU",
        "CW", "DM", "DO", "GD", "GL", "GP", "GT", "HN", "HT", "JM", "KN", "KY",
        "LC", "MF", "MQ", "MS", "MX", "NI", "PA", "PM", "PR", "SV", "SX", "TC",
        "TT", "US", "VC", "VG", "VI",
    ]

    /// The fish a new spot starts with: the general profile at sea, else by the region the
    /// spot is in (see `defaultSpecies(forRegion:)`).
    public static func defaultSpecies(forRegion regionCode: String?, water: WaterType) -> Species {
        water.isSalt ? .general : defaultSpecies(forRegion: regionCode)
    }

    /// North America defaults to walleye; everywhere else to northern pike.
    public static func defaultSpecies(forRegion regionCode: String? = Locale.current.region?.identifier) -> Species {
        guard let code = regionCode?.uppercased(), northAmericanRegions.contains(code) else {
            return .northernPike
        }
        return .walleye
    }
}

public enum WaterType: String, CaseIterable, Codable, Sendable {
    case warmFreshwater, coldFreshwater, inshoreSalt, offshore

    public var isSalt: Bool { self == .inshoreSalt || self == .offshore }
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
            // Lunar evidence exists for walleye/muskie, not for bass or carp.
            let solunar = species == .largemouthBass || species?.isCyprinid == true ? 0.05 : 0.10
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
