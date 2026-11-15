package com.dautovri.bitecurve.ui

import android.content.Context
import com.dautovri.bitecurve.core.Astro
import com.dautovri.bitecurve.core.HourConditions
import com.dautovri.bitecurve.data.startOfDay
import java.time.ZoneId
import kotlin.math.abs

/**
 * The weather, sun and moon at one moment at a spot (the iOS `Conditions`). Every value comes
 * from the forecast or from astronomy; nothing here is estimated.
 */
class Conditions(time: Double, hours: List<HourConditions>, latitude: Double, longitude: Double, val zone: ZoneId) {
    val hour: HourConditions?
    /** Pressure change over the three hours before `time`, hPa; null without enough forecast. */
    val pressureDelta: Double?
    val sunrise: Double?
    val sunset: Double?
    val moonPhaseAngle: Double = Astro.moonPhaseAngle(time)

    init {
        val sorted = hours.sortedBy { it.time }
        // The forecast hour that contains `time`, within an hour and a half at most.
        val nearest = sorted.minByOrNull { abs(it.time - time) }
        hour = nearest?.takeIf { abs(it.time - time) <= 5400 }
        val earlier = hour?.let { h -> sorted.lastOrNull { it.time <= h.time - 3 * 3600 + 60 } }
        pressureDelta = if (hour != null && earlier != null && hour.time - earlier.time <= 4 * 3600) hour.pressureHPa - earlier.pressureHPa else null
        val dayStart = startOfDay(time, zone)
        val dayEnd = startOfDay(time, zone, 1)
        val sun = Astro.events(Astro.Body.SUN, dayStart, dayEnd, latitude, longitude)
        sunrise = sun.rises.firstOrNull()
        sunset = sun.sets.lastOrNull()
    }

    val wind: String? get() = hour?.let { windSpeed(it.windSpeedKmh) }

    /** Where the wind blows towards, as a rotation for an arrow that points up at 0. */
    val windArrowDegrees: Double? get() = hour?.windFromDeg?.let { it + 180 }

    val pressure: String? get() = hour?.let { pressure(it.pressureHPa) }

    /** Rising (1), falling (-1) or steady (0) over three hours; under 0.5 hPa counts as steady. */
    val pressureTrend: Int? get() = pressureDelta?.let { if (it > 0.5) 1 else if (it < -0.5) -1 else 0 }

    val temperature: String? get() = hour?.let { temperature(it.airTempC) }

    val cloud: String? get() = hour?.let { percent(it.cloudCover) }

    fun clock(context: Context, time: Double?): String? = time?.let { clock(context, it, zone) }
}
