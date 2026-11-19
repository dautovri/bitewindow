package com.dautovri.bitecurve.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.dautovri.bitecurve.BiteCurveApp
import com.dautovri.bitecurve.R
import com.dautovri.bitecurve.core.CatchModel
import com.dautovri.bitecurve.core.Scorecard
import com.dautovri.bitecurve.core.Weights
import com.dautovri.bitecurve.data.Spot
import com.dautovri.bitecurve.data.StoreData
import com.dautovri.bitecurve.data.Trip
import com.dautovri.bitecurve.data.TripFitRecord
import com.dautovri.bitecurve.data.nowSeconds
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.ZoneId
import kotlin.math.roundToInt

/**
 * Ends the trip and stores what the model expected for it, so the trip can train the personal
 * catch rate later. Runs in the app's own scope: leaving the screen must not lose it.
 */
fun endTrip(app: BiteCurveApp, tripId: String) {
    val data = app.store.data.value
    val trip = data.trips.firstOrNull { it.id == tripId } ?: return
    val spot = data.spots.firstOrNull { it.id == trip.spotId }
    val start = trip.startedAt
    val finish = nowSeconds()
    // Neutral estimate first, so the trip counts even if the app quits now.
    app.store.updateTrip(tripId) { it.copy(expectedCatch = CatchModel.expectedCatch(emptyList(), start, finish), endedAt = finish) }
    if (finish - start > CatchModel.maxTripHours * 3600) return
    val service = app.forecasts
    val base = spot?.context(service)
    val water = spot?.waterReading(service)
    app.scope.launch {
        var context = base
        if (base != null && base.water.isSalt) context = base.copy(tide = service.tideStation(base.latitude, base.longitude))
        val points = service.tripPoints(context, start, finish)
        app.store.updateTrip(tripId) { it.copy(expectedCatch = CatchModel.expectedCatch(points, start, finish)) }
        val times = trip.completeCatchTimes ?: return@launch
        val record = Scorecard.record(points, start, finish, times) ?: return@launch
        // Kept on the phone: the only form in which this trip could ever tune the weights.
        val fit = context?.let { c ->
            Scorecard.slices(points, Weights.prior(c.water, c.species), start, finish, times)?.let { slices ->
                TripFitRecord(water = c.water.raw, species = c.species.raw, waterTempC = water?.tempC, waterSource = water?.source?.wireName,
                    hasBank = c.bankBearingDeg != null, hasTideStation = c.tide != null, slices = slices)
            }
        }
        app.store.updateTrip(tripId) { it.copy(bandHours = record.hours, bandCatches = record.catches, forecastIndex = record.meanIndex, fitRecord = fit) }
    }
}

