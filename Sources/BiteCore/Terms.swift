import Foundation

/// Sub-scores of the bite model. Every term maps to z in [-1, 1], 0 = neutral.
/// Functional forms follow docs/SCIENCE.md; numeric constants are heuristic
/// priors, to be replaced by coefficients fitted on logged trips.
public enum Terms {

    // MARK: Frontal / pressure

    /// A time-ordered sea-level pressure series in hPa.
    public struct PressureSeries: Sendable {
        public let samples: [(time: Date, hPa: Double)]

        public init(_ samples: [(time: Date, hPa: Double)]) {
            self.samples = samples.sorted { $0.time < $1.time }
        }

        /// Linear interpolation; nil outside the covered range.
        public func value(at t: Date) -> Double? {
            guard let first = samples.first, let last = samples.last,
                  t >= first.time, t <= last.time else { return nil }
            var lo = 0, hi = samples.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if samples[mid].time <= t { lo = mid } else { hi = mid }
            }
            let a = samples[lo], b = samples[hi]
            let span = b.time.timeIntervalSince(a.time)
            guard span > 0 else { return a.hPa }
            let f = t.timeIntervalSince(a.time) / span
            return a.hPa + (b.hPa - a.hPa) * f
        }

        /// P(t) - P(t - hours); nil when either end is missing.
        public func delta(at t: Date, hours: Double) -> Double? {
            guard let now = value(at: t),
                  let then = value(at: t.addingTimeInterval(-hours * 3600)) else { return nil }
            return now - then
        }
    }

    /// Pressure is modelled as a frontal-passage detector, not as an absolute level.
    /// Missing history makes the affected component neutral.
    public static func pressure(_ series: PressureSeries, at t: Date, cloudCover: Double) -> Double {
        let fall = series.delta(at: t, hours: 6).map { tanh(-$0 / 3) } ?? 0
        let post: Double = series.delta(at: t, hours: 24).map { d24 in
            cloudCover < 0.3 ? -tanh(max(0, d24 - 4) / 4) : 0
        } ?? 0
        let stab = series.delta(at: t, hours: 48).map { exp(-pow($0 / 3, 2)) - 0.5 } ?? 0
        return 0.5 * fall + 0.35 * post + 0.15 * stab
    }

    // MARK: Solunar

    /// `majors` are lunar upper/lower transits, `minors` are moonrise/moonset.
    public static func solunar(at t: Date, majors: [Date], minors: [Date], phaseAngle: Double) -> Double {
        func kernel(_ events: [Date], sigmaMinutes: Double) -> Double {
            events.map { e -> Double in
                let dm = t.timeIntervalSince(e) / 60
                return exp(-(dm * dm) / (2 * sigmaMinutes * sigmaMinutes))
            }.max() ?? 0
        }
        let s = max(kernel(majors, sigmaMinutes: 45), 0.6 * kernel(minors, sigmaMinutes: 30))
        let m = 0.75 + 0.25 * abs(cos(phaseAngle * .pi / 180))
        return 2 * s * m - 1
    }

    // MARK: Light

    /// Unknown cloud cover (`nil`) makes the cloud component neutral.
    public static func light(at t: Date, sunrise: Date?, sunset: Date?, cloudCover: Double?) -> Double {
        func bump(_ e: Date?) -> Double {
            guard let e else { return 0 }
            let dm = t.timeIntervalSince(e) / 60
            return exp(-pow(dm / 60, 2))
        }
        // Polar day or polar night: no sunrise and no sunset. Neutral, not the
        // bright-noon penalty for all 24 hours.
        let twilight = (sunrise == nil && sunset == nil) ? 0 : 2 * max(bump(sunrise), bump(sunset)) - 1
        let cloud = cloudCover.map { 2 * (1 - pow(1 - max(0, min(1, $0)), 2)) - 1 } ?? 0
        return 0.7 * twilight + 0.3 * cloud
    }

    // MARK: Thermal

    /// Asymmetric thermal performance curve on water temperature (°C).
    public static func thermal(waterTempC t: Double, species: Species) -> Double {
        // "Any fish" has no preferred temperature.
        if species == .general { return 0 }
        let p = species.thermal
        let f: Double
        if t <= p.optimum {
            f = exp(-pow((t - p.optimum) / p.sigmaLow, 2))
        } else {
            f = max(0, 1 - pow((t - p.optimum) / (p.criticalMax - p.optimum), 2))
        }
        return 2 * f - 1
    }

    /// Rough surface water temperature when none was measured: the mean air temperature of the
    /// last 72 h before `now`, kept to 1...30 °C. Needs at least 24 hours of that history.
    /// Water lags the air, so this runs low in autumn and high in spring; it is shown as an estimate.
    public static func estimatedWaterTempC(hours: [HourConditions], now: Date) -> Double? {
        let past = hours.filter { $0.time <= now && $0.time > now.addingTimeInterval(-72 * 3600) }
        guard past.count >= 24 else { return nil }
        let mean = past.map(\.airTempC).reduce(0, +) / Double(past.count)
        return min(30, max(1, mean))
    }

    /// One daily step of the air-to-water lag model.
    public static func waterTempStep(previousC: Double, airMean7dC: Double, tauDays: Double = 8) -> Double {
        previousC + (airMean7dC - previousC) / tauDays
    }

    // MARK: Wind

    /// - Parameters:
    ///   - speedKmh: sustained wind speed.
    ///   - towardDeg: compass bearing the wind blows toward.
    ///   - bankBearingDeg: bearing from open water to the fished bank; nil = unknown.
    public static func wind(speedKmh u: Double, towardDeg: Double?, bankBearingDeg: Double?) -> Double {
        if u > 35 { return -1 }
        let zU = 2 * exp(-pow((u - 18) / 12, 2)) - 1
        var zDir = 0.0
        if let towardDeg, let bankBearingDeg {
            zDir = cos((towardDeg - bankBearingDeg) * .pi / 180)
        }
        return 0.6 * zU + 0.4 * zDir
    }

    /// Fetch-limited significant wave height in metres (JONSWAP form).
    public static func waveHeight(windMs u10: Double, fetchMeters f: Double) -> Double {
        1.6e-3 * u10 * (f / 9.81).squareRoot()
    }

    // MARK: Tide

    /// Moving water fishes better than slack. Within the day the rate is scaled to the day's
    /// strongest flow. With `maxRateOfCycle` (the strongest flow of the surrounding spring-neap
    /// cycle) 30 % of the term says how strong the day's tides are: spring tides around new and
    /// full moon run harder than neap tides at the quarter moons.
    public static func tide(rate: Double, maxRateOfDay: Double, maxRateOfCycle: Double? = nil) -> Double {
        guard maxRateOfDay > 0 else { return 0 }
        let withinDay = 2 * min(1, abs(rate) / maxRateOfDay) - 1
        guard let cycle = maxRateOfCycle, cycle > 0 else { return withinDay }
        let dayStrength = 2 * min(1, maxRateOfDay / cycle) - 1
        return 0.7 * withinDay + 0.3 * dayStrength
    }

    /// Spring-neap proxy from the moon phase alone, for saltwater spots without a tide station:
    /// 1 at new and full moon (spring tides), −1 at the quarters (neap tides). Ignores the one-to-
    /// two-day lag of the real springs behind the phase, and seas with almost no tide.
    public static func springTide(phaseAngle: Double) -> Double {
        cos(2 * phaseAngle * .pi / 180)
    }
}
