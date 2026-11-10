import Foundation

/// Harmonic tide prediction from station constituents (e.g. NOAA CO-OPS).
/// Supports the eight largest constituents; others in the input are ignored.
/// NOT validated against published predictions yet — see README.
public struct TideStation: Codable, Sendable, Equatable {
    public struct Constituent: Codable, Sendable, Equatable {
        /// "M2", "S2", "N2", "K2", "K1", "O1", "P1", "Q1"
        public var name: String
        /// Amplitude H in metres.
        public var amplitude: Double
        /// Greenwich phase lag κ in degrees.
        public var phase: Double

        public init(name: String, amplitude: Double, phase: Double) {
            self.name = name; self.amplitude = amplitude; self.phase = phase
        }
    }

    public var id: String
    public var name: String
    /// Mean level above chart datum, metres.
    public var meanLevel: Double
    public var constituents: [Constituent]

    public init(id: String, name: String, meanLevel: Double, constituents: [Constituent]) {
        self.id = id; self.name = name; self.meanLevel = meanLevel; self.constituents = constituents
    }

    /// Predicted height in metres above chart datum.
    public func height(at date: Date) -> Double {
        let jd = Astro.julianDay(date)
        let T = (jd - 2451545.0) / 36525
        // Mean longitudes: moon, sun, lunar perigee, lunar ascending node.
        let s = 218.3165 + 481267.8813 * T
        let h = 280.4661 + 36000.7698 * T
        let p = 83.3535 + 4069.0137 * T
        let N = (125.0445 - 1934.1363 * T) * Double.pi / 180
        let dayFraction = (jd + 0.5) - (jd + 0.5).rounded(.down)
        let t15 = 360 * dayFraction  // 15° per hour of UT

        var sum = meanLevel
        for c in constituents {
            let v: Double, f: Double, u: Double
            switch c.name.uppercased() {
            case "M2":
                v = 2 * t15 + 2 * h - 2 * s
                (f, u) = (1.0004 - 0.0373 * cos(N) + 0.0002 * cos(2 * N), -2.14 * sin(N))
            case "N2":
                v = 2 * t15 + 2 * h - 3 * s + p
                (f, u) = (1.0004 - 0.0373 * cos(N) + 0.0002 * cos(2 * N), -2.14 * sin(N))
            case "S2":
                v = 2 * t15
                (f, u) = (1, 0)
            case "K2":
                v = 2 * t15 + 2 * h
                f = 1.0241 + 0.2863 * cos(N) + 0.0083 * cos(2 * N) - 0.0015 * cos(3 * N)
                u = -17.74 * sin(N) + 0.68 * sin(2 * N) - 0.04 * sin(3 * N)
            case "K1":
                v = t15 + h + 90
                f = 1.0060 + 0.1150 * cos(N) - 0.0088 * cos(2 * N) + 0.0006 * cos(3 * N)
                u = -8.86 * sin(N) + 0.68 * sin(2 * N) - 0.07 * sin(3 * N)
            case "O1":
                v = t15 + h - 2 * s - 90
                f = 1.0089 + 0.1871 * cos(N) - 0.0147 * cos(2 * N) + 0.0014 * cos(3 * N)
                u = 10.80 * sin(N) - 1.34 * sin(2 * N) + 0.19 * sin(3 * N)
            case "Q1":
                v = t15 + h - 3 * s + p - 90
                f = 1.0089 + 0.1871 * cos(N) - 0.0147 * cos(2 * N) + 0.0014 * cos(3 * N)
                u = 10.80 * sin(N) - 1.34 * sin(2 * N) + 0.19 * sin(3 * N)
            case "P1":
                v = t15 - h - 90
                (f, u) = (1, 0)
            default:
                continue
            }
            sum += f * c.amplitude * cos((v + u - c.phase) * Double.pi / 180)
        }
        return sum
    }

    public struct Extreme: Sendable, Equatable {
        public let time: Date
        public let height: Double
        public let isHigh: Bool
    }

    /// High and low waters in `[from, to]`: sign changes of the rate, scanned
    /// every `step` seconds and refined by bisection to under a minute.
    public func extremes(from: Date, to: Date, step: TimeInterval = 600) -> [Extreme] {
        guard to > from, step > 0 else { return [] }
        var out: [Extreme] = []
        var t0 = from, r0 = rate(at: from)
        while t0 < to {
            let t1 = min(to, t0.addingTimeInterval(step))
            let r1 = rate(at: t1)
            if r0 > 0 && r1 <= 0 || r0 < 0 && r1 >= 0 {
                var lo = t0, hi = t1
                let rising = r0 > 0
                while hi.timeIntervalSince(lo) > 30 {
                    let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
                    if (rate(at: mid) > 0) == rising { lo = mid } else { hi = mid }
                }
                let t = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
                out.append(Extreme(time: t, height: height(at: t), isHigh: rising))
            }
            t0 = t1; r0 = r1
        }
        return out
    }

    /// Rate of change in metres per hour (central difference over 10 minutes).
    public func rate(at date: Date) -> Double {
        let dt: TimeInterval = 300
        return (height(at: date.addingTimeInterval(dt)) - height(at: date.addingTimeInterval(-dt))) / (2 * dt / 3600)
    }
}
