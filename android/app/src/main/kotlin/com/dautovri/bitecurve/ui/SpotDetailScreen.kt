package com.dautovri.bitecurve.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.NightsStay
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.Waves
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material.icons.filled.Air
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.dautovri.bitecurve.R
import com.dautovri.bitecurve.billing.Entitlements
import com.dautovri.bitecurve.core.BiteWindow
import com.dautovri.bitecurve.core.CatchModel
import com.dautovri.bitecurve.core.Forecaster
import com.dautovri.bitecurve.core.ScorePoint
import com.dautovri.bitecurve.core.Species
import com.dautovri.bitecurve.core.TideStation
import com.dautovri.bitecurve.core.WaterType
import com.dautovri.bitecurve.data.Forecast
import com.dautovri.bitecurve.data.Spot
import com.dautovri.bitecurve.data.WaterReading
import com.dautovri.bitecurve.data.nowSeconds
import com.dautovri.bitecurve.data.startOfDay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId

private class DaySummary(
    val date: Double,
    val window: BiteWindow?,
    val points: List<ScorePoint>,
    /** A day past the free horizon: the date is real, the forecast is not shown. */
    val isLocked: Boolean = false,
) {
    /** No weather covered any part of the day: the score is sun, moon and tide only. */
    val weatherless: Boolean get() = points.none { it.hasWeather }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SpotDetailScreen(spotId: String, initialDay: Double?, onBack: () -> Unit, onPaywall: () -> Unit) {
    val app = app()
    val context = LocalContext.current
    val colors = Theme.colors
    val data by app.store.data.collectAsStateWithLifecycle()
    val isPro by app.entitlements.isPro.collectAsStateWithLifecycle()
    val lastPrefetch by app.forecasts.lastPrefetch.collectAsStateWithLifecycle()
    val spot = data.spots.firstOrNull { it.id == spotId }
    if (spot == null) {
        LaunchedEffect(Unit) { onBack() }
        return
    }
    val service = app.forecasts
    val zone = spot.zone

    var forecast by remember { mutableStateOf<Forecast?>(null) }
    var tide by remember { mutableStateOf<TideStation?>(null) }
    /** The day the screen explains; null means today. */
    var selectedDay by remember { mutableStateOf(initialDay) }
    /** Where the water temperature in the score comes from; set again when an estimate arrives. */
    var waterReading by remember { mutableStateOf(spot.waterReading(service)) }

    // Also when forecasts are downloaded again while this screen is open.
    LaunchedEffect(lastPrefetch) {
        // Saved forecast first, so the screen fills at once with weak or no signal.
        if (forecast == null) forecast = service.saved(spot.latitude, spot.longitude)
        forecast = service.forecast(spot.latitude, spot.longitude)
        // In case this screen opened before the card on the Forecast tab had asked.
        com.dautovri.bitecurve.data.SpotTimeZone.resolveIfNeeded(context, app.store, spot)
    }
    LaunchedEffect(spot.waterRaw, spot.waterTempC) {
        waterReading = spot.waterReading(service)
        service.waterEstimate(spot.latitude, spot.longitude, spot.isSalt)
        waterReading = spot.waterReading(service)
        tide = if (spot.isSalt) service.tideStation(spot.latitude, spot.longitude) else null
    }

    // Free: today and tomorrow, then locked dates. Pro: the full 10-day horizon.
    val days by produceState(emptyList<DaySummary>(), forecast, tide, isPro, spot.timeZoneId, spot.waterRaw, spot.speciesRaw, spot.bankBearingDeg, waterReading) {
        val f = forecast ?: return@produceState
        value = withContext(Dispatchers.Default) {
            val now = nowSeconds()
            val today = startOfDay(now, zone)
            val count = if (isPro) Entitlements.horizonDays else Entitlements.freeDays
            val end = startOfDay(now, zone, count.toLong())
            val spotContext = spot.context(service).copy(tide = if (spot.isSalt) tide else null)
            val points = Forecaster.curve(spotContext, f.hours, today, end, fillMissingWeather = true)
            // Today's window starts no earlier than now; the curve still covers the whole day.
            val cutoff = now - 900
            val out = points.groupBy { startOfDay(it.time, zone) }.filter { it.key < end }
                .map { (day, list) -> DaySummary(day, Forecaster.bestWindow(list, notBefore = if (day == today) cutoff else null), list) }
                .sortedBy { it.date }.toMutableList()
            if (!isPro) {
                for (offset in Entitlements.freeDays until Entitlements.horizonDays) {
                    out.add(DaySummary(startOfDay(now, zone, offset.toLong()), null, emptyList(), isLocked = true))
                }
            }
            out
        }
    }
    val day = days.firstOrNull { !it.isLocked && it.date == selectedDay } ?: days.firstOrNull()
    val multiplier = data.catchMultiplier(spot)
    val tripCount = data.fittedTrips(spot).size

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = { Text(spot.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.close)) } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.background),
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
            Column(Modifier.widthIn(max = Theme.readableWidth).padding(top = 8.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(Theme.gap)) {
                Box(Modifier.padding(horizontal = 20.dp)) { StatusBanner(forecast) }

                if (days.isNotEmpty()) {
                    DayStrip(days.map { StripDay(it.date, it.window?.meanIndex, it.isLocked) }, day?.date, zone) { tapped ->
                        if (tapped.isLocked) onPaywall() else selectedDay = tapped.date
                    }
                }

                Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(Theme.gap)) {
                    if (day != null) {
                        val isToday = day.date == startOfDay(nowSeconds(), zone)
                        // The moment a day's readings describe: the middle of its best window, now
                        // for today without one, otherwise midday.
                        val moment = day.window?.let { it.start + (it.end - it.start) / 2 } ?: if (isToday) nowSeconds() else day.date + 12 * 3600
                        val conditions = remember(day.date, moment, forecast) {
                            Conditions(moment, forecast?.hours ?: emptyList(), spot.latitude, spot.longitude, zone)
                        }

                        // The day's index and best window, the curve, and the expected catch.
                        BiteCard {
                            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                                // Away from the phone's own zone, say whose clock the times are on.
                                val suffix = if (zone.rules.getOffset(Instant.ofEpochSecond(day.date.toLong())) ==
                                    ZoneId.systemDefault().rules.getOffset(Instant.ofEpochSecond(day.date.toLong()))) "" else " · ${zone.getDisplayName(java.time.format.TextStyle.SHORT, java.util.Locale.getDefault())}"
                                Text(fullDay(day.date, zone) + suffix, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = colors.secondaryText)
                                val window = day.window
                                if (window != null) {
                                    Row(Modifier.semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                                        IndexGauge(window.meanIndex, 76.dp)
                                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                            Text(stringResource(R.string.best_window), style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText)
                                            Text(
                                                "${clock(context, window.start, zone)} – ${clock(context, window.end, zone)}",
                                                style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = colors.primaryText, maxLines = 2,
                                            )
                                            Text(biteLabel(context, window.meanIndex), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, color = colors.bite(window.meanIndex))
                                        }
                                    }
                                } else {
                                    Text(stringResource(if (isToday) R.string.not_enough_forecast_left_for_today else R.string.no_forecast), color = colors.secondaryText)
                                }

                                // The banner at the top already says so when there is no weather at all.
                                if (day.weatherless && forecast?.hours?.isEmpty() == false) {
                                    Note(Icons.Filled.NightsStay, stringResource(R.string.no_weather_data_sun_moon_and_tide_only))
                                }

                                val dayEnd = startOfDay(day.date + 3600, zone, 1)
                                if (isPro) {
                                    BiteCurveChart(day.points, day.window, conditions.sunrise, conditions.sunset, zone, Modifier.height(190.dp))
                                    val station = tide
                                    if (spot.isSalt && station != null) {
                                        val samples = remember(station, day.date) { station.curve(day.date, dayEnd) }
                                        TideChart(samples, zone, Modifier.height(84.dp))
                                    }
                                } else {
                                    // The day's real frame (daylight, best window) with the curve withheld, never a made-up one.
                                    Box(Modifier.clip(RoundedCornerShape(14.dp)).clickable(onClick = onPaywall), contentAlignment = Alignment.Center) {
                                        BiteCurveChart(emptyList(), day.window, conditions.sunrise, conditions.sunset, zone, Modifier.height(170.dp), domain = day.date..dayEnd)
                                        Row(
                                            Modifier.padding(horizontal = 24.dp)
                                                .background(colors.card.copy(alpha = 0.92f), RoundedCornerShape(14.dp))
                                                .border(1.dp, colors.stroke, RoundedCornerShape(14.dp))
                                                .padding(horizontal = 12.dp, vertical = 10.dp),
                                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                                        ) {
                                            Icon(Icons.Filled.Lock, null, Modifier.size(16.dp), tint = colors.primaryText)
                                            Text(
                                                stringResource(R.string.unlock_hourly_curve_tide_curve_expected_catch_an),
                                                style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, color = colors.primaryText,
                                            )
                                        }
                                    }
                                }

                                if (window != null) {
                                    Hairline()
                                    // Pro: the number, with the personal multiplier it includes. Free: the label and a lock.
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        FishIcon(Modifier.size(18.dp))
                                        Text(stringResource(R.string.expected_fish_in_window), Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, color = colors.primaryText)
                                        if (isPro) {
                                            if (tripCount > 0) {
                                                val rate = stringResource(R.string.your_catch_rate_here)
                                                Text(
                                                    "×${number(multiplier.mean, 2)}", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, color = colors.secondaryText,
                                                    modifier = Modifier.background(colors.well, CircleShape).padding(horizontal = 7.dp, vertical = 3.dp)
                                                        .clearAndSetSemantics { contentDescription = "$rate ${number(multiplier.mean, 2)}" },
                                                )
                                            }
                                            val fish = CatchModel.expectedCatch(day.points, window.start, window.end) * multiplier.mean
                                            Text(number(fish, 1), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = colors.primaryText)
                                        } else {
                                            val plans = stringResource(R.string.see_pro_plans)
                                            Box(
                                                Modifier.size(34.dp).clip(CircleShape).background(colors.well).clickable(onClick = onPaywall)
                                                    .clearAndSetSemantics { contentDescription = plans },
                                                contentAlignment = Alignment.Center,
                                            ) { Icon(Icons.Filled.Lock, null, Modifier.size(15.dp), tint = colors.primaryText) }
                                        }
                                    }
                                }
                            }
                        }

                        // The weather, sun and moon in the middle of the best window (now, without one).
                        BiteCard {
                            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                if (conditions.hour != null) {
                                    // The readings are for the middle of the window, not for now.
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                                        Icon(Icons.Filled.Schedule, null, Modifier.size(14.dp), tint = colors.secondaryText)
                                        Text(clock(context, moment, zone), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, color = colors.secondaryText)
                                    }
                                }
                                ConditionsGrid(conditions)
                            }
                        }

                        val window = day.window
                        if (isPro && window != null) {
                            // Mean weighted contribution of each active factor over the window, with the reading behind it.
                            val inside = day.points.filter { it.time >= window.start && it.time <= window.end }
                            if (inside.isNotEmpty()) {
                                fun mean(pick: (ScorePoint) -> Double) = inside.sumOf(pick) / inside.size
                                val factors = buildList {
                                    add(Factor(stringResource(R.string.light), mean { it.contributions.light }, Icons.Filled.WbSunny, conditions.cloud))
                                    waterReading?.let { water ->
                                        // "≈" marks an estimate.
                                        val degrees = temperature(water.tempC)
                                        add(Factor(stringResource(R.string.water_temperature), mean { it.contributions.thermal }, Icons.Filled.Thermostat, if (water.isMeasured) degrees else "≈ $degrees"))
                                    }
                                    if (!day.weatherless) {
                                        add(Factor(stringResource(R.string.wind), mean { it.contributions.wind }, Icons.Filled.Air, conditions.wind))
                                        add(Factor(stringResource(R.string.pressure_trend), mean { it.contributions.pressure }, Icons.Filled.Speed, conditions.pressure, conditions.pressureTrend))
                                    }
                                    add(Factor(stringResource(R.string.moon), mean { it.contributions.solunar }, moonPhase = conditions.moonPhaseAngle))
                                    // Without a station the tide term still counts: the moon phase stands in for spring and neap tides.
                                    if (spot.isSalt) add(Factor(stringResource(R.string.tide), mean { it.contributions.tide }, Icons.Filled.Waves))
                                }
                                BiteCard { FactorBreakdown(factors) }
                            }
                        }

                        // Everyone: tide times at saltwater spots, and where they come from.
                        if (spot.isSalt) {
                            BiteCard {
                                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                                    val station = tide
                                    if (station != null) {
                                        val extremes = remember(station, day.date) { station.extremes(day.date, startOfDay(day.date + 3600, zone, 1)) }
                                        if (extremes.isNotEmpty()) {
                                            LabeledRow(stringResource(R.string.tides)) {
                                                Text(
                                                    extremes.joinToString("  ") { "${if (it.isHigh) "▲" else "▼"} ${clock(context, it.time, zone)}" },
                                                    style = MaterialTheme.typography.bodySmall, color = colors.primaryText, textAlign = TextAlign.End,
                                                )
                                            }
                                        }
                                        LabeledRow(stringResource(R.string.tide_station)) {
                                            Text(station.name, style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText, textAlign = TextAlign.End)
                                        }
                                    } else {
                                        Text(stringResource(R.string.no_tide_station_found_near_this_spot_the_score_e), style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText)
                                    }
                                    Text(stringResource(R.string.tide_predictions_from_noaa_harmonic_constants_no), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                                }
                            }
                        }
                    }

                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        CardHeader(stringResource(R.string.your_record))
                        BiteCard {
                            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                    RecordTile(Icons.Filled.Flag, "$tripCount", stringResource(R.string.trips_logged_here), Modifier.weight(1f))
                                    if (tripCount > 0) {
                                        RecordTile(FishGlyph, "×${number(multiplier.mean, 2)}", stringResource(R.string.your_catch_rate_here), Modifier.weight(1f))
                                    }
                                }
                                Text(
                                    stringResource(if (tripCount == 0) R.string.log_trips_here_blank_ones_included_and_the_expec else R.string.relative_to_the_starting_estimate_it_moves_slowl),
                                    style = MaterialTheme.typography.bodySmall, color = colors.secondaryText,
                                )
                            }
                        }
                    }

                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        CardHeader(stringResource(R.string.spot))
                        SpotSettingsCard(spot, waterReading)
                    }

                    Column(Modifier.padding(horizontal = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(
                            stringResource(R.string.weather_data_apple_weather_legal_attribution),
                            style = MaterialTheme.typography.bodySmall, color = colors.accent, textDecoration = TextDecoration.Underline,
                            modifier = Modifier.clickable {
                                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://weatherkit.apple.com/legal-attribution.html")))
                            },
                        )
                        Text(stringResource(R.string.bite_windows_are_estimates_from_weather_sun_moon), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                    }
                }
            }
        }
    }
}