/**
 * Trip log. Ending a trip with zero fish is a single tap, because blank trips
 * are what make the catch-rate model honest.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LogScreen(onPaywall: (PaywallContext) -> Unit) {
    val app = app()
    val colors = Theme.colors
    val data by app.store.data.collectAsStateWithLifecycle()
    val isPro by app.entitlements.isPro.collectAsStateWithLifecycle()
    var proCardDismissed by remember { mutableStateOf(app.prefs.logProCardDismissed) }
    val trips = data.trips.sortedByDescending { it.startedAt }
    val active = trips.firstOrNull { it.isActive }
    val finished = trips.filter { !it.isActive }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.log), fontWeight = FontWeight.Bold) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.background),
            )
        },
    ) { padding ->
        LazyColumn(
            Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(Theme.gap), horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            item {
                Column(Modifier.widthIn(max = Theme.readableWidth), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (active != null) {
                        CardHeader(stringResource(R.string.current_trip))
                        ActiveTripCard(active, data)
                    } else {
                        StartTripMenu(data.spots) { spot -> app.store.addTrip(Trip(spotId = spot?.id)) }
                    }
                }
            }
            if (finished.isNotEmpty()) {
                item {
                    Column(Modifier.widthIn(max = Theme.readableWidth), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        CardHeader(stringResource(R.string.totals))
                        TotalsRow(finished)
                    }
                }
                item {
                    Column(Modifier.widthIn(max = Theme.readableWidth), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        CardHeader(stringResource(R.string.was_the_forecast_right))
                        ForecastCheckCard(Scorecard.summary(finished.mapNotNull { it.scoreRecord }))
                    }
                }
            }
            // A few trips in, the log is what Pro tunes the expected catch to. Says so once; never a pop-up.
            if (!isPro && !proCardDismissed && finished.size >= 3) {
                item {
                    BiteCard(Modifier.widthIn(max = Theme.readableWidth)) {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(stringResource(R.string.log_pro_card, finished.size), style = MaterialTheme.typography.bodyMedium, color = colors.primaryText)
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Button({ onPaywall(PaywallContext.FACTORS) }) { Text(stringResource(R.string.see_pro_plans), fontWeight = FontWeight.SemiBold) }
                                TextButton({
                                    app.prefs.logProCardDismissed = true
                                    proCardDismissed = true
                                }) { Text(stringResource(R.string.not_now)) }
                            }
                        }
                    }
                }
            }
            item { Box(Modifier.widthIn(max = Theme.readableWidth).fillMaxWidth()) { CardHeader(stringResource(R.string.history)) } }
            if (finished.isEmpty()) {
                item {
                    BiteCard(Modifier.widthIn(max = Theme.readableWidth)) {
                        Text(stringResource(R.string.no_finished_trips_yet_log_every_trip_blank_ones), style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText)
                    }
                }
            } else {
                items(finished, key = { it.id }) { trip ->
                    TripHistoryCard(trip, data.spots.firstOrNull { it.id == trip.spotId }) { app.store.deleteTrip(trip.id) }
                }
            }
        }
    }
}

@Composable
private fun StartTripMenu(spots: List<Spot>, onStart: (Spot?) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Button({ open = true }, Modifier.fillMaxWidth().heightIn(min = 56.dp), shape = RoundedCornerShape(Theme.cardRadius)) {
            Icon(Icons.Filled.PlayArrow, null)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.start_trip), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        }
        DropdownMenu(open, { open = false }) {
            for (spot in spots) DropdownMenuItem(text = { Text(spot.name) }, onClick = { open = false; onStart(spot) })
            DropdownMenuItem(text = { Text(stringResource(R.string.no_spot)) }, onClick = { open = false; onStart(null) })
        }
    }
}

private fun timer(seconds: Long): String {
    val h = seconds / 3600
    val m = seconds % 3600 / 60
    val s = seconds % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

@Composable
private fun ActiveTripCard(trip: Trip, data: StoreData) {
    val app = app()
    val context = LocalContext.current
    val colors = Theme.colors
    val spot = data.spots.firstOrNull { it.id == trip.spotId }
    val zone = spot?.zone ?: ZoneId.systemDefault()
    var now by remember { mutableStateOf(nowSeconds()) }
    LaunchedEffect(trip.id) {
        while (true) { now = nowSeconds(); delay(1000) }
    }
    BiteCard {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(spot?.name ?: stringResource(R.string.no_spot), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = colors.primaryText)
                Text(timer((now - trip.startedAt).toLong().coerceAtLeast(0)), style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold, color = colors.accent)
                // On the spot's clock, like the fish times below it.
                Text(stringResource(R.string.started_x, clock(context, trip.startedAt, zone)), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
            }
            Well(Modifier.fillMaxWidth()) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    // Each tap on plus stamps the fish with the time, for the forecast check.
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        FishIcon(Modifier.size(22.dp))
                        Text(stringResource(R.string.fish_caught_x, trip.catchCount), Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, color = colors.primaryText)
                        FilledTonalIconButton({ app.store.updateTrip(trip.id) { it.withoutLastCatch() } }, enabled = trip.catchCount > 0) {
                            Icon(Icons.Filled.Remove, "−1")
                        }
                        FilledTonalIconButton({ if (trip.catchCount < 500) app.store.updateTrip(trip.id) { it.withCatch() } }) {
                            Icon(Icons.Filled.Add, "+1")
                        }
                    }
                    trip.completeCatchTimes?.takeIf { it.isNotEmpty() }?.let { CatchTimesLine(it, zone) }
                }
            }
            Button({ endTrip(app, trip.id) }, Modifier.fillMaxWidth().heightIn(min = 52.dp)) {
                Text(stringResource(if (trip.catchCount == 0) R.string.end_trip_no_fish else R.string.end_trip), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

/** The times the fish came, on the spot's clock. */
@Composable
private fun CatchTimesLine(times: List<Double>, zone: ZoneId) {
    val context = LocalContext.current
    val label = stringResource(R.string.fish_caught_at)
    val clocks = times.map { clock(context, it, zone) }
    Text(
        clocks.joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = Theme.colors.secondaryText, maxLines = 3,
        modifier = Modifier.clearAndSetSemantics { contentDescription = label; stateDescription = clocks.joinToString(", ") },
    )
}

