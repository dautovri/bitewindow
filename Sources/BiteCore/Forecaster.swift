import Foundation

/// One hour of weather input, in the units WeatherKit REST returns.
public struct HourConditions: Codable, Sendable, Equatable {
    public var time: Date
    /// Sea-level pressure, hPa (millibars).
    public var pressureHPa: Double
    /// 0...1
    public var cloudCover: Double
    public var windSpeedKmh: Double
    /// Compass bearing the wind comes FROM, degrees.
    public var windFromDeg: Double?
    public var airTempC: Double

    public init(time: Date, pressureHPa: Double, cloudCover: Double,
                windSpeedKmh: Double, windFromDeg: Double?, airTempC: Double) {
        self.time = time; self.pressureHPa = pressureHPa; self.cloudCover = cloudCover
        self.windSpeedKmh = windSpeedKmh; self.windFromDeg = windFromDeg; self.airTempC = airTempC
    }
}

public struct SpotContext: Sendable {
    public var latitude: Double
    public var longitude: Double
    public var water: WaterType
    public var species: Species
    /// Bearing from open water to the fished bank; nil when unknown.
    public var bankBearingDeg: Double?
    /// Measured water temperature. When nil the thermal term is neutral.
    public var waterTempC: Double?
    public var tide: TideStation?

    public init(latitude: Double, longitude: Double, water: WaterType, species: Species,
                bankBearingDeg: Double? = nil, waterTempC: Double? = nil, tide: TideStation? = nil) {
        self.latitude = latitude; self.longitude = longitude; self.water = water
        self.species = species; self.bankBearingDeg = bankBearingDeg
        self.waterTempC = waterTempC; self.tide = tide
    }
}

/// Weighted contribution (w · z) of each factor at one instant.
public struct Contributions: Sendable, Equatable {
    public var light = 0.0, thermal = 0.0, wind = 0.0, pressure = 0.0, solunar = 0.0, tide = 0.0
    public var total: Double { light + thermal + wind + pressure + solunar + tide }
}

public struct ScorePoint: Sendable, Equatable {
    public let time: Date
    /// Bite index, 0...100. 50 = neutral.
    public let index: Double
    public let contributions: Contributions
    /// False when no weather covered this instant and the score rests on
    /// sun, moon, tide and water temperature alone (see `fillMissingWeather`).
    public let hasWeather: Bool

    public init(time: Date, index: Double, contributions: Contributions, hasWeather: Bool = true) {
        self.time = time; self.index = index; self.contributions = contributions; self.hasWeather = hasWeather
    }
}

public struct BiteWindow: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let meanIndex: Double
}

public enum Forecaster {
    /// Logistic gain. With k = 3 a fully favourable day (Σ w·z ≈ 0.9) scores ~94.
    public static let gain = 3.0

    public static func index(for c: Contributions) -> Double {
        100 / (1 + exp(-gain * c.total))
    }

    static func interpolate(_ hours: [HourConditions], at t: Date) -> HourConditions? {
        guard let first = hours.first, let last = hours.last, t >= first.time, t <= last.time else { return nil }
        guard let hi = hours.firstIndex(where: { $0.time >= t }) else { return nil }
        if hi == 0 { return hours[0] }
        let a = hours[hi - 1], b = hours[hi]
        let span = b.time.timeIntervalSince(a.time)
        let f = span > 0 ? t.timeIntervalSince(a.time) / span : 0
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        return HourConditions(time: t,
                              pressureHPa: mix(a.pressureHPa, b.pressureHPa),
                              cloudCover: mix(a.cloudCover, b.cloudCover),
                              windSpeedKmh: mix(a.windSpeedKmh, b.windSpeedKmh),
                              windFromDeg: f < 0.5 ? a.windFromDeg : b.windFromDeg,
                              airTempC: mix(a.airTempC, b.airTempC))
    }

