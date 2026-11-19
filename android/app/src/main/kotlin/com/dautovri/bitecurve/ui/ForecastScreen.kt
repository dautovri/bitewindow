package com.dautovri.bitecurve.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.Button
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
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.dautovri.bitecurve.BiteCurveApp
import com.dautovri.bitecurve.R
import com.dautovri.bitecurve.core.BiteWindow
import com.dautovri.bitecurve.core.Forecaster
import com.dautovri.bitecurve.core.ScorePoint
import com.dautovri.bitecurve.core.SpotContext
import com.dautovri.bitecurve.data.Forecast
import com.dautovri.bitecurve.data.Spot
import com.dautovri.bitecurve.data.nowSeconds
import com.dautovri.bitecurve.data.startOfDay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

@Composable
fun app(): BiteCurveApp = LocalContext.current.applicationContext as BiteCurveApp

/** What a spot card shows, worked out from one forecast. */
private class SpotSnapshot(
    val today: BiteWindow? = null,
    val tomorrow: BiteWindow? = null,
    /** Today's curve, for the small chart. */
    val points: List<ScorePoint> = emptyList(),
    val conditions: Conditions? = null,
    val isOffline: Boolean = false,
)

private suspend fun snapshot(spot: Spot, context: SpotContext, forecast: Forecast): SpotSnapshot = withContext(Dispatchers.Default) {
    val now = nowSeconds()
    val today = startOfDay(now, spot.zone)
    val tomorrow = startOfDay(now, spot.zone, 1)
    val end = startOfDay(now, spot.zone, 2)
    val all = Forecaster.curve(context, forecast.hours, today, end, fillMissingWeather = true)
    val points = all.filter { it.time < tomorrow }
    SpotSnapshot(
        // Windows that already started more than one 15-minute step ago are over for today.
        today = Forecaster.bestWindow(points, notBefore = now - 900),
        tomorrow = Forecaster.bestWindow(all.filter { it.time >= tomorrow && it.time < end }),
        points = points,
        conditions = Conditions(now, forecast.hours, spot.latitude, spot.longitude, spot.zone),
        isOffline = forecast.source == Forecast.Source.CACHED,
    )
}