/**
 * Was the forecast right? Fishing hours and fish from the log, filed under the bite index the
 * forecast gave for each moment.
 */
@Composable
private fun ForecastCheckCard(summary: Scorecard.Summary) {
    val context = LocalContext.current
    val colors = Theme.colors
    fun rate(value: Double?) = value?.let { number(it, 1) } ?: "–"
    fun hours(value: Double) = number(value, if (value < 10) 1 else 0)
    val good = rate(summary.goodRate)
    val slow = rate(summary.slowRate)
    val verdict = when (summary.verdict) {
        Scorecard.Verdict.NOT_ENOUGH -> stringResource(R.string.tap_plus_each_time_you_land_a_fish_after_three_h)
        Scorecard.Verdict.TRACKS -> stringResource(R.string.the_forecast_holds_for_you_x_fish_per_hour_when, good, slow)
        Scorecard.Verdict.FLAT -> stringResource(R.string.no_clear_difference_so_far_x_fish_per_hour_when, good, slow)
        Scorecard.Verdict.INVERSE -> stringResource(R.string.so_far_you_catch_more_in_slow_forecasts_x_fish_p, slow, good)
    }
    val (icon, tint) = when (summary.verdict) {
        Scorecard.Verdict.NOT_ENOUGH -> Icons.Filled.HourglassEmpty to colors.secondaryText
        Scorecard.Verdict.TRACKS -> Icons.Filled.Verified to colors.bite(70.0)
        Scorecard.Verdict.FLAT -> Icons.Filled.DragHandle to colors.secondaryText
        Scorecard.Verdict.INVERSE -> Icons.Filled.SwapVert to colors.bite(40.0)
    }
    val peak = Scorecard.bandFloors.indices.mapNotNull { summary.rate(it) }.maxOrNull() ?: 0.0
    BiteCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(icon, null, Modifier.size(24.dp), tint = tint)
                Text(verdict, style = MaterialTheme.typography.bodyMedium, color = colors.primaryText)
            }
            if (summary.trips > 0) {
                val hoursLabel = stringResource(R.string.hours)
                val fishLabel = stringResource(R.string.fish)
                val perHourLabel = stringResource(R.string.per_hour)
                val number = Modifier.width(52.dp)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.forecast).uppercase(), Modifier.weight(1f), style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold, color = colors.secondaryText, maxLines = 1)
                    for (title in listOf(hoursLabel, fishLabel, perHourLabel)) {
                        Text(title.uppercase(), number, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold, color = colors.secondaryText, maxLines = 2, textAlign = androidx.compose.ui.text.style.TextAlign.End)
                    }
                }
                for (band in Scorecard.bandFloors.indices.reversed()) {
                    val sample = Scorecard.bandFloors[band] + 1
                    val color = colors.bite(sample)
                    val label = biteLabel(context, sample)
                    val state = "$hoursLabel ${hours(summary.hours[band])}, $fishLabel ${summary.catches[band]}, $perHourLabel ${rate(summary.rate(band))}"
                    // Read as one row with its column names.
                    Row(Modifier.clearAndSetSemantics { contentDescription = label; stateDescription = state }, verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                Box(Modifier.size(8.dp).background(color, CircleShape))
                                Text(label, style = MaterialTheme.typography.bodyMedium, color = colors.primaryText, maxLines = 2)
                            }
                            // The bar is the catch rate, so a forecast that holds reads as a staircase.
                            val share = if (peak > 0) ((summary.rate(band) ?: 0.0) / peak).toFloat() else 0f
                            Canvas(Modifier.fillMaxWidth().padding(end = 12.dp).height(5.dp)) {
                                if (share > 0) drawRoundRect(color.copy(alpha = 0.85f), size = size.copy(width = maxOf(4.dp.toPx(), size.width * share)), cornerRadius = CornerRadius(size.height / 2))
                            }
                        }
                        Text(hours(summary.hours[band]), number, style = MaterialTheme.typography.bodyMedium, color = colors.primaryText, textAlign = androidx.compose.ui.text.style.TextAlign.End)
                        Text("${summary.catches[band]}", number, style = MaterialTheme.typography.bodyMedium, color = colors.primaryText, textAlign = androidx.compose.ui.text.style.TextAlign.End)
                        Text(rate(summary.rate(band)), number, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, color = colors.primaryText, textAlign = androidx.compose.ui.text.style.TextAlign.End)
                    }
                }
                Text(stringResource(R.string.counts_trips_with_timed_fish_and_a_saved_forecas, summary.trips), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
            }
        }
    }
}

