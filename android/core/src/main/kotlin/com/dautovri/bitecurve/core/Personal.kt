package com.dautovri.bitecurve.core

import kotlinx.serialization.Serializable
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

// Port of Sources/BiteCore/Personal.swift (the barometer fusion lives in Support.kt).

/**
 * Turns the bite index into an expected catch, so logged trips (including
 * blanks) can be compared with what the global model predicted.
 */
object CatchModel {
    /** Catch rate of an average angler at a neutral index (50). Placeholder, as in Swift. */
    const val baselineFishPerHour = 0.5

    /** Trips longer than this are treated as "forgot to end the trip". */
    const val maxTripHours = 24.0

    /** Catch rate relative to a neutral hour: index 50 -> 1, 100 -> 2, 0 -> 0. */
    fun relativeRate(index: Double): Double = max(0.0, min(100.0, index)) / 50

    /**
     * Expected catch over `[from, to]` under the global model: `baseline · ∫ relativeRate dt`.
     * Time not covered by `points` counts as neutral.
     */
    fun expectedCatch(points: List<ScorePoint>, from: Double, to: Double, baseline: Double = baselineFishPerHour): Double {
        val duration = to - from
        if (!(duration > 0) || !(baseline > 0)) return 0.0
        val sorted = points.sortedBy { it.time }

        fun index(t: Double): Double {
            val first = sorted.firstOrNull() ?: return 50.0
            val last = sorted.last()
            if (t < first.time || t > last.time) return 50.0
            var lo = 0
            var hi = sorted.size - 1
            while (hi - lo > 1) {
                val mid = (lo + hi) / 2
                if (sorted[mid].time <= t) lo = mid else hi = mid
            }
            val a = sorted[lo]
            val b = sorted[hi]
            val span = b.time - a.time
            if (!(span > 0)) return a.index
            val f = (t - a.time) / span
            return a.index + (b.index - a.index) * f
        }

        // Midpoint rule on slices of at most 5 minutes.
        val n = max(1, ceil(duration / 300).toInt())
        val dt = duration / n
        var relativeHours = 0.0
        for (k in 0 until n) {
            val t = from + (k + 0.5) * dt
            relativeHours += relativeRate(index(t)) * dt / 3600
        }
        return baseline * relativeHours
    }
}

/**
 * A stretch of a trip with the fish caught in it and the mean of each factor's own score,
 * before weighting, in the order light, thermal, wind, pressure, solunar, tide.
 */
@Serializable
data class FactorSlice(val hours: Double, val catches: Int, val z: List<Double>)

/**
 * Checks the forecast against what was caught: every fishing hour and every fish is filed
 * under the bite index the forecast gave for that moment.
 */
object Scorecard {
    /** Lower edges of the four index bands: slow, below average, above average, strong. */
    val bandFloors: List<Double> = listOf(0.0, 35.0, 50.0, 65.0)

    /** The first band that counts as a good forecast (index 50 and up). */
    const val firstGoodBand = 2

    fun band(index: Double): Int {
        val i = bandFloors.indexOfLast { index >= it }
        return if (i < 0) 0 else i
    }

    /** One trip, split by the forecast band of each moment. */
    data class TripRecord(val hours: List<Double>, val catches: List<Int>, val meanIndex: Double)

    /**
     * Files a trip under the forecast bands. Null when the forecast does not cover the whole
     * trip (nothing is guessed), or a catch lies outside it.
     */
    fun record(points: List<ScorePoint>, from: Double, to: Double, catchTimes: List<Double>): TripRecord? {
        val sorted = points.sortedBy { it.time }
        val duration = to - from
        // The curve is sampled every 15 minutes, so allow that much slack at each end.
        if (!(duration > 0) || sorted.size < 2) return null
        val first = sorted.first()
        val last = sorted.last()
        if (!(first.time <= from + 900) || !(last.time >= to - 900)) return null

        fun index(t: Double): Double {
            if (t <= first.time) return first.index
            if (t >= last.time) return last.index
            var lo = 0
            var hi = sorted.size - 1
            while (hi - lo > 1) {
                val mid = (lo + hi) / 2
                if (sorted[mid].time <= t) lo = mid else hi = mid
            }
            val a = sorted[lo]
            val b = sorted[hi]
            val span = b.time - a.time
            if (!(span > 0)) return a.index
            return a.index + (b.index - a.index) * (t - a.time) / span
        }

        val hours = DoubleArray(bandFloors.size)
        val catches = IntArray(bandFloors.size)
        val n = max(1, ceil(duration / 300).toInt())
        val dt = duration / n
        var weighted = 0.0
        for (k in 0 until n) {
            val value = index(from + (k + 0.5) * dt)
            hours[band(value)] += dt / 3600
            weighted += value * dt
        }
        for (time in catchTimes) {
            if (!(time >= from - 60) || !(time <= to + 60)) return null
            catches[band(index(time))] += 1
        }
        return TripRecord(hours.toList(), catches.toList(), weighted / duration)
    }