/** The Forecast tab: one card per saved spot with today's index, best window and the weather now. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ForecastScreen(onAddSpot: () -> Unit, onOpen: (Spot) -> Unit, onSettings: () -> Unit) {
    val app = app()
    val data by app.store.data.collectAsStateWithLifecycle()
    val isPro by app.entitlements.isPro.collectAsStateWithLifecycle()
    val alertsOn by app.prefs.alertsEnabled.collectAsStateWithLifecycle()
    var alertsPromptAnswered by remember { mutableStateOf(app.prefs.alertsPromptAnswered) }
    val spots = data.spots

    // A spot added, removed or changed: the alerts follow.
    LaunchedEffect(spots.joinToString { "${it.id}${it.name}${it.waterRaw}${it.speciesRaw}${it.waterTempC}" }) {
        delay(4000)
        com.dautovri.bitecurve.alerts.BiteAlerts.reschedule(app)
    }
    Scaffold(
        containerColor = Theme.colors.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.forecast), fontWeight = FontWeight.Bold) },
                actions = {
                    IconButton(onAddSpot) { Icon(Icons.Filled.Add, stringResource(R.string.add_spot), tint = Theme.colors.accent) }
                    IconButton(onSettings) { Icon(Icons.Filled.Settings, stringResource(R.string.settings), tint = Theme.colors.accent) }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Theme.colors.background),
            )
        },
    ) { padding ->
        if (spots.isEmpty()) {
            Column(
                Modifier.fillMaxSize().padding(padding).padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
            ) {
                Icon(Icons.Filled.Place, null, Modifier.size(48.dp), tint = Theme.colors.secondaryText)
                Spacer(Modifier.height(12.dp))
                Text(stringResource(R.string.no_spots_yet), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = Theme.colors.primaryText)
                Spacer(Modifier.height(6.dp))
                Text(
                    stringResource(R.string.add_a_fishing_spot_from_the_map_tab_to_see_its_b),
                    color = Theme.colors.secondaryText, textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(16.dp))
                Button(onAddSpot) { Text(stringResource(R.string.add_your_first_spot)) }
            }
        } else {
            LazyColumn(
                Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(Theme.gap), horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                // Once, to someone with a spot and no alerts: free for today and tomorrow, so not a paywall.
                if (!alertsOn && !alertsPromptAnswered) {
                    item(key = "alerts-prompt") {
                        Box(Modifier.widthIn(max = Theme.readableWidth)) { AlertsPromptCard { alertsPromptAnswered = true } }
                    }
                }
                items(spots, key = { it.id }) { spot ->
                    SpotCard(spot, isPro, onOpen = { onOpen(spot) }, onDelete = { app.store.deleteSpot(spot.id) })
                }
            }
        }
    }
}

/** One spot on the Forecast tab. */
@OptIn(ExperimentalFoundationApi::class, ExperimentalLayoutApi::class)
@Composable
private fun SpotCard(spot: Spot, isPro: Boolean, onOpen: () -> Unit, onDelete: () -> Unit) {
    val app = app()
    val context = LocalContext.current
    val colors = Theme.colors
    val lastPrefetch by app.forecasts.lastPrefetch.collectAsStateWithLifecycle()
    var snapshot by remember(spot.id) { mutableStateOf(SpotSnapshot()) }
    var loaded by remember(spot.id) { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }

    LaunchedEffect(spot.id, spot.waterRaw, spot.speciesRaw, spot.waterTempC, spot.bankBearingDeg, spot.timeZoneId, lastPrefetch) {
        val service = app.forecasts
        // Saved forecast first, so the card fills at once with weak or no signal;
        // the network result (up to the 10 s timeout) replaces it.
        val saved = service.saved(spot.latitude, spot.longitude)
        if (saved != null) {
            snapshot = snapshot(spot, spot.context(service), saved)
            loaded = true
        } else if (snapshot.today == null) {
            // Nothing saved yet (a new spot): sun and moon alone until the weather is in, rather
            // than an empty card for as long as the requests take with a weak signal.
            snapshot = snapshot(spot, spot.context(service), Forecast(emptyList(), Forecast.Source.LIVE))
        }
        val tide = if (spot.isSalt) service.tideStation(spot.latitude, spot.longitude) else null
        val forecast = service.forecast(spot.latitude, spot.longitude)
        // The water estimate feeds the score; the context is rebuilt once it is in.
        service.waterEstimate(spot.latitude, spot.longitude, spot.isSalt)
        snapshot = snapshot(spot, spot.context(service).copy(tide = tide), forecast)
        loaded = true
        // Once the spot's zone is known the card redraws in it (the zone is one of the keys).
        com.dautovri.bitecurve.data.SpotTimeZone.resolveIfNeeded(context, app.store, spot)
    }

    val delete = stringResource(R.string.delete)
    Box(Modifier.widthIn(max = Theme.readableWidth)) {
        BiteCard(
            Modifier
                .clip(RoundedCornerShape(Theme.cardRadius))
                .combinedClickable(onClick = onOpen, onLongClick = { menu = true })
                .semantics { customActions = listOf(CustomAccessibilityAction(delete) { onDelete(); true }) },
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(spot.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = colors.primaryText)
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                            WaterIcon(spot.isSalt, Modifier.size(15.dp))
                            Text("${spot.species.label(context)} · ${spot.water.label(context)}", style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText)
                        }
                    }
                    IndexGauge(snapshot.today?.meanIndex, 60.dp)
                }

                // The verdict first: today's window, with the day's shape (Pro) or tomorrow (free) beside it.
                FlowRow(
                    Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp), itemVerticalAlignment = Alignment.CenterVertically,
                ) {
                    val window = snapshot.today
                    if (window != null) {
                        WindowPill(context, window, spot.zone)
                    } else {
                        // Sun and moon fill any gap in the weather, so a missing window means the day is nearly over.
                        Text(
                            stringResource(if (loaded) R.string.not_enough_forecast_left_for_today else R.string.loading),
                            style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText,
                        )
                    }
                    if (isPro) {
                        if (snapshot.points.size > 1) {
                            MiniCurve(snapshot.points, colors.bite(snapshot.today?.meanIndex), Modifier.weight(1f).widthIn(min = 96.dp).height(36.dp))
                        }
                    } else {
                        snapshot.tomorrow?.let { tomorrow ->
                            Row(
                                Modifier.background(colors.well, CircleShape).padding(horizontal = 12.dp, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                Text(stringResource(R.string.tomorrow), style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText)
                                Box(Modifier.size(8.dp).background(colors.bite(tomorrow.meanIndex), CircleShape))
                                Text("${tomorrow.meanIndex.roundToInt()}", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, color = colors.primaryText)
                            }
                        }
                    }
                }

                snapshot.conditions?.let { conditions ->
                    if (conditions.hour != null) {
                        Text(
                            stringResource(R.string.now).uppercase(), style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.SemiBold, color = colors.secondaryText, modifier = Modifier.padding(top = 2.dp),
                        )
                    }
                    ConditionsGrid(conditions)
                    if (snapshot.isOffline) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                            Icon(Icons.Filled.WifiOff, null, Modifier.size(14.dp), tint = colors.secondaryText)
                            Text(stringResource(R.string.offline), style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                        }
                    }
                }
            }
        }
        DropdownMenu(menu, { menu = false }) {
            DropdownMenuItem(
                text = { Text(delete) },
                leadingIcon = { Icon(Icons.Filled.Delete, null) },
                onClick = { menu = false; onDelete() },
            )
        }
        Spacer(Modifier.width(0.dp))
    }
}
