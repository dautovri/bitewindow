package com.dautovri.bitecurve.data

import com.dautovri.bitecurve.core.BiteWindow
import com.dautovri.bitecurve.core.Forecaster
import com.dautovri.bitecurve.core.HourConditions
import com.dautovri.bitecurve.core.SpotContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId

/** One day at a spot: its best two-hour window, if the forecast still has one. */
data class DayOutlook(
    /** Midnight at the spot, seconds since 1970. */
    val date: Double,
    val window: BiteWindow?,
) {
    val index: Double? get() = window?.meanIndex
}

/** A spot's data in a form that can be scored off the main thread. */
class SpotSummaryInput(
    val id: String,
    val name: String,
    val context: SpotContext,
    val zone: ZoneId,
    val hours: List<HourConditions>,
)

/** Midnight of the day `time` falls on in `zone`, plus `days` whole days, seconds since 1970. */
fun startOfDay(time: Double, zone: ZoneId, days: Long = 0): Double =
    Instant.ofEpochMilli((time * 1000).toLong()).atZone(zone).toLocalDate().plusDays(days).atStartOfDay(zone).toEpochSecond().toDouble()

/** Port of App/BiteWindow/Services/DayOutlooks.swift. */
object DayOutlooks {
    /**
     * The next `days` days at a spot, today first, as the Forecast tab scores them: today's
     * window starts no earlier than now.
     */
    fun compute(context: SpotContext, hours: List<HourConditions>, zone: ZoneId, days: Int, now: Double = nowSeconds()): List<DayOutlook> {
        if (days <= 0) return emptyList()
        val today = startOfDay(now, zone)
        val end = startOfDay(now, zone, days.toLong())
        val points = Forecaster.curve(context, hours, today, end, fillMissingWeather = true)
        val cutoff = now - 900
        val byDay = points.filter { it.time < end }.groupBy { startOfDay(it.time, zone) }
        return (0 until days).map { offset ->
            val day = startOfDay(now, zone, offset.toLong())
            DayOutlook(day, Forecaster.bestWindow(byDay[day] ?: emptyList(), notBefore = if (day == today) cutoff else null))
        }
    }

    /** Every saved spot with its saved forecast (no network for weather), ready to score. */
    suspend fun inputs(spots: List<Spot>, service: ForecastService): List<SpotSummaryInput> = spots.map { spot ->
        val hours = service.saved(spot.latitude, spot.longitude)?.hours ?: emptyList()
        var context = spot.context(service)
        if (spot.isSalt) context = context.copy(tide = service.tideStation(spot.latitude, spot.longitude))
        SpotSummaryInput(spot.id, spot.name, context, spot.zone, hours)
    }

    /** `days` days for each spot, computed off the main thread. */
    suspend fun compute(inputs: List<SpotSummaryInput>, days: Int, now: Double = nowSeconds()): Map<String, List<DayOutlook>> =
        withContext(Dispatchers.Default) {
            inputs.associate { it.id to compute(it.context, it.hours, it.zone, days, now) }
        }
}
