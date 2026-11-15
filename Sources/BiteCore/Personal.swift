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

/// Checks the forecast against what was caught: every fishing hour and every fish is filed
/// under the bite index the forecast gave for that moment, so the catch rate can be compared
/// between slow and good hours. Blank hours count as much as the fish do.
public enum Scorecard {
    /// Lower edges of the four index bands: slow, below average, above average, strong.
    public static let bandFloors: [Double] = [0, 35, 50, 65]
    /// The first band that counts as a good forecast (index 50 and up).
    public static let firstGoodBand = 2

    public static func band(index: Double) -> Int {
        (bandFloors.lastIndex { index >= $0 }) ?? 0
    }

    /// One trip, split by the forecast band of each moment.
    public struct TripRecord: Sendable, Equatable {
        /// Hours fished in each band.
        public var hours: [Double]
        /// Fish caught in each band.
        public var catches: [Int]
        /// Time-weighted mean index over the trip.
        public var meanIndex: Double

        public init(hours: [Double], catches: [Int], meanIndex: Double) {
            self.hours = hours; self.catches = catches; self.meanIndex = meanIndex
        }
    }

    /// Files a trip under the forecast bands. Nil when the forecast does not cover the whole
    /// trip (nothing is guessed), or a catch lies outside it.
    public static func record(points: [ScorePoint], from: Date, to: Date, catchTimes: [Date]) -> TripRecord? {
        let sorted = points.sorted { $0.time < $1.time }
        let duration = to.timeIntervalSince(from)
        // The curve is sampled every 15 minutes, so allow that much slack at each end.
        guard duration > 0, sorted.count >= 2, let first = sorted.first, let last = sorted.last,
              first.time <= from.addingTimeInterval(900), last.time >= to.addingTimeInterval(-900) else { return nil }

        func index(at t: Date) -> Double {
            if t <= first.time { return first.index }
            if t >= last.time { return last.index }
            var lo = 0, hi = sorted.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if sorted[mid].time <= t { lo = mid } else { hi = mid }
            }
            let a = sorted[lo], b = sorted[hi]
            let span = b.time.timeIntervalSince(a.time)
            guard span > 0 else { return a.index }
            return a.index + (b.index - a.index) * t.timeIntervalSince(a.time) / span
        }

        var hours = [Double](repeating: 0, count: bandFloors.count)
        var catches = [Int](repeating: 0, count: bandFloors.count)
        let n = max(1, Int((duration / 300).rounded(.up)))
        let dt = duration / Double(n)
        var weighted = 0.0
        for k in 0..<n {
            let value = index(at: from.addingTimeInterval((Double(k) + 0.5) * dt))
            hours[band(index: value)] += dt / 3600
            weighted += value * dt
        }
        for time in catchTimes {
            guard time >= from.addingTimeInterval(-60), time <= to.addingTimeInterval(60) else { return nil }
            catches[band(index: index(at: time))] += 1
        }
        return TripRecord(hours: hours, catches: catches, meanIndex: weighted / duration)
    }

    public enum Verdict: Sendable, Equatable {
        /// Too little fishing on one side of the line to compare.
        case notEnough
        /// Fish came clearly faster in good hours.
        case tracks
        /// No clear difference.
        case flat
        /// Fish came clearly faster in slow hours.
        case inverse
    }

    public struct Summary: Sendable, Equatable {
        public var hours: [Double]
        public var catches: [Int]
        public var trips: Int
        public var verdict: Verdict

        /// Fish per hour in a band; nil with under half an hour fished in it.
        public func rate(band: Int) -> Double? {
            hours[band] >= 0.5 ? Double(catches[band]) / hours[band] : nil
        }

        public var goodHours: Double { hours[Scorecard.firstGoodBand...].reduce(0, +) }
        public var slowHours: Double { hours[..<Scorecard.firstGoodBand].reduce(0, +) }
        public var goodCatches: Int { catches[Scorecard.firstGoodBand...].reduce(0, +) }
        public var slowCatches: Int { catches[..<Scorecard.firstGoodBand].reduce(0, +) }
        public var goodRate: Double? { goodHours > 0 ? Double(goodCatches) / goodHours : nil }
        public var slowRate: Double? { slowHours > 0 ? Double(slowCatches) / slowHours : nil }
    }

    /// Hours needed on each side of index 50 before a verdict is given.
    public static let minHoursPerSide = 3.0
    /// Fish needed in total before a verdict is given.
    public static let minCatches = 5
    /// How much faster one side must be to call it. PLACEHOLDER (heuristic).
    public static let clearRatio = 1.25

    public static func summary(_ records: [TripRecord]) -> Summary {
        var hours = [Double](repeating: 0, count: bandFloors.count)
        var catches = [Int](repeating: 0, count: bandFloors.count)
        for record in records where record.hours.count == bandFloors.count && record.catches.count == bandFloors.count {
            for band in bandFloors.indices {
                hours[band] += record.hours[band]
                catches[band] += record.catches[band]
            }
        }
        var summary = Summary(hours: hours, catches: catches, trips: records.count, verdict: .notEnough)
        guard summary.goodHours >= minHoursPerSide, summary.slowHours >= minHoursPerSide,
              summary.goodCatches + summary.slowCatches >= minCatches,
              let good = summary.goodRate, let slow = summary.slowRate else { return summary }
        if good >= slow * clearRatio {
            summary.verdict = .tracks
        } else if slow >= good * clearRatio {
            summary.verdict = .inverse
        } else {
            summary.verdict = .flat
        }
        return summary
    }
}