@Composable
private fun StatusBanner(forecast: Forecast?) {
    val colors = Theme.colors
    if (forecast == null) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
            Text(stringResource(R.string.loading_forecast), color = colors.secondaryText)
        }
    } else if (forecast.source == Forecast.Source.CACHED) {
        val saved = forecast.fetchedAt
        val text = if (saved != null && forecast.hours.isNotEmpty()) stringResource(R.string.offline_forecast_saved_x, relative(saved))
        else stringResource(R.string.no_weather_data_sun_moon_and_tide_only)
        Note(Icons.Filled.WifiOff, text)
    }
}

@Composable
private fun Note(icon: ImageVector, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(icon, null, Modifier.size(15.dp), tint = Theme.colors.secondaryText)
        Text(text, style = MaterialTheme.typography.bodySmall, color = Theme.colors.secondaryText)
    }
}

@Composable
private fun LabeledRow(label: String, content: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = Theme.colors.primaryText)
        Spacer(Modifier.weight(1f))
        content()
    }
}

/** A number with its label on a recessed tile. */
@Composable
private fun RecordTile(icon: ImageVector, value: String, label: String, modifier: Modifier = Modifier) {
    Well(modifier.semantics(mergeDescendants = true) {}) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Icon(icon, null, Modifier.size(20.dp), tint = Theme.colors.accent)
            Text(value, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = Theme.colors.primaryText)
            Text(label, style = MaterialTheme.typography.labelMedium, color = Theme.colors.secondaryText)
        }
    }
}