    enum class Verdict {
        /** Too little fishing on one side of the line to compare. */
        NOT_ENOUGH,
        /** Fish came clearly faster in good hours. */
        TRACKS,
        /** No clear difference. */
        FLAT,
        /** Fish came clearly faster in slow hours. */
        INVERSE,
    }

    data class Summary(val hours: List<Double>, val catches: List<Int>, val trips: Int, val verdict: Verdict) {
        /** Fish per hour in a band; null with under half an hour fished in it. */
        fun rate(band: Int): Double? = if (hours[band] >= 0.5) catches[band] / hours[band] else null

        val goodHours: Double get() = hours.drop(firstGoodBand).fold(0.0) { a, b -> a + b }
        val slowHours: Double get() = hours.take(firstGoodBand).fold(0.0) { a, b -> a + b }
        val goodCatches: Int get() = catches.drop(firstGoodBand).sum()
        val slowCatches: Int get() = catches.take(firstGoodBand).sum()
        val goodRate: Double? get() = if (goodHours > 0) goodCatches / goodHours else null
        val slowRate: Double? get() = if (slowHours > 0) slowCatches / slowHours else null
    }

    /** Hours needed on each side of index 50 before a verdict is given. */
    const val minHoursPerSide = 3.0

    /** Fish needed in total before a verdict is given. */
    const val minCatches = 5

    /** How much faster one side must be to call it. Placeholder, as in Swift. */
    const val clearRatio = 1.25

    fun summary(records: List<TripRecord>): Summary {
        val hours = DoubleArray(bandFloors.size)
        val catches = IntArray(bandFloors.size)
        for (record in records) {
            if (record.hours.size != bandFloors.size || record.catches.size != bandFloors.size) continue
            for (band in bandFloors.indices) {
                hours[band] += record.hours[band]
                catches[band] += record.catches[band]
            }
        }
        val summary = Summary(hours.toList(), catches.toList(), records.size, Verdict.NOT_ENOUGH)
        val good = summary.goodRate
        val slow = summary.slowRate
        if (summary.goodHours < minHoursPerSide || summary.slowHours < minHoursPerSide ||
            summary.goodCatches + summary.slowCatches < minCatches || good == null || slow == null
        ) return summary
        val verdict = when {
            good >= slow * clearRatio -> Verdict.TRACKS
            slow >= good * clearRatio -> Verdict.INVERSE
            else -> Verdict.FLAT
        }
        return summary.copy(verdict = verdict)
    }

    /**
     * Cuts a trip into slices of `length` seconds. Null under the same conditions as `record`:
     * the forecast must cover the whole trip and every fish must lie inside it.
     */
    fun slices(
        points: List<ScorePoint>, weights: Weights, from: Double, to: Double,
        catchTimes: List<Double>, length: Double = 3600.0,
    ): List<FactorSlice>? {
        val sorted = points.sortedBy { it.time }
        val duration = to - from
        if (!(duration > 0) || !(length > 0) || sorted.size < 2) return null
        val first = sorted.first()
        val last = sorted.last()
        if (!(first.time <= from + 900) || !(last.time >= to - 900)) return null
        if (!catchTimes.all { it >= from - 60 && it <= to + 60 }) return null

        fun unweighted(c: Contributions): DoubleArray {
            fun z(value: Double, weight: Double): Double = if (weight > 0) value / weight else 0.0
            return doubleArrayOf(
                z(c.light, weights.light), z(c.thermal, weights.thermal), z(c.wind, weights.wind),
                z(c.pressure, weights.pressure), z(c.solunar, weights.solunar), z(c.tide, weights.tide),
            )
        }
        val scores = sorted.map { unweighted(it.contributions) }

        fun score(t: Double): DoubleArray {
            if (t <= first.time) return scores[0]
            if (t >= last.time) return scores[scores.size - 1]
            var lo = 0
            var hi = sorted.size - 1
            while (hi - lo > 1) {
                val mid = (lo + hi) / 2
                if (sorted[mid].time <= t) lo = mid else hi = mid
            }
            val span = sorted[hi].time - sorted[lo].time
            if (!(span > 0)) return scores[lo]
            val f = (t - sorted[lo].time) / span
            return DoubleArray(6) { scores[lo][it] + (scores[hi][it] - scores[lo][it]) * f }
        }

        val count = max(1, ceil(duration / length).toInt())
        val hoursOut = DoubleArray(count)
        val zOut = ArrayList<List<Double>>()
        val catchesOut = IntArray(count)
        for (k in 0 until count) {
            val start = k * length
            val end = min(duration, (k + 1) * length)
            val steps = max(1, ceil((end - start) / 300).toInt())
            val dt = (end - start) / steps
            val sum = DoubleArray(6)
            for (s in 0 until steps) {
                val z = score(from + start + (s + 0.5) * dt)
                for (i in sum.indices) sum[i] += z[i]
            }
            hoursOut[k] = (end - start) / 3600
            zOut.add(sum.map { it / steps })
        }
        for (time in catchTimes) {
            val offset = min(max(0.0, time - from), duration)
            catchesOut[min(count - 1, (offset / length).toInt())] += 1
        }
        return (0 until count).map { FactorSlice(hoursOut[it], catchesOut[it], zOut[it]) }
    }
}
