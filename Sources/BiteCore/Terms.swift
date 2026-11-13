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
        let p = species.thermal
        let f: Double
        if t <= p.optimum {
            f = exp(-pow((t - p.optimum) / p.sigmaLow, 2))
        } else {
            f = max(0, 1 - pow((t - p.optimum) / (p.criticalMax - p.optimum), 2))
        }
        return 2 * f - 1
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

    /// Scores current strength: fast-moving water scores high, slack scores low.
    public static func tide(rate: Double, maxRateOfDay: Double) -> Double {
        guard maxRateOfDay > 0 else { return 0 }
        return 2 * min(1, abs(rate) / maxRateOfDay) - 1
    }
}
