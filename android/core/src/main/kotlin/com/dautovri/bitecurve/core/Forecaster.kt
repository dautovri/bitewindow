package com.dautovri.bitecurve.core

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

// Port of Sources/BiteCore/Forecaster.swift.

/** One hour of weather input, in the units the worker returns. `time` is seconds since 1970. */
data class HourConditions(
    val time: Double,
    /** Sea-level pressure, hPa (millibars). */
    val pressureHPa: Double,
    /** 0...1 */
    val cloudCover: Double,
    val windSpeedKmh: Double,
    /** Compass bearing the wind comes FROM, degrees. */
    val windFromDeg: Double?,
    val airTempC: Double,
)

data class SpotContext(
    val latitude: Double,
    val longitude: Double,
    val water: WaterType,
    val species: Species,
    /** Bearing from open water to the fished bank; null when unknown. */
    val bankBearingDeg: Double? = null,
    /** Measured water temperature. When null the thermal term is neutral. */
    val waterTempC: Double? = null,
    val tide: TideStation? = null,
)

/** Weighted contribution (w · z) of each factor at one instant. */
data class Contributions(
    val light: Double = 0.0, val thermal: Double = 0.0, val wind: Double = 0.0,
    val pressure: Double = 0.0, val solunar: Double = 0.0, val tide: Double = 0.0,
) {
    val total: Double get() = light + thermal + wind + pressure + solunar + tide
}

data class ScorePoint(
    val time: Double,
    /** Bite index, 0...100. 50 = neutral. */
    val index: Double,
    val contributions: Contributions,
    /** False when no weather covered this instant (see `fillMissingWeather`). */
    val hasWeather: Boolean = true,
)

data class BiteWindow(val start: Double, val end: Double, val meanIndex: Double)

/** How one species is biting at a spot at one instant. */
data class SpeciesOutlook(val species: Species, val index: Double)

object Forecaster {
    /** Logistic gain. With k = 3 a fully favourable day (Σ w·z ≈ 0.9) scores ~94. */
    const val gain = 3.0

    fun index(c: Contributions): Double = 100 / (1 + exp(-gain * c.total))

    internal fun interpolate(hours: List<HourConditions>, t: Double): HourConditions? {
        val first = hours.firstOrNull() ?: return null
        val last = hours.last()
        if (t < first.time || t > last.time) return null
        val hi = hours.indexOfFirst { it.time >= t }
        if (hi < 0) return null
        if (hi == 0) return hours[0]
        val a = hours[hi - 1]
        val b = hours[hi]
        val span = b.time - a.time
        val f = if (span > 0) (t - a.time) / span else 0.0
        fun mix(x: Double, y: Double): Double = x + (y - x) * f
        return HourConditions(
            time = t,
            pressureHPa = mix(a.pressureHPa, b.pressureHPa),
            cloudCover = mix(a.cloudCover, b.cloudCover),
            windSpeedKmh = mix(a.windSpeedKmh, b.windSpeedKmh),
            windFromDeg = if (f < 0.5) a.windFromDeg else b.windFromDeg,
            airTempC = mix(a.airTempC, b.airTempC),
        )
    }

