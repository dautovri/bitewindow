package com.dautovri.bitecurve.core

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt
import kotlin.math.tanh

/**
 * Port of Sources/BiteCore/Terms.swift: sub-scores of the bite model. Every term maps to z in
 * [-1, 1], 0 = neutral. Numeric constants are the same heuristic priors as in the Swift engine.
 */
object Terms {

    // Frontal / pressure

    /** A time-ordered sea-level pressure series in hPa. */
    class PressureSeries(samples: List<PressureSample>) {
        val samples: List<PressureSample> = samples.sortedBy { it.time }

        /** Linear interpolation; null outside the covered range. */
        fun value(t: Double): Double? {
            val first = samples.firstOrNull() ?: return null
            val last = samples.last()
            if (t < first.time || t > last.time) return null
            var lo = 0
            var hi = samples.size - 1
            while (hi - lo > 1) {
                val mid = (lo + hi) / 2
                if (samples[mid].time <= t) lo = mid else hi = mid
            }
            val a = samples[lo]
            val b = samples[hi]
            val span = b.time - a.time
            if (!(span > 0)) return a.hPa
            val f = (t - a.time) / span
            return a.hPa + (b.hPa - a.hPa) * f
        }

        /** P(t) - P(t - hours); null when either end is missing. */
        fun delta(t: Double, hours: Double): Double? {
            val now = value(t) ?: return null
            val then = value(t - hours * 3600) ?: return null
            return now - then
        }
    }

    /**
     * Pressure is modelled as a frontal-passage detector, not as an absolute level.
     * Missing history makes the affected component neutral.
     */
    fun pressure(series: PressureSeries, t: Double, cloudCover: Double): Double {
        val fall = series.delta(t, 6.0)?.let { tanh(-it / 3) } ?: 0.0
        val post = series.delta(t, 24.0)?.let { d24 ->
            if (cloudCover < 0.3) -tanh(max(0.0, d24 - 4) / 4) else 0.0
        } ?: 0.0
        val stab = series.delta(t, 48.0)?.let { exp(-(it / 3).pow(2)) - 0.5 } ?: 0.0
        return 0.5 * fall + 0.35 * post + 0.15 * stab
    }

    // Solunar

    /** `majors` are lunar upper/lower transits, `minors` are moonrise/moonset. */
    fun solunar(t: Double, majors: List<Double>, minors: List<Double>, phaseAngle: Double): Double {
        fun kernel(events: List<Double>, sigmaMinutes: Double): Double =
            events.maxOfOrNull { e ->
                val dm = (t - e) / 60
                exp(-(dm * dm) / (2 * sigmaMinutes * sigmaMinutes))
            } ?: 0.0
        val s = max(kernel(majors, 45.0), 0.6 * kernel(minors, 30.0))
        val m = 0.75 + 0.25 * abs(cos(phaseAngle * Math.PI / 180))
        return 2 * s * m - 1
    }

    // Light

    /** Unknown cloud cover (`null`) makes the cloud component neutral. */
    fun light(t: Double, sunrise: Double?, sunset: Double?, cloudCover: Double?): Double {
        fun bump(e: Double?): Double {
            if (e == null) return 0.0
            val dm = (t - e) / 60
            return exp(-(dm / 60).pow(2))
        }
        // Polar day or polar night: no sunrise and no sunset. Neutral, not the
        // bright-noon penalty for all 24 hours.
        val twilight = if (sunrise == null && sunset == null) 0.0 else 2 * max(bump(sunrise), bump(sunset)) - 1
        val cloud = cloudCover?.let { 2 * (1 - (1 - max(0.0, min(1.0, it))).pow(2)) - 1 } ?: 0.0
        return 0.7 * twilight + 0.3 * cloud
    }

    // Thermal

    /** Asymmetric thermal performance curve on water temperature (°C). */
    fun thermal(waterTempC: Double, species: Species): Double {
        // "Any fish" has no preferred temperature.
        if (species == Species.GENERAL) return 0.0
        val p = species.thermal
        val f = if (waterTempC <= p.optimum) {
            exp(-((waterTempC - p.optimum) / p.sigmaLow).pow(2))
        } else {
            max(0.0, 1 - ((waterTempC - p.optimum) / (p.criticalMax - p.optimum)).pow(2))
        }
        return 2 * f - 1
    }

    /**
     * Rough surface water temperature when none was measured: the mean air temperature of the
     * last 72 h before `now`, kept to 1...30 °C. Needs at least 24 hours of that history.
     */
    fun estimatedWaterTempC(hours: List<HourConditions>, now: Double): Double? {
        val past = hours.filter { it.time <= now && it.time > now - 72 * 3600 }
        if (past.size < 24) return null
        val mean = past.fold(0.0) { acc, h -> acc + h.airTempC } / past.size
        return min(30.0, max(1.0, mean))
    }

    /** One daily step of the air-to-water lag model. */
    fun waterTempStep(previousC: Double, airMean7dC: Double, tauDays: Double = 8.0): Double =
        previousC + (airMean7dC - previousC) / tauDays

    // Wind

    /**
     * @param speedKmh sustained wind speed.
     * @param towardDeg compass bearing the wind blows toward.
     * @param bankBearingDeg bearing from open water to the fished bank; null = unknown.
     */
    fun wind(speedKmh: Double, towardDeg: Double?, bankBearingDeg: Double?): Double {
        if (speedKmh > 35) return -1.0
        val zU = 2 * exp(-((speedKmh - 18) / 12).pow(2)) - 1
        var zDir = 0.0
        if (towardDeg != null && bankBearingDeg != null) {
            zDir = cos((towardDeg - bankBearingDeg) * Math.PI / 180)
        }
        return 0.6 * zU + 0.4 * zDir
    }

    /** Fetch-limited significant wave height in metres (JONSWAP form). */
    fun waveHeight(windMs: Double, fetchMeters: Double): Double = 1.6e-3 * windMs * sqrt(fetchMeters / 9.81)

    // Tide

    /**
     * Moving water fishes better than slack. Within the day the rate is scaled to the day's
     * strongest flow. With `maxRateOfCycle` 30 % of the term says how strong the day's tides are.
     */
    fun tide(rate: Double, maxRateOfDay: Double, maxRateOfCycle: Double? = null): Double {
        if (!(maxRateOfDay > 0)) return 0.0
        val withinDay = 2 * min(1.0, abs(rate) / maxRateOfDay) - 1
        if (maxRateOfCycle == null || !(maxRateOfCycle > 0)) return withinDay
        val dayStrength = 2 * min(1.0, maxRateOfDay / maxRateOfCycle) - 1
        return 0.7 * withinDay + 0.3 * dayStrength
    }

    /**
     * Spring-neap proxy from the moon phase alone, for saltwater spots without a tide station:
     * 1 at new and full moon (spring tides), −1 at the quarters (neap tides).
     */
    fun springTide(phaseAngle: Double): Double = cos(2 * phaseAngle * Math.PI / 180)
}
