package com.dautovri.bitecurve.ui

import android.content.Context
import android.icu.text.MeasureFormat
import android.icu.text.NumberFormat
import android.icu.util.LocaleData
import android.icu.util.Measure
import android.icu.util.MeasureUnit
import android.icu.util.ULocale
import android.text.format.DateFormat
import android.text.format.DateUtils
import com.dautovri.bitecurve.R
import com.dautovri.bitecurve.core.Species
import com.dautovri.bitecurve.core.WaterType
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

// Numbers, units and dates in the phone's own conventions (°F, mph and inHg in the US),
// the counterpart of the Foundation formatters the iOS app uses.

private fun locale(): Locale = Locale.getDefault()

private fun pattern(skeleton: String): DateTimeFormatter =
    DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale(), skeleton), locale())

private fun at(time: Double, zone: ZoneId) = Instant.ofEpochMilli((time * 1000).toLong()).atZone(zone)

/** The time of day in a given zone, in the phone's 12- or 24-hour style. */
fun clock(context: Context, time: Double, zone: ZoneId): String =
    pattern(if (DateFormat.is24HourFormat(context)) "Hm" else "hm").format(at(time, zone))

/** The hour only, for chart axes. */
fun hourLabel(context: Context, time: Double, zone: ZoneId): String =
    pattern(if (DateFormat.is24HourFormat(context)) "H" else "ha").format(at(time, zone))

fun weekdayShort(time: Double, zone: ZoneId): String = pattern("EEE").format(at(time, zone)).uppercase(locale())
fun dayOfMonth(time: Double, zone: ZoneId): String = pattern("d").format(at(time, zone))
fun fullDay(time: Double, zone: ZoneId): String = pattern("EEEEMMMd").format(at(time, zone))

fun dateAndTime(context: Context, time: Double, zone: ZoneId): String =
    pattern(if (DateFormat.is24HourFormat(context)) "yMMMdHm" else "yMMMdhm").format(at(time, zone))