    /**
     * Scores `[from, to]` every `step` seconds. `hours` should start 48 h before `from` so
     * pressure deltas are defined; instants without weather are skipped. `pressure` overrides
     * the pressure trace taken from `hours`. With `fillMissingWeather`, instants without
     * weather are scored anyway with wind, pressure and cloud neutral; those points carry
     * `hasWeather == false`.
     */
    fun curve(
        context: SpotContext, hours: List<HourConditions>,
        from: Double, to: Double, step: Double = 900.0,
        weights: Weights? = null,
        pressure: Terms.PressureSeries? = null,
        fillMissingWeather: Boolean = false,
    ): List<ScorePoint> {
        val sortedHours = hours.sortedBy { it.time }
        val w = weights ?: Weights.prior(context.water, context.species)
        val series = pressure ?: Terms.PressureSeries(sortedHours.map { PressureSample(it.time, it.pressureHPa) })

        val pad = 86400.0
        val sun = Astro.events(Astro.Body.SUN, from - pad, to + pad, context.latitude, context.longitude)
        val moon = Astro.events(Astro.Body.MOON, from - pad, to + pad, context.latitude, context.longitude)
        val majors = moon.upperTransits + moon.lowerTransits
        val minors = moon.rises + moon.sets

        fun nearest(events: List<Double>, t: Double): Double? = events.minByOrNull { abs(it - t) }

        val times = ArrayList<Double>()
        var t = from
        while (t <= to) { times.add(t); t += step }

        val station = context.tide
        val tideRates: List<Double>? = station?.let { s -> times.map { s.rate(it) } }
        val halfDaySteps = max(1, ((12.5 * 3600) / step).toInt())
        // Strongest flow of the spring-neap cycle (14.8 days) around the scored range, hourly.
        val cyclePeak: Double? = station?.let { s ->
            val half = 7.4 * 86400
            var peak = 0.0
            var u = from - half
            while (u <= to + half) {
                peak = max(peak, abs(s.rate(u)))
                u += 3600
            }
            peak
        }
        val isSalt = context.water.isSalt

        val out = ArrayList<ScorePoint>()
        for ((i, time) in times.withIndex()) {
            val weather = interpolate(sortedHours, time)
            if (weather == null && !fillMissingWeather) continue
            val light = w.light * Terms.light(time, nearest(sun.rises, time), nearest(sun.sets, time), weather?.cloudCover)
            val thermal = context.waterTempC?.let { w.thermal * Terms.thermal(it, context.species) } ?: 0.0
            var wind = 0.0
            var press = 0.0
            if (weather != null) {
                wind = w.wind * Terms.wind(weather.windSpeedKmh, weather.windFromDeg?.let { it + 180 }, context.bankBearingDeg)
                press = w.pressure * Terms.pressure(series, time, weather.cloudCover)
            }
            val solunar = w.solunar * Terms.solunar(time, majors, minors, Astro.moonPhaseAngle(time))
            var tide = 0.0
            if (tideRates != null && w.tide > 0) {
                val lo = max(0, i - halfDaySteps)
                val hi = min(tideRates.size - 1, i + halfDaySteps)
                var peak = 0.0
                for (k in lo..hi) peak = max(peak, abs(tideRates[k]))
                tide = w.tide * Terms.tide(tideRates[i], peak, cyclePeak)
            } else if (isSalt && w.tide > 0) {
                // No station: the moon phase stands in for spring and neap tides, at half weight
                // because the timing of the flow within the day is unknown.
                tide = w.tide * 0.5 * Terms.springTide(Astro.moonPhaseAngle(time))
            }
            val c = Contributions(light, thermal, wind, press, solunar, tide)
            out.add(ScorePoint(time, index(c), c, weather != null))
        }
        return out
    }

    /**
     * Highest-mean contiguous window of the given length. With `notBefore`, only windows
     * starting at or after that time count.
     */
    fun bestWindow(points: List<ScorePoint>, length: Double = 7200.0, notBefore: Double? = null): BiteWindow? {
        val pts = if (notBefore != null) points.filter { it.time >= notBefore } else points
        if (pts.size < 2) return null
        var best: BiteWindow? = null
        var j = 0
        var sum = 0.0
        for (i in pts.indices) {
            sum += pts[i].index
            while (pts[i].time - pts[j].time > length) {
                sum -= pts[j].index
                j += 1
            }
            val covered = pts[i].time - pts[j].time
            if (covered < length * 0.9) continue
            val mean = sum / (i - j + 1)
            if (best == null || mean > best.meanIndex) {
                best = BiteWindow(pts[j].time, pts[i].time, mean)
            }
        }
        return best
    }

    /**
     * Every species that lives in the spot's water scored at `now`, ordered by how well the
     * water temperature suits it (then by index). Empty without a water temperature.
     */
    fun speciesNow(context: SpotContext, hours: List<HourConditions>, now: Double, waterTempC: Double?): List<SpeciesOutlook> {
        if (waterTempC == null) return emptyList()
        // Sun, moon, weather and tide are scored once; species change only the thermal term and
        // the solunar weight, so each species re-weights that one point.
        val base = context.copy(waterTempC = null)
        val point = curve(base, hours, now, now, fillMissingWeather = true).firstOrNull() ?: return emptyList()
        val c = point.contributions
        val baseSolunarWeight = Weights.prior(context.water, context.species).solunar
        val solunarZ = if (baseSolunarWeight > 0) c.solunar / baseSolunarWeight else 0.0
        val scored = ArrayList<Pair<SpeciesOutlook, Double>>()
        for (species in Species.entries) {
            if (species == Species.GENERAL || !species.livesIn(context.water)) continue
            val w = Weights.prior(context.water, species)
            val fit = Terms.thermal(waterTempC, species)
            val sc = c.copy(thermal = w.thermal * fit, solunar = w.solunar * solunarZ)
            scored.add(Pair(SpeciesOutlook(species, index(sc)), fit))
        }
        scored.sortWith { a, b ->
            if (a.second != b.second) b.second.compareTo(a.second) else b.first.index.compareTo(a.first.index)
        }
        return scored.map { it.first }
    }

    /** Summer depth guidance for stratified lakes. Location advice only. */
    fun depthAdvice(maxDepthMeters: Double, surfaceTempC: Double, species: Species): String? {
        if (!(maxDepthMeters > 6) || !(surfaceTempC > species.thermal.optimum + 2)) return null
        return "Lake is likely stratified: target the thermocline band and avoid the deep basin, where oxygen runs low."
    }
}
