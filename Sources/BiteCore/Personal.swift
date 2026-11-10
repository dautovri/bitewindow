import Foundation

/// Turns the bite index into an expected catch, so logged trips (including
/// blanks) can be compared with what the global model predicted.
public enum CatchModel {
    /// Catch rate of an average angler at a neutral index (50). PLACEHOLDER
    /// (heuristic); the per-spot `CatchRateMultiplier` absorbs its error.
    public static let baselineFishPerHour = 0.5

    /// Trips longer than this are treated as "forgot to end the trip" and
    /// excluded from the personal fit.
    public static let maxTripHours = 24.0

    /// Catch rate relative to a neutral hour: index 50 -> 1, 100 -> 2, 0 -> 0.
    public static func relativeRate(index: Double) -> Double {
        max(0, min(100, index)) / 50
    }

    /// Expected catch over `[from, to]` under the global model:
    /// `baseline · ∫ relativeRate dt`. Time not covered by `points` counts as neutral,
    /// so an empty `points` gives `baseline · hours`.
    public static func expectedCatch(points: [ScorePoint], from: Date, to: Date,
                                     baseline: Double = baselineFishPerHour) -> Double {
        let duration = to.timeIntervalSince(from)
        guard duration > 0, baseline > 0 else { return 0 }
        let sorted = points.sorted { $0.time < $1.time }

        func index(at t: Date) -> Double {
            guard let first = sorted.first, let last = sorted.last,
                  t >= first.time, t <= last.time else { return 50 }
            var lo = 0, hi = sorted.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if sorted[mid].time <= t { lo = mid } else { hi = mid }
            }
            let a = sorted[lo], b = sorted[hi]
            let span = b.time.timeIntervalSince(a.time)
            guard span > 0 else { return a.index }
            let f = t.timeIntervalSince(a.time) / span
            return a.index + (b.index - a.index) * f
        }

        // Midpoint rule on slices of at most 5 minutes.
        let n = max(1, Int((duration / 300).rounded(.up)))
        let dt = duration / Double(n)
        var relativeHours = 0.0
        for k in 0..<n {
            let t = from.addingTimeInterval((Double(k) + 0.5) * dt)
            relativeHours += relativeRate(index: index(at: t)) * dt / 3600
        }
        return baseline * relativeHours
    }
}

extension CatchRateMultiplier {
    /// One finished trip: fish caught and the model-expected catch for it.
    public struct Observation: Sendable, Equatable {
        public var catches: Int
        public var expected: Double

        public init(catches: Int, expected: Double) {
            self.catches = catches; self.expected = expected
        }
    }

    /// Posterior after folding in every observation. Order does not matter.
    public static func fitted(to observations: [Observation],
                              prior: CatchRateMultiplier = CatchRateMultiplier()) -> CatchRateMultiplier {
        var m = prior
        for o in observations { m.update(catches: o.catches, expected: o.expected) }
        return m
    }
}

extension Barometry {
    public typealias Sample = (time: Date, hPa: Double)

    /// Replaces the forecast pressure trace with the phone barometer wherever
    /// the phone was sampling.
    ///
    /// The phone reports station pressure, which differs from sea-level
    /// pressure by an altitude offset that is constant while the phone stays at
    /// one elevation. The offset is taken as the median device − forecast
    /// difference, so the fused trace keeps the forecast's level and the
    /// device's trend. Readings more than `maxResidual` hPa off that offset
    /// (taken at another elevation: 1 hPa ≈ 8 m) are dropped.
    ///
    /// Returns `forecast` unchanged (sorted) when fewer than `minSamples`
    /// readings survive or they span less than `minSpan` seconds.
    public static func fuse(forecast: [Sample], device: [Sample],
                            minSamples: Int = 3, minSpan: TimeInterval = 1800,
                            maxResidual: Double = 2) -> [Sample] {
        let series = Terms.PressureSeries(forecast)
        var times: [Date] = [], readings: [Double] = [], expected: [Double] = []
        for s in device.sorted(by: { $0.time < $1.time }) {
            guard let f = series.value(at: s.time) else { continue }
            times.append(s.time); readings.append(s.hPa); expected.append(f)
        }
        guard let offset = bias(device: readings, forecast: expected) else { return series.samples }

        var kept: [Sample] = []
        for i in times.indices where abs(readings[i] - expected[i] - offset) <= maxResidual {
            kept.append((time: times[i], hPa: readings[i] - offset))
        }
        guard kept.count >= minSamples, let first = kept.first, let last = kept.last,
              last.time.timeIntervalSince(first.time) >= minSpan else { return series.samples }

        var out: [Sample] = series.samples.filter { $0.time < first.time || $0.time > last.time }
        out.append(contentsOf: kept)
        out.sort { $0.time < $1.time }
        return out
    }
}