    /// Scores `[from, to]` every `step` seconds. `hours` should start 48 h before
    /// `from` so pressure deltas are defined; instants without weather are skipped.
    /// `pressure` overrides the pressure trace taken from `hours` (see `Barometry.fuse`).
    /// With `fillMissingWeather`, instants without weather are scored anyway with
    /// wind, pressure and cloud neutral, so the app still works with no network
    /// and no saved forecast; those points carry `hasWeather == false`.
    public static func curve(context: SpotContext, hours: [HourConditions],
                             from: Date, to: Date, step: TimeInterval = 900,
                             weights: Weights? = nil,
                             pressure: Terms.PressureSeries? = nil,
                             fillMissingWeather: Bool = false) -> [ScorePoint] {
        let hours = hours.sorted { $0.time < $1.time }
        let w = weights ?? Weights.prior(water: context.water, species: context.species)
        let series = pressure ?? Terms.PressureSeries(hours.map { ($0.time, $0.pressureHPa) })

        let pad: TimeInterval = 86400
        let sun = Astro.events(.sun, from: from.addingTimeInterval(-pad), to: to.addingTimeInterval(pad),
                               latitude: context.latitude, longitude: context.longitude)
        let moon = Astro.events(.moon, from: from.addingTimeInterval(-pad), to: to.addingTimeInterval(pad),
                                latitude: context.latitude, longitude: context.longitude)
        let majors = moon.upperTransits + moon.lowerTransits
        let minors = moon.rises + moon.sets

        func nearest(_ events: [Date], to t: Date) -> Date? {
            events.min { abs($0.timeIntervalSince(t)) < abs($1.timeIntervalSince(t)) }
        }

        var times: [Date] = []
        var t = from
        while t <= to { times.append(t); t = t.addingTimeInterval(step) }

        let tideRates: [Double]? = context.tide.map { station in times.map { station.rate(at: $0) } }
        let halfDaySteps = max(1, Int((12.5 * 3600) / step))

        var out: [ScorePoint] = []
        for (i, time) in times.enumerated() {
            let weather = interpolate(hours, at: time)
            if weather == nil && !fillMissingWeather { continue }
            var c = Contributions()
            c.light = w.light * Terms.light(at: time, sunrise: nearest(sun.rises, to: time),
                                            sunset: nearest(sun.sets, to: time), cloudCover: weather?.cloudCover)
            if let tw = context.waterTempC {
                c.thermal = w.thermal * Terms.thermal(waterTempC: tw, species: context.species)
            }
            if let h = weather {
                c.wind = w.wind * Terms.wind(speedKmh: h.windSpeedKmh,
                                             towardDeg: h.windFromDeg.map { $0 + 180 },
                                             bankBearingDeg: context.bankBearingDeg)
                c.pressure = w.pressure * Terms.pressure(series, at: time, cloudCover: h.cloudCover)
            }
            c.solunar = w.solunar * Terms.solunar(at: time, majors: majors, minors: minors,
                                                  phaseAngle: Astro.moonPhaseAngle(time))
            if let rates = tideRates, w.tide > 0 {
                let lo = max(0, i - halfDaySteps), hi = min(rates.count - 1, i + halfDaySteps)
                let peak = rates[lo...hi].map { abs($0) }.max() ?? 0
                c.tide = w.tide * Terms.tide(rate: rates[i], maxRateOfDay: peak)
            }
            out.append(ScorePoint(time: time, index: index(for: c), contributions: c, hasWeather: weather != nil))
        }
        return out
    }

    /// Highest-mean contiguous window of the given length.
    public static func bestWindow(in points: [ScorePoint], length: TimeInterval = 7200) -> BiteWindow? {
        guard points.count >= 2 else { return nil }
        var best: BiteWindow?
        var j = 0
        var sum = 0.0
        for i in points.indices {
            sum += points[i].index
            while points[i].time.timeIntervalSince(points[j].time) > length {
                sum -= points[j].index
                j += 1
            }
            let covered = points[i].time.timeIntervalSince(points[j].time)
            guard covered >= length * 0.9 else { continue }
            let mean = sum / Double(i - j + 1)
            if best == nil || mean > best!.meanIndex {
                best = BiteWindow(start: points[j].time, end: points[i].time, meanIndex: mean)
            }
        }
        return best
    }

    /// Summer depth guidance for stratified lakes. Location advice only —
    /// stratification does not enter the timing score.
    public static func depthAdvice(maxDepthMeters: Double, surfaceTempC: Double, species: Species) -> String? {
        guard maxDepthMeters > 6, surfaceTempC > species.thermal.optimum + 2 else { return nil }
        return "Lake is likely stratified: target the thermocline band and avoid the deep basin, where oxygen runs low."
    }
}
