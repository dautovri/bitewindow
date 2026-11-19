package com.dautovri.bitecurve.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.dautovri.bitecurve.R
import com.dautovri.bitecurve.billing.Entitlements
import com.dautovri.bitecurve.data.DayOutlook
import com.dautovri.bitecurve.data.DayOutlooks
import com.dautovri.bitecurve.data.Spot
import com.dautovri.bitecurve.data.nowSeconds
import com.dautovri.bitecurve.data.startOfDay
import java.time.DayOfWeek
import java.time.Instant
import java.time.ZoneId
import kotlin.math.roundToInt

/**
 * Where and when to go: every spot against the days ahead, coloured by the day's bite index.
 * Free shows today and tomorrow; the rest of the ten days are Pro.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlannerScreen(onOpen: (Spot, Double) -> Unit, onPaywall: (PaywallContext) -> Unit) {
    val app = app()
    val context = LocalContext.current
    val colors = Theme.colors
    val data by app.store.data.collectAsStateWithLifecycle()
    val isPro by app.entitlements.isPro.collectAsStateWithLifecycle()
    val lastPrefetch by app.forecasts.lastPrefetch.collectAsStateWithLifecycle()
    val spots = data.spots
    var rows by remember { mutableStateOf<Map<String, List<DayOutlook>>>(emptyMap()) }
    var loaded by remember { mutableStateOf(false) }

    val horizon = Entitlements.horizonDays
    val visibleDays = if (isPro) horizon else Entitlements.freeDays
    val phone = ZoneId.systemDefault()
    // The days in the header: calendar dates, starting with the phone's today.
    val dayLabels = (0 until horizon).map { startOfDay(nowSeconds(), phone, it.toLong()) }

    LaunchedEffect(lastPrefetch, isPro, spots.joinToString { "${it.id}${it.waterRaw}${it.speciesRaw}${it.waterTempC}" }) {
        val inputs = DayOutlooks.inputs(spots, app.forecasts)
        rows = DayOutlooks.compute(inputs, horizon + 1)
        loaded = true
    }

    /** The spot's day that falls on the header column's calendar date. */
    fun day(spot: Spot, column: Int): DayOutlook? {
        val wanted = Instant.ofEpochSecond(dayLabels[column].toLong()).atZone(phone).toLocalDate()
        return rows[spot.id]?.firstOrNull { Instant.ofEpochSecond(it.date.toLong()).atZone(spot.zone).toLocalDate() == wanted }
    }

    // Locked columns of the coming weekend: someone planning Saturday on a Wednesday looks
    // exactly here. Only the weekend that starts within the week, as one run of days; on a
    // Sunday the Saturday six days off is next weekend, not "this weekend".
    val lockedWeekend: List<Int> = if (isPro) emptyList() else {
        val weekend = (Entitlements.freeDays until horizon).filter {
            Instant.ofEpochSecond(dayLabels[it].toLong()).atZone(phone).dayOfWeek in setOf(DayOfWeek.SATURDAY, DayOfWeek.SUNDAY)
        }
        val first = weekend.firstOrNull()
        if (first == null || first >= 6) emptyList() else weekend.filterIndexed { i, column -> column == first + i }
    }
    // True when any spot has a strong window on a locked weekend day. Says no more than that.
    val weekendLooksStrong = lockedWeekend.any { column -> spots.any { (day(it, column)?.index ?: 0.0) >= 65 } }
    val lockedContext = if (weekendLooksStrong) PaywallContext.WEEKEND else PaywallContext.DAYS

    // The single best spot-and-day in view.
    var best: Pair<Spot, DayOutlook>? = null
    for (spot in spots) for (column in 0 until visibleDays) {
        val d = day(spot, column) ?: continue
        val index = d.index ?: continue
        if (best == null || index > (best.second.index ?: 0.0)) best = spot to d
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.planner), fontWeight = FontWeight.Bold) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.background),
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Column(Modifier.widthIn(max = Theme.readableWidth), verticalArrangement = Arrangement.spacedBy(Theme.gap)) {
                val bestWindow = best?.second?.window
                if (best != null && bestWindow != null) {
                    val (spot, d) = best
                    BiteCard(onClick = { onOpen(spot, d.date) }) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                            IndexGauge(bestWindow.meanIndex, 60.dp)
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                Text(stringResource(R.string.best_in_view).uppercase(), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, color = colors.secondaryText)
                                Text(spot.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = colors.primaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(
                                    "${fullDay(d.date, spot.zone)} · ${clock(context, bestWindow.start, spot.zone)} – ${clock(context, bestWindow.end, spot.zone)}",
                                    style = MaterialTheme.typography.bodyMedium, color = colors.bite(bestWindow.meanIndex), maxLines = 2,
                                )
                            }
                            Icon(Icons.Filled.ChevronRight, null, tint = colors.secondaryText)
                        }
                    }
                }

                if (spots.isEmpty()) {
                    BiteCard { Text(stringResource(R.string.add_a_fishing_spot_from_the_map_tab_to_see_its_b), color = colors.secondaryText) }
                } else {
                    val cell = 46.dp
                    val gap = 6.dp
                    val nameWidth = 112.dp
                    BiteCard(padding = 12.dp) {
                        // Spot names stay put on the left; the days scroll sideways under their headers.
                        Row(horizontalArrangement = Arrangement.spacedBy(gap)) {
                            Column(verticalArrangement = Arrangement.spacedBy(gap)) {
                                Spacer(Modifier.size(nameWidth, 34.dp))
                                for (spot in spots) {
                                    Box(Modifier.size(nameWidth, cell), contentAlignment = Alignment.CenterStart) {
                                        Text(spot.name, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, color = colors.primaryText, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                    }
                                }
                            }
                            Column(Modifier.horizontalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(gap)) {
                                Row(horizontalArrangement = Arrangement.spacedBy(gap)) {
                                    dayLabels.forEachIndexed { offset, date ->
                                        Column(Modifier.size(cell, 34.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                                            Text(weekdayShort(date, phone), style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold, color = if (offset == 0) colors.accent else colors.secondaryText, maxLines = 1)
                                            Text(dayOfMonth(date, phone), style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Bold, color = colors.primaryText)
                                        }
                                    }
                                }
                                for (spot in spots) {
                                    Row(horizontalArrangement = Arrangement.spacedBy(gap)) {
                                        for (offset in 0 until horizon) {
                                            val d = day(spot, offset)
                                            val index = d?.index
                                            val shape = RoundedCornerShape(12.dp)
                                            val pro = stringResource(R.string.bitecurve_pro)
                                            when {
                                                offset >= visibleDays -> {
                                                    val weekend = offset in lockedWeekend
                                                    Box(
                                                        Modifier.size(cell).clip(shape).background(colors.well.copy(alpha = 0.6f))
                                                            .then(if (weekend) Modifier.border(1.5.dp, colors.accent.copy(alpha = 0.6f), shape) else Modifier)
                                                            .clickable { onPaywall(if (weekend) lockedContext else PaywallContext.DAYS) }
                                                            .clearAndSetSemantics { contentDescription = pro },
                                                        contentAlignment = Alignment.Center,
                                                    ) { Icon(Icons.Filled.Lock, null, Modifier.size(14.dp), tint = if (weekend) colors.accent else colors.secondaryText) }
                                                }

                                                d != null && index != null -> {
                                                    val color = colors.bite(index)
                                                    val isBest = best?.let { it.first.id == spot.id && it.second.date == d.date } ?: false
                                                    val description = "${spot.name}, ${fullDay(d.date, spot.zone)}"
                                                    val state = "${index.roundToInt()}, ${biteLabel(context, index)}"
                                                    Box(
                                                        Modifier.size(cell).clip(shape)
                                                            // Strong days are solid; the rest are tinted, so the eye lands on the best ones.
                                                            .background(if (index >= 65) color else color.copy(alpha = 0.16f))
                                                            .then(if (isBest) Modifier.border(2.dp, colors.primaryText, shape) else Modifier)
                                                            .clickable { onOpen(spot, d.date) }
                                                            .clearAndSetSemantics { contentDescription = description; stateDescription = state },
                                                        contentAlignment = Alignment.Center,
                                                    ) {
                                                        Text("${index.roundToInt()}", style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Bold, color = if (index >= 65) Color.White else color)
                                                    }
                                                }

                                                else -> Box(Modifier.size(cell).clip(shape).background(colors.well.copy(alpha = 0.4f)), contentAlignment = Alignment.Center) {
                                                    Text(if (loaded) "–" else "", color = colors.secondaryText)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Row(Modifier.padding(horizontal = 4.dp).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        for (sample in listOf(70.0, 57.0, 42.0, 20.0)) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                                Box(Modifier.size(8.dp).background(colors.bite(sample), CircleShape))
                                Text(biteLabel(context, sample), style = MaterialTheme.typography.labelSmall, color = colors.secondaryText, maxLines = 1)
                            }
                        }
                    }
                    if (!isPro) {
                        if (weekendLooksStrong) {
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
                                Box(Modifier.size(9.dp).background(colors.bite(65.0), CircleShape))
                                Spacer(Modifier.width(8.dp))
                                Text(stringResource(R.string.a_strong_bite_is_forecast_this_weekend), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, color = colors.bite(65.0))
                            }
                        }
                        Button({ onPaywall(if (lockedWeekend.isEmpty()) PaywallContext.DAYS else lockedContext) }, Modifier.fillMaxWidth()) {
                            Icon(Icons.Filled.LockOpen, null, Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(
                                stringResource(if (lockedWeekend.isEmpty()) R.string.unlock_all_10_days_with_bitecurve_pro else R.string.see_the_weekend_with_bitecurve_pro),
                                fontWeight = FontWeight.SemiBold,
                            )
                        }
                    }
                }
                Spacer(Modifier.height(0.dp))
            }
        }
    }
}
