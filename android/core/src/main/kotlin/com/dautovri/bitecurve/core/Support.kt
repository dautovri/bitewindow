package com.dautovri.bitecurve.core

import kotlin.math.pow

// Port of Sources/BiteCore/Support.swift. Times are seconds since 1970 (UTC) as Double,
// the same quantity Swift's Date carries, so the arithmetic matches the Swift engine.

/**
 * Conjugate Gamma–Poisson catch-rate multiplier for one user or one water body.
 * `mean` multiplies the global expected catch; it shrinks toward 1 until
 * roughly 20–30 trips have been logged. Zero-catch trips must be included.
 */
data class CatchRateMultiplier(val alpha: Double = 5.0, val beta: Double = 5.0) {
    val mean: Double get() = alpha / beta

    /**
     * @param catches fish caught on the trip (may be 0).
     * @param expected model-expected catch for that trip (rate × hours).
     */
    fun updated(catches: Int, expected: Double): CatchRateMultiplier {
        if (catches < 0 || !(expected > 0)) return this
        return CatchRateMultiplier(alpha + catches, beta + expected)
    }

    /** One finished trip: fish caught and the model-expected catch for it. */
    data class Observation(val catches: Int, val expected: Double)

    companion object {
        /** Posterior after folding in every observation. Order does not matter. */
        fun fitted(observations: List<Observation>, prior: CatchRateMultiplier = CatchRateMultiplier()): CatchRateMultiplier {
            var m = prior
            for (o in observations) m = m.updated(o.catches, o.expected)
            return m
        }
    }
}

/** One pressure reading: time in seconds since 1970, pressure in hPa. */
data class PressureSample(val time: Double, val hPa: Double)

object Barometry {
    fun hPaFromKPa(kPa: Double): Double = kPa * 10

    /** Device samples older than this are never read again (see the Swift source). */
    const val sampleRetention: Double = 72.0 * 3600

    /** Reduces station pressure to sea level. */
    fun seaLevel(stationHPa: Double, altitudeMeters: Double, tempC: Double): Double =
        stationHPa * (1 - 0.0065 * altitudeMeters / (tempC + 0.0065 * altitudeMeters + 273.15)).pow(-5.257)

    /** Median offset of device readings against forecast pressure at the same instants. */
    fun bias(device: List<Double>, forecast: List<Double>): Double? {
        val diffs = device.zip(forecast).map { (d, f) -> d - f }.sorted()
        if (diffs.isEmpty()) return null
        val mid = diffs.size / 2
        return if (diffs.size % 2 == 0) (diffs[mid - 1] + diffs[mid]) / 2 else diffs[mid]
    }

    /**
     * Replaces the forecast pressure trace with the phone barometer wherever the phone was
     * sampling. The offset between station and sea-level pressure is taken as the median
     * device − forecast difference; readings more than `maxResidual` hPa off it are dropped.
     * Returns `forecast` unchanged (sorted) when fewer than `minSamples` readings survive or
     * they span less than `minSpan` seconds.
     */
    fun fuse(
        forecast: List<PressureSample>, device: List<PressureSample>,
        minSamples: Int = 3, minSpan: Double = 1800.0, maxResidual: Double = 2.0,
    ): List<PressureSample> {
        val series = Terms.PressureSeries(forecast)
        val times = ArrayList<Double>()
        val readings = ArrayList<Double>()
        val expected = ArrayList<Double>()
        for (s in device.sortedBy { it.time }) {
            val f = series.value(s.time) ?: continue
            times.add(s.time); readings.add(s.hPa); expected.add(f)
        }
        val offset = bias(readings, expected) ?: return series.samples

        val kept = ArrayList<PressureSample>()
        for (i in times.indices) {
            if (kotlin.math.abs(readings[i] - expected[i] - offset) <= maxResidual) {
                kept.add(PressureSample(times[i], readings[i] - offset))
            }
        }
        if (kept.size < minSamples) return series.samples
        val first = kept.first()
        val last = kept.last()
        if (last.time - first.time < minSpan) return series.samples

        val out = ArrayList(series.samples.filter { it.time < first.time || it.time > last.time })
        out.addAll(kept)
        out.sortBy { it.time }
        return out
    }
}

object Geohash {
    private const val alphabet = "0123456789bcdefghjkmnpqrstuvwxyz"

    fun encode(latitude: Double, longitude: Double, precision: Int = 5): String {
        var latLo = -90.0
        var latHi = 90.0
        var lonLo = -180.0
        var lonHi = 180.0
        val hash = StringBuilder()
        var bit = 0
        var ch = 0
        var even = true
        while (hash.length < precision) {
            if (even) {
                val mid = (lonLo + lonHi) / 2
                if (longitude >= mid) { ch = ch shl 1 or 1; lonLo = mid } else { ch = ch shl 1; lonHi = mid }
            } else {
                val mid = (latLo + latHi) / 2
                if (latitude >= mid) { ch = ch shl 1 or 1; latLo = mid } else { ch = ch shl 1; latHi = mid }
            }
            even = !even
            bit += 1
            if (bit == 5) { hash.append(alphabet[ch]); bit = 0; ch = 0 }
        }
        return hash.toString()
    }

    /** Centre of the cell as (latitude, longitude), or null for an invalid hash. */
    fun decode(hash: String): Pair<Double, Double>? {
        var latLo = -90.0
        var latHi = 90.0
        var lonLo = -180.0
        var lonHi = 180.0
        var even = true
        for (c in hash.lowercase()) {
            val idx = alphabet.indexOf(c)
            if (idx < 0) return null
            for (shift in 4 downTo 0) {
                val on = (idx shr shift) and 1 == 1
                if (even) {
                    val mid = (lonLo + lonHi) / 2
                    if (on) lonLo = mid else lonHi = mid
                } else {
                    val mid = (latLo + latHi) / 2
                    if (on) latLo = mid else latHi = mid
                }
                even = !even
            }
        }
        return if (hash.isEmpty()) null else Pair((latLo + latHi) / 2, (lonLo + lonHi) / 2)
    }
}