/** "2 hours ago", "yesterday". */
fun relative(time: Double): String =
    DateUtils.getRelativeTimeSpanString((time * 1000).toLong(), System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()

fun number(value: Double, minFraction: Int, maxFraction: Int = minFraction): String =
    NumberFormat.getInstance(locale()).apply {
        minimumFractionDigits = minFraction
        maximumFractionDigits = maxFraction
        isGroupingUsed = false
    }.format(value)

fun percent(fraction: Double): String = NumberFormat.getPercentInstance(locale()).format(fraction)

private enum class Units { METRIC, UK, US }

private fun units(): Units = when (LocaleData.getMeasurementSystem(ULocale.forLocale(locale()))) {
    LocaleData.MeasurementSystem.US -> Units.US
    LocaleData.MeasurementSystem.UK -> Units.UK
    else -> Units.METRIC
}

private fun measure(value: Double, unit: MeasureUnit, fraction: Int): String {
    val numbers = NumberFormat.getInstance(locale()).apply {
        minimumFractionDigits = fraction
        maximumFractionDigits = fraction
        isGroupingUsed = false
    }
    return MeasureFormat.getInstance(locale(), MeasureFormat.FormatWidth.SHORT, numbers).format(Measure(value, unit))
}

/** True where the weather is given in °F. */
fun usesFahrenheit(): Boolean = units() == Units.US

fun temperatureSymbol(): String = if (usesFahrenheit()) "°F" else "°C"

fun toDisplayTemperature(celsius: Double): Double = if (usesFahrenheit()) celsius * 9 / 5 + 32 else celsius
fun fromDisplayTemperature(value: Double): Double = if (usesFahrenheit()) (value - 32) * 5 / 9 else value

fun temperature(celsius: Double): String {
    // -0.3 would print as "-0"; the + 0.0 turns a negative zero into a plain one.
    val value = toDisplayTemperature(celsius).roundToInt().toDouble() + 0.0
    return measure(value, if (usesFahrenheit()) MeasureUnit.FAHRENHEIT else MeasureUnit.CELSIUS, 0)
}

fun windSpeed(kmh: Double): String =
    if (units() == Units.METRIC) measure(kmh, MeasureUnit.KILOMETER_PER_HOUR, 0) else measure(kmh / 1.609344, MeasureUnit.MILE_PER_HOUR, 0)

/** Inches of mercury move in hundredths; hectopascals in whole numbers, without grouping. */
fun pressure(hPa: Double): String =
    if (units() == Units.US) measure(hPa * 0.0295299830714, MeasureUnit.INCH_HG, 2) else measure(hPa, MeasureUnit.HECTOPASCAL, 0)

fun durationHours(hours: Double): String = measure(hours, MeasureUnit.HOUR, 1)

fun Species.label(context: Context): String = context.getString(
    when (this) {
        Species.LARGEMOUTH_BASS -> R.string.largemouth_bass
        Species.WALLEYE -> R.string.walleye
        Species.NORTHERN_PIKE -> R.string.northern_pike
        Species.RAINBOW_TROUT -> R.string.rainbow_trout
        Species.CRUCIAN_CARP -> R.string.crucian_carp
        Species.COMMON_CARP -> R.string.common_carp
        Species.EUROPEAN_PERCH -> R.string.perch
        Species.COMMON_BREAM -> R.string.bream
        Species.GENERAL -> R.string.any_fish
        Species.EUROPEAN_SEA_BASS -> R.string.sea_bass
        Species.ATLANTIC_COD -> R.string.cod
        Species.ATLANTIC_MACKEREL -> R.string.mackerel
        Species.SEA_TROUT -> R.string.sea_trout
        Species.FLOUNDER -> R.string.flounder
        Species.STRIPED_BASS -> R.string.striped_bass
        Species.RED_DRUM -> R.string.red_drum
    },
)

/** Side-view illustration (the iOS asset of the same fish); none for "any fish". */
fun Species.image(): Int? = when (this) {
    Species.LARGEMOUTH_BASS -> R.drawable.fish_largemouth_bass
    Species.WALLEYE -> R.drawable.fish_walleye
    Species.NORTHERN_PIKE -> R.drawable.fish_northern_pike
    Species.RAINBOW_TROUT -> R.drawable.fish_rainbow_trout
    Species.CRUCIAN_CARP -> R.drawable.fish_crucian_carp
    Species.COMMON_CARP -> R.drawable.fish_common_carp
    Species.EUROPEAN_PERCH -> R.drawable.fish_european_perch
    Species.COMMON_BREAM -> R.drawable.fish_common_bream
    Species.GENERAL -> null
    Species.EUROPEAN_SEA_BASS -> R.drawable.fish_european_sea_bass
    Species.ATLANTIC_COD -> R.drawable.fish_atlantic_cod
    Species.ATLANTIC_MACKEREL -> R.drawable.fish_atlantic_mackerel
    Species.SEA_TROUT -> R.drawable.fish_sea_trout
    Species.FLOUNDER -> R.drawable.fish_flounder
    Species.STRIPED_BASS -> R.drawable.fish_striped_bass
    Species.RED_DRUM -> R.drawable.fish_red_drum
}

fun WaterType.label(context: Context): String = context.getString(
    when (this) {
        WaterType.WARM_FRESHWATER -> R.string.warm_freshwater
        WaterType.COLD_FRESHWATER -> R.string.cold_freshwater
        WaterType.INSHORE_SALT -> R.string.inshore_saltwater
        WaterType.OFFSHORE -> R.string.offshore
    },
)

/** Wording for a bite index. 50 is neutral. */
fun biteLabel(context: Context, index: Double): String = context.getString(
    when {
        index >= 65 -> R.string.strong_bite
        index >= 50 -> R.string.above_average
        index >= 35 -> R.string.below_average
        else -> R.string.slow
    },
)