@Composable
private fun TotalsRow(finished: List<Trip>) {
    val fish = finished.sumOf { it.catchCount }
    val blanks = finished.count { it.catchCount == 0 }
    val blankPercent = (blanks.toDouble() / finished.size * 100).roundToInt()
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        TotalStatCard(Icons.Filled.Flag, "${finished.size}", stringResource(R.string.trips), Modifier.weight(1f))
        TotalStatCard(FishGlyph, "$fish", stringResource(R.string.fish), Modifier.weight(1f))
        TotalStatCard(Icons.Filled.RadioButtonUnchecked, "$blankPercent%", stringResource(R.string.blank_trips), Modifier.weight(1f))
    }
}

@Composable
private fun TotalStatCard(icon: ImageVector, value: String, label: String, modifier: Modifier = Modifier) {
    BiteCard(modifier.semantics(mergeDescendants = true) {}, padding = 12.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(icon, null, Modifier.size(20.dp), tint = Theme.colors.accent)
            Text(value, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = Theme.colors.primaryText, maxLines = 1)
            Text(label, style = MaterialTheme.typography.labelMedium, color = Theme.colors.secondaryText, maxLines = 2)
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TripHistoryCard(trip: Trip, spot: Spot?, onDelete: () -> Unit) {
    val context = LocalContext.current
    val colors = Theme.colors
    val zone = spot?.zone ?: ZoneId.systemDefault()
    var menu by remember { mutableStateOf(false) }
    val delete = stringResource(R.string.delete)
    Box(Modifier.widthIn(max = Theme.readableWidth)) {
        BiteCard(
            Modifier.clip(RoundedCornerShape(Theme.cardRadius)).combinedClickable(onClick = {}, onLongClick = { menu = true })
                .semantics(mergeDescendants = true) { customActions = listOf(CustomAccessibilityAction(delete) { onDelete(); true }) },
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(spot?.name ?: stringResource(R.string.no_spot), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = colors.primaryText)
                    Text("${dateAndTime(context, trip.startedAt, zone)} · ${durationHours(trip.hours)}", style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                    trip.forecastIndex?.let { index ->
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Box(Modifier.size(8.dp).background(colors.bite(index), CircleShape))
                            Text(stringResource(R.string.forecast_x_x, index.roundToInt(), biteLabel(context, index)), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                        }
                    }
                    trip.completeCatchTimes?.takeIf { it.isNotEmpty() }?.let { CatchTimesLine(it, zone) }
                }
                if (trip.catchCount == 0) {
                    // Same shape as a catch badge, outlined: a blank trip counts too.
                    Box(contentAlignment = Alignment.Center) {
                        Row(Modifier.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            FishIcon(Modifier.size(16.dp), colors.secondaryText)
                            Text(stringResource(R.string.blank), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, color = colors.secondaryText)
                        }
                        Canvas(Modifier.matchParentSize()) {
                            drawRoundRect(
                                colors.secondaryText.copy(alpha = 0.45f), cornerRadius = CornerRadius(size.height / 2),
                                style = Stroke(1.2.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx()))),
                            )
                        }
                    }
                } else {
                    Row(
                        Modifier.background(colors.accent.copy(alpha = 0.15f), CircleShape).padding(horizontal = 12.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        FishIcon(Modifier.size(18.dp))
                        Text("${trip.catchCount}", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = colors.accent)
                    }
                }
            }
        }
        DropdownMenu(menu, { menu = false }) {
            DropdownMenuItem(text = { Text(delete) }, leadingIcon = { Icon(Icons.Filled.Delete, null) }, onClick = { menu = false; onDelete() })
        }
    }
}