/** A value that opens a menu of choices, like the pickers of the iOS spot card. */
@Composable
fun <T> MenuPicker(label: String, value: String, options: List<Pair<T, String>>, onPick: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.clip(RoundedCornerShape(10.dp)).clickable { open = true }.padding(start = 8.dp, top = 6.dp, bottom = 6.dp)
                .semantics { contentDescription = label },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(value, style = MaterialTheme.typography.bodyMedium, color = Theme.colors.accent, textAlign = TextAlign.End)
            Icon(Icons.Filled.ArrowDropDown, null, tint = Theme.colors.accent)
        }
        DropdownMenu(open, { open = false }) {
            for ((option, name) in options) {
                DropdownMenuItem(text = { Text(name) }, onClick = { open = false; onPick(option) })
            }
        }
    }
}

/** Species, water, the bank fished from and the angler's own water temperature. */
@Composable
private fun SpotSettingsCard(spot: Spot, waterReading: WaterReading?) {
    val app = app()
    val context = LocalContext.current
    val colors = Theme.colors
    // The side of the water the angler stands on, as the bearing from open water to that bank.
    val banks = listOf(
        0.0 to R.string.north_bank, 45.0 to R.string.northeast_bank, 90.0 to R.string.east_bank, 135.0 to R.string.southeast_bank,
        180.0 to R.string.south_bank, 225.0 to R.string.southwest_bank, 270.0 to R.string.west_bank, 315.0 to R.string.northwest_bank,
    )
    BiteCard {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            LabeledRow(stringResource(R.string.target_species)) {
                MenuPicker(stringResource(R.string.target_species), spot.species.label(context), Species.choices(spot.water).map { it to it.label(context) }) { picked ->
                    app.store.updateSpot(spot.id) { it.copy(speciesRaw = picked.raw) }
                }
            }
            Hairline()
            LabeledRow(stringResource(R.string.water)) {
                MenuPicker(stringResource(R.string.water), spot.water.label(context), WaterType.entries.map { it to it.label(context) }) { picked ->
                    app.store.updateSpot(spot.id) { it.withWater(picked) }
                }
            }
            Hairline()
            // Wind blowing onto the bank you stand on scores higher than wind off it.
            LabeledRow(stringResource(R.string.bank_you_fish_from)) {
                val current = banks.firstOrNull { it.first == spot.bankBearingDeg }?.let { stringResource(it.second) } ?: stringResource(R.string.not_set)
                val options: List<Pair<Double?, String>> = listOf<Pair<Double?, String>>(null to stringResource(R.string.not_set)) + banks.map { it.first to stringResource(it.second) }
                MenuPicker(stringResource(R.string.bank_you_fish_from), current, options) { picked ->
                    app.store.updateSpot(spot.id) { it.copy(bankBearingDeg = picked) }
                }
            }
            Hairline()
            // The measured water temperature as the angler types it, in the unit the forecast
            // shows. Kept as text while typing ("68." must not lose its dot); every valid state
            // is stored in °C at once, and an empty field goes back to the estimate.
            var text by remember(spot.id) { mutableStateOf(spot.waterTempC?.let { number(toDisplayTemperature(it), 0, 1) } ?: "") }
            val prompt = waterReading?.takeIf { !it.isMeasured }?.let { "≈ " + number(toDisplayTemperature(it.tempC), 0) } ?: stringResource(R.string.optional)
            val fieldLabel = stringResource(R.string.water_temperature)
            Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(fieldLabel, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, color = colors.primaryText)
                Row(
                    Modifier.background(colors.well, RoundedCornerShape(10.dp)).padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    BasicTextField(
                        value = text,
                        onValueChange = { typed ->
                            text = typed.take(6)
                            // Comma and dot both count as the decimal mark.
                            val trimmed = text.trim().replace(',', '.')
                            if (trimmed.isEmpty()) {
                                app.store.updateSpot(spot.id) { it.copy(waterTempC = null) }
                            } else {
                                val celsius = trimmed.toDoubleOrNull()?.let { fromDisplayTemperature(it) }
                                // Liquid water an angler can fish in.
                                if (celsius != null && celsius >= -3 && celsius <= 40) app.store.updateSpot(spot.id) { it.copy(waterTempC = celsius) }
                            }
                        },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        textStyle = TextStyle(color = colors.accent, fontSize = 16.sp, textAlign = TextAlign.End),
                        cursorBrush = SolidColor(colors.accent),
                        modifier = Modifier.width(72.dp).semantics { contentDescription = fieldLabel },
                        decorationBox = { inner ->
                            Box(contentAlignment = Alignment.CenterEnd) {
                                if (text.isEmpty()) Text(prompt, color = colors.secondaryText, fontSize = 16.sp, maxLines = 1)
                                inner()
                            }
                        },
                    )
                    Text(temperatureSymbol(), color = colors.secondaryText)
                }
            }
            // Says where the temperature in the score comes from.
            val note = when (waterReading?.source) {
                WaterReading.Source.SATELLITE -> R.string.estimated_from_noaa_satellite_sea_surface_data_t
                WaterReading.Source.MODELLED -> R.string.estimated_from_the_last_30_days_of_air_temperatu
                WaterReading.Source.MEASURED -> R.string.your_reading_clear_the_field_to_go_back_to_the_e
                null -> null
            }
            if (note != null) Text(stringResource(note), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
        }
    }
}
