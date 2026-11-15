package com.dautovri.bitecurve.core

import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Port of Sources/BiteCore/Astro.swift: low-precision sun and moon ephemerides
 * (Astronomical Almanac series). Sun ~0.01°, moon ~0.3° in longitude, enough for
 * rise/set/transit times within a couple of minutes. Fully offline.
 */
object Astro {
    internal const val deg2rad = Math.PI / 180
    internal const val rad2deg = 180 / Math.PI

    enum class Body { SUN, MOON }

    /** [ra], [dec], [lon] and [parallax] in degrees. */
    data class Position(val ra: Double, val dec: Double, val lon: Double, val parallax: Double)

    fun julianDay(time: Double): Double = time / 86400 + 2440587.5

    internal fun norm360(x: Double): Double {
        val r = x % 360
        return if (r < 0) r + 360 else r
    }

    /** Wraps to (-180, 180]. */
    internal fun wrap180(x: Double): Double {
        val r = norm360(x)
        return if (r > 180) r - 360 else r
    }

    internal fun sinD(d: Double): Double = sin(d * deg2rad)
    internal fun cosD(d: Double): Double = cos(d * deg2rad)

    internal fun obliquity(jd: Double): Double = 23.439 - 0.0000004 * (jd - 2451545.0)

    internal fun equatorial(lon: Double, lat: Double, jd: Double, parallax: Double): Position {
        val eps = obliquity(jd)
        val l = cosD(lat) * cosD(lon)
        val m = cosD(eps) * cosD(lat) * sinD(lon) - sinD(eps) * sinD(lat)
        val n = sinD(eps) * cosD(lat) * sinD(lon) + cosD(eps) * sinD(lat)
        val ra = norm360(atan2(m, l) * rad2deg)
        val dec = asin(max(-1.0, min(1.0, n))) * rad2deg
        return Position(ra, dec, norm360(lon), parallax)
    }

    fun sun(jd: Double): Position {
        val n = jd - 2451545.0
        val L = norm360(280.460 + 0.9856474 * n)
        val g = norm360(357.528 + 0.9856003 * n)
        val lambda = L + 1.915 * sinD(g) + 0.020 * sinD(2 * g)
        return equatorial(lambda, 0.0, jd, 0.0)
    }

    fun moon(jd: Double): Position {
        val t = (jd - 2451545.0) / 36525
        val lambda = 218.32 + 481267.881 * t +
            6.29 * sinD(135.0 + 477198.87 * t) -
            1.27 * sinD(259.3 - 413335.36 * t) +
            0.66 * sinD(235.7 + 890534.22 * t) +
            0.21 * sinD(269.9 + 954397.74 * t) -
            0.19 * sinD(357.5 + 35999.05 * t) -
            0.11 * sinD(186.5 + 966404.03 * t)
        val beta = 5.13 * sinD(93.3 + 483202.02 * t) +
            0.28 * sinD(228.2 + 960400.89 * t) -
            0.28 * sinD(318.3 + 6003.15 * t) -
            0.17 * sinD(217.6 - 407332.21 * t)
        val par = 0.9508 +
            0.0518 * cosD(135.0 + 477198.87 * t) +
            0.0095 * cosD(259.3 - 413335.36 * t) +
            0.0078 * cosD(235.7 + 890534.22 * t) +
            0.0028 * cosD(269.9 + 954397.74 * t)
        return equatorial(lambda, beta, jd, par)
    }

    fun position(body: Body, jd: Double): Position = if (body == Body.SUN) sun(jd) else moon(jd)

    /** Greenwich mean sidereal time, degrees. */
    internal fun gmst(jd: Double): Double = norm360(280.46061837 + 360.98564736629 * (jd - 2451545.0))

    /** Local hour angle in (-180, 180]; 0 at upper transit. */
    fun hourAngle(body: Body, time: Double, longitude: Double): Double {
        val jd = julianDay(time)
        return wrap180(gmst(jd) + longitude - position(body, jd).ra)
    }

    /** Geocentric altitude above the horizon, degrees. */
    fun altitude(body: Body, time: Double, latitude: Double, longitude: Double): Double {
        val jd = julianDay(time)
        val p = position(body, jd)
        val h = gmst(jd) + longitude - p.ra
        val s = sinD(latitude) * sinD(p.dec) + cosD(latitude) * cosD(p.dec) * cosD(h)
        return asin(max(-1.0, min(1.0, s))) * rad2deg
    }

    /** Geocentric altitude at which the upper limb touches the horizon. */
    internal fun horizonAltitude(body: Body, jd: Double): Double = when (body) {
        Body.SUN -> -0.833
        Body.MOON -> 0.7275 * moon(jd).parallax - 0.5667
    }

    /** Sun–moon elongation in degrees: 0 = new, 180 = full. */
    fun moonPhaseAngle(time: Double): Double {
        val jd = julianDay(time)
        return norm360(moon(jd).lon - sun(jd).lon)
    }

    /** Illuminated fraction of the lunar disc, 0...1. */
    fun moonIllumination(time: Double): Double = (1 - cosD(moonPhaseAngle(time))) / 2

    class Events(
        val rises: List<Double>,
        val sets: List<Double>,
        val upperTransits: List<Double>,
        val lowerTransits: List<Double>,
    )

    /**
     * Finds rise, set and transit times in `[start, end]` by scanning in
     * 5-minute steps and bisecting each bracket to about one second.
     */
    fun events(body: Body, from: Double, to: Double, latitude: Double, longitude: Double): Events {
        val rises = ArrayList<Double>()
        val sets = ArrayList<Double>()
        val uppers = ArrayList<Double>()
        val lowers = ArrayList<Double>()
        val step = 300.0

        fun horizon(d: Double): Double =
            altitude(body, d, latitude, longitude) - horizonAltitude(body, julianDay(d))
        fun upper(d: Double): Double = hourAngle(body, d, longitude)
        fun lower(d: Double): Double = wrap180(upper(d) + 180)

        fun bisect(f: (Double) -> Double, a: Double, b: Double): Double {
            var lo = a
            var hi = b
            var flo = f(lo)
            while (hi - lo > 1) {
                val mid = lo + (hi - lo) / 2
                val fm = f(mid)
                if ((fm < 0) == (flo < 0)) { lo = mid; flo = fm } else { hi = mid }
            }
            return lo + (hi - lo) / 2
        }

        var t0 = from
        var h0 = horizon(t0)
        var u0 = upper(t0)
        var l0 = lower(t0)
        while (t0 < to) {
            val t1 = min(t0 + step, to)
            val h1 = horizon(t1)
            val u1 = upper(t1)
            val l1 = lower(t1)
            if (h0 < 0 && h1 >= 0) rises.add(bisect(::horizon, t0, t1))
            if (h0 >= 0 && h1 < 0) sets.add(bisect(::horizon, t0, t1))
            // Hour angle increases through zero at transit; ignore the ±180 wrap.
            if (u0 < 0 && u1 >= 0 && u1 - u0 < 180) uppers.add(bisect(::upper, t0, t1))
            if (l0 < 0 && l1 >= 0 && l1 - l0 < 180) lowers.add(bisect(::lower, t0, t1))
            t0 = t1; h0 = h1; u0 = u1; l0 = l1
        }
        return Events(rises, sets, uppers, lowers)
    }
}
