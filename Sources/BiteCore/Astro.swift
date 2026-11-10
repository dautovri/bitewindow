import Foundation

/// Low-precision sun and moon ephemerides (Astronomical Almanac series).
/// Accuracy: sun ~0.01°, moon ~0.3° in longitude — enough for rise/set/transit
/// times within a couple of minutes, which is all the scoring model needs.
/// Fully offline; no network or system astronomy API.
public enum Astro {
    static let deg2rad = Double.pi / 180
    static let rad2deg = 180 / Double.pi

    public enum Body: Sendable { case sun, moon }

    public struct Position: Sendable {
        /// Right ascension, degrees.
        public let ra: Double
        /// Declination, degrees.
        public let dec: Double
        /// Ecliptic longitude, degrees.
        public let lon: Double
        /// Horizontal parallax, degrees (0 for the sun at this precision).
        public let parallax: Double
    }

    public static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400 + 2440587.5
    }

    static func norm360(_ x: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Wraps to (-180, 180].
    static func wrap180(_ x: Double) -> Double {
        let r = norm360(x)
        return r > 180 ? r - 360 : r
    }

    static func sinD(_ d: Double) -> Double { sin(d * deg2rad) }
    static func cosD(_ d: Double) -> Double { cos(d * deg2rad) }

    static func obliquity(_ jd: Double) -> Double {
        23.439 - 0.0000004 * (jd - 2451545.0)
    }

    static func equatorial(lon: Double, lat: Double, jd: Double, parallax: Double) -> Position {
        let eps = obliquity(jd)
        let l = cosD(lat) * cosD(lon)
        let m = cosD(eps) * cosD(lat) * sinD(lon) - sinD(eps) * sinD(lat)
        let n = sinD(eps) * cosD(lat) * sinD(lon) + cosD(eps) * sinD(lat)
        let ra = norm360(atan2(m, l) * rad2deg)
        let dec = asin(max(-1, min(1, n))) * rad2deg
        return Position(ra: ra, dec: dec, lon: norm360(lon), parallax: parallax)
    }

    public static func sun(jd: Double) -> Position {
        let n = jd - 2451545.0
        let L = norm360(280.460 + 0.9856474 * n)
        let g = norm360(357.528 + 0.9856003 * n)
        let lambda = L + 1.915 * sinD(g) + 0.020 * sinD(2 * g)
        return equatorial(lon: lambda, lat: 0, jd: jd, parallax: 0)
    }

    public static func moon(jd: Double) -> Position {
        let t = (jd - 2451545.0) / 36525
        let lambda = 218.32 + 481267.881 * t
            + 6.29 * sinD(135.0 + 477198.87 * t)
            - 1.27 * sinD(259.3 - 413335.36 * t)
            + 0.66 * sinD(235.7 + 890534.22 * t)
            + 0.21 * sinD(269.9 + 954397.74 * t)
            - 0.19 * sinD(357.5 + 35999.05 * t)
            - 0.11 * sinD(186.5 + 966404.03 * t)
        let beta = 5.13 * sinD(93.3 + 483202.02 * t)
            + 0.28 * sinD(228.2 + 960400.89 * t)
            - 0.28 * sinD(318.3 + 6003.15 * t)
            - 0.17 * sinD(217.6 - 407332.21 * t)
        let par = 0.9508
            + 0.0518 * cosD(135.0 + 477198.87 * t)
            + 0.0095 * cosD(259.3 - 413335.36 * t)
            + 0.0078 * cosD(235.7 + 890534.22 * t)
            + 0.0028 * cosD(269.9 + 954397.74 * t)
        return equatorial(lon: lambda, lat: beta, jd: jd, parallax: par)
    }

    public static func position(_ body: Body, jd: Double) -> Position {
        body == .sun ? sun(jd: jd) : moon(jd: jd)
    }

    /// Greenwich mean sidereal time, degrees.
    static func gmst(_ jd: Double) -> Double {
        norm360(280.46061837 + 360.98564736629 * (jd - 2451545.0))
    }

    /// Local hour angle in (-180, 180]; 0 at upper transit.
    public static func hourAngle(_ body: Body, date: Date, longitude: Double) -> Double {
        let jd = julianDay(date)
        return wrap180(gmst(jd) + longitude - position(body, jd: jd).ra)
    }

    /// Geocentric altitude above the horizon, degrees.
    public static func altitude(_ body: Body, date: Date, latitude: Double, longitude: Double) -> Double {
        let jd = julianDay(date)
        let p = position(body, jd: jd)
        let h = gmst(jd) + longitude - p.ra
        let s = sinD(latitude) * sinD(p.dec) + cosD(latitude) * cosD(p.dec) * cosD(h)
        return asin(max(-1, min(1, s))) * rad2deg
    }

    /// Geocentric altitude at which the upper limb touches the horizon.
    static func horizonAltitude(_ body: Body, jd: Double) -> Double {
        switch body {
        case .sun: return -0.833
        case .moon: return 0.7275 * moon(jd: jd).parallax - 0.5667
        }
    }

    /// Sun–moon elongation in degrees: 0 = new, 180 = full.
    public static func moonPhaseAngle(_ date: Date) -> Double {
        let jd = julianDay(date)
        return norm360(moon(jd: jd).lon - sun(jd: jd).lon)
    }

    /// Illuminated fraction of the lunar disc, 0...1.
    public static func moonIllumination(_ date: Date) -> Double {
        (1 - cosD(moonPhaseAngle(date))) / 2
    }

    public struct Events: Sendable {
        public var rises: [Date] = []
        public var sets: [Date] = []
        public var upperTransits: [Date] = []
        public var lowerTransits: [Date] = []
    }

    /// Finds rise, set and transit times in `[start, end]` by scanning in
    /// 5-minute steps and bisecting each bracket to about one second.
    public static func events(_ body: Body, from start: Date, to end: Date,
                              latitude: Double, longitude: Double) -> Events {
        var out = Events()
        let step: TimeInterval = 300

        func horizon(_ d: Date) -> Double {
            altitude(body, date: d, latitude: latitude, longitude: longitude)
                - horizonAltitude(body, jd: julianDay(d))
        }
        func upper(_ d: Date) -> Double { hourAngle(body, date: d, longitude: longitude) }
        func lower(_ d: Date) -> Double { wrap180(upper(d) + 180) }

        func bisect(_ f: (Date) -> Double, _ a: Date, _ b: Date) -> Date {
            var lo = a, hi = b
            var flo = f(lo)
            while hi.timeIntervalSince(lo) > 1 {
                let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
                let fm = f(mid)
                if (fm < 0) == (flo < 0) { lo = mid; flo = fm } else { hi = mid }
            }
            return lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
        }

        var t0 = start
        var h0 = horizon(t0), u0 = upper(t0), l0 = lower(t0)
        while t0 < end {
            let t1 = min(t0.addingTimeInterval(step), end)
            let h1 = horizon(t1), u1 = upper(t1), l1 = lower(t1)
            if h0 < 0, h1 >= 0 { out.rises.append(bisect(horizon, t0, t1)) }
            if h0 >= 0, h1 < 0 { out.sets.append(bisect(horizon, t0, t1)) }
            // Hour angle increases through zero at transit; ignore the ±180 wrap.
            if u0 < 0, u1 >= 0, u1 - u0 < 180 { out.upperTransits.append(bisect(upper, t0, t1)) }
            if l0 < 0, l1 >= 0, l1 - l0 < 180 { out.lowerTransits.append(bisect(lower, t0, t1)) }
            t0 = t1; h0 = h1; u0 = u1; l0 = l1
        }
        return out
    }
}
