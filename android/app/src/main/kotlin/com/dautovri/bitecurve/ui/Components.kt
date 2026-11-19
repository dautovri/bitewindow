package com.dautovri.bitecurve.ui

import android.content.Context
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.East
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Navigation
import androidx.compose.material.icons.filled.NorthEast
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.SouthEast
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.filled.Waves
import androidx.compose.material.icons.filled.WbCloudy
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material.icons.filled.WbTwilight
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dautovri.bitecurve.R
import com.dautovri.bitecurve.core.BiteWindow
import com.dautovri.bitecurve.core.ScorePoint
import com.dautovri.bitecurve.core.TideStation
import com.dautovri.bitecurve.data.nowSeconds
import java.time.Instant
import java.time.ZoneId
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Ring filled to the index, with the number in the middle. `null` draws an empty ring. */
@Composable
fun IndexGauge(index: Double?, size: Dp = 44.dp) {
    val colors = Theme.colors
    val color = colors.bite(index)
    val label = stringResource(R.string.bite_index)
    val value = index?.let { stringResource(R.string.x_of_100, it.roundToInt()) } ?: stringResource(R.string.not_available)
    Box(
        Modifier.size(size).clearAndSetSemantics { contentDescription = label; stateDescription = value },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val line = max(3.dp.toPx(), this.size.minDimension * 0.11f)
            val inset = line / 2
            val arc = Size(this.size.width - line, this.size.height - line)
            drawArc(colors.secondaryText.copy(alpha = 0.18f), 0f, 360f, false, Offset(inset, inset), arc, style = Stroke(line))
            val sweep = (max(0.0, min(100.0, index ?: 0.0)) / 100 * 360).toFloat()
            if (sweep > 0) drawArc(color, -90f, sweep, false, Offset(inset, inset), arc, style = Stroke(line, cap = StrokeCap.Round))
        }
        Text(
            index?.let { "${it.roundToInt()}" } ?: "–",
            fontSize = (size.value * 0.36f).sp, fontWeight = FontWeight.Bold, color = colors.primaryText, maxLines = 1,
        )
    }
}

/** The moon as it looks: the lit part of the disc for a sun–moon elongation in degrees. */
@Composable
fun MoonIcon(phaseAngle: Double, size: Dp = 14.dp) {
    val colors = Theme.colors
    val label = stringResource(R.string.moon)
    Canvas(Modifier.size(size).semantics { contentDescription = label }) {
        val r = this.size.minDimension / 2
        val c = Offset(this.size.width / 2, this.size.height / 2)
        drawCircle(colors.accent.copy(alpha = 0.25f), r, c)
        // The terminator is half an ellipse whose width follows the phase.
        val waxing = phaseAngle < 180
        val k = cos(Math.toRadians(phaseAngle)).toFloat()   // 1 new, -1 full
        val lit = Path().apply {
            val bounds = Rect(c.x - r, c.y - r, c.x + r, c.y + r)
            // The lit limb: right half when waxing, left half when waning.
            arcTo(bounds, -90f, if (waxing) 180f else -180f, true)
            // Back along the terminator.
            val w = r * abs(k)
            val term = Rect(c.x - w, c.y - r, c.x + w, c.y + r)
            val bulgesIntoLit = k > 0
            val sweep = if (waxing == bulgesIntoLit) -180f else 180f
            arcTo(term, 90f, sweep, false)
            close()
        }
        drawPath(lit, colors.accent)
    }
}

private fun pathThrough(points: List<Offset>): Path = Path().apply {
    points.forEachIndexed { i, p -> if (i == 0) moveTo(p.x, p.y) else lineTo(p.x, p.y) }
}

/**
 * One day's bite curve with night shaded, the best window marked and a line at the current
 * time. With no points it draws the day's frame only (the free tier shows that, never a
 * made-up curve); `domain` then gives the day.
 */
@Composable
fun BiteCurveChart(
    points: List<ScorePoint>, window: BiteWindow?, sunrise: Double?, sunset: Double?,
    zone: ZoneId, modifier: Modifier = Modifier, domain: ClosedFloatingPointRange<Double>? = null,
) {
    val colors = Theme.colors
    val color = colors.bite(window?.meanIndex)
    val context = LocalContext.current
    val measurer = rememberTextMeasurer()
    val label = stringResource(R.string.bite_index_through_the_day)
    val span = domain ?: if (points.size >= 2 && points.first().time < points.last().time) points.first().time..points.last().time else null
    val axisStyle = TextStyle(fontSize = 10.sp, color = colors.secondaryText)
    Canvas(modifier.fillMaxWidth().semantics { contentDescription = label }) {
        if (span == null) return@Canvas
        val left = 30.dp.toPx()
        val bottom = 18.dp.toPx()
        val plot = Rect(left, 8.dp.toPx(), size.width - 10.dp.toPx(), size.height - bottom)
        fun x(t: Double) = plot.left + ((t - span.start) / (span.endInclusive - span.start)).toFloat() * plot.width
        fun y(v: Double) = plot.bottom - (v / 100).toFloat() * plot.height

        clipRect(plot.left, plot.top, plot.right, plot.bottom) {
            // Before sunrise and after sunset, so dawn and dusk peaks read at a glance.
            if (sunrise != null && sunrise > span.start) {
                drawRect(colors.night, Offset(plot.left, plot.top), Size(x(min(sunrise, span.endInclusive)) - plot.left, plot.height))
            }
            if (sunset != null && sunset < span.endInclusive) {
                val from = x(max(sunset, span.start))
                drawRect(colors.night, Offset(from, plot.top), Size(plot.right - from, plot.height))
            }
            if (window != null) {
                drawRect(color.copy(alpha = 0.18f), Offset(x(window.start), plot.top), Size(x(window.end) - x(window.start), plot.height))
            }
            if (points.size >= 2) {
                val line = points.map { Offset(x(it.time), y(it.index)) }
                val area = pathThrough(line).apply {
                    lineTo(line.last().x, plot.bottom)
                    lineTo(line.first().x, plot.bottom)
                    close()
                }
                drawPath(area, Brush.verticalGradient(listOf(color.copy(alpha = 0.32f), color.copy(alpha = 0.02f)), plot.top, plot.bottom))
                drawPath(pathThrough(line), color, style = Stroke(2.5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
            }
            drawLine(
                colors.secondaryText.copy(alpha = 0.5f), Offset(plot.left, y(50.0)), Offset(plot.right, y(50.0)),
                1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx())),
            )
            val now = nowSeconds()
            if (now in span) {
                drawLine(colors.primaryText.copy(alpha = 0.6f), Offset(x(now), plot.top), Offset(x(now), plot.bottom), 1.5.dp.toPx())
            }
        }

        for (v in listOf(0, 50, 100)) {
            val text = measurer.measure("$v", axisStyle)
            drawText(text, topLeft = Offset(plot.left - text.size.width - 5.dp.toPx(), y(v.toDouble()) - text.size.height / 2f))
        }
        // A label every six hours of the spot's clock.
        var hour = Instant.ofEpochSecond(span.start.toLong()).atZone(zone).withMinute(0).withSecond(0)
        while (hour.toEpochSecond() <= span.endInclusive) {
            val t = hour.toEpochSecond().toDouble()
            if (hour.hour % 6 == 0 && t >= span.start) {
                drawLine(colors.secondaryText.copy(alpha = 0.18f), Offset(x(t), plot.top), Offset(x(t), plot.bottom), 1.dp.toPx())
                val text = measurer.measure(hourLabel(context, t, zone), axisStyle)
                val tx = (x(t) - text.size.width / 2f).coerceIn(plot.left, size.width - text.size.width)
                drawText(text, topLeft = Offset(tx, plot.bottom + 3.dp.toPx()))
            }
            hour = hour.plusHours(1)
        }
    }
}

/** Today's curve without axes, with a dot at the current time. */
@Composable
fun MiniCurve(points: List<ScorePoint>, color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier.clearAndSetSemantics { }) {
        if (points.size < 2) return@Canvas
        val start = points.first().time
        val end = points.last().time
        fun x(t: Double) = ((t - start) / (end - start)).toFloat() * size.width
        fun y(v: Double) = size.height - (v / 100).toFloat() * size.height
        drawPath(pathThrough(points.map { Offset(x(it.time), y(it.index)) }), color, style = Stroke(2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
        val now = nowSeconds()
        val current = points.minByOrNull { abs(it.time - now) }
        if (current != null && abs(current.time - now) < 3600) drawCircle(color, 3.5.dp.toPx(), Offset(x(current.time), y(current.index)))
    }
}

@Composable
fun TideChart(samples: List<TideStation.Sample>, zone: ZoneId, modifier: Modifier = Modifier) {
    val colors = Theme.colors
    val context = LocalContext.current
    val measurer = rememberTextMeasurer()
    val label = stringResource(R.string.tide_height_through_the_day)
    val axisStyle = TextStyle(fontSize = 10.sp, color = colors.secondaryText)
    Canvas(modifier.fillMaxWidth().semantics { contentDescription = label }) {
        if (samples.size < 2) return@Canvas
        val left = 30.dp.toPx()
        val bottom = 18.dp.toPx()
        val plot = Rect(left, 8.dp.toPx(), size.width - 10.dp.toPx(), size.height - bottom)
        val start = samples.first().time
        val end = samples.last().time
        val low = samples.minOf { it.height }
        val high = samples.maxOf { it.height }
        val pad = max(0.05, (high - low) * 0.1)
        fun x(t: Double) = plot.left + ((t - start) / (end - start)).toFloat() * plot.width
        fun y(h: Double) = plot.bottom - ((h - (low - pad)) / (high - low + 2 * pad)).toFloat() * plot.height
        val line = samples.map { Offset(x(it.time), y(it.height)) }
        val area = pathThrough(line).apply { lineTo(line.last().x, plot.bottom); lineTo(line.first().x, plot.bottom); close() }
        drawPath(area, Brush.verticalGradient(listOf(colors.tide.copy(alpha = 0.3f), colors.tide.copy(alpha = 0.03f)), plot.top, plot.bottom))
        drawPath(pathThrough(line), colors.tide, style = Stroke(2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
        for (h in listOf(low, high)) {
            val text = measurer.measure(number(h, 1), axisStyle)
            drawText(text, topLeft = Offset(plot.left - text.size.width - 5.dp.toPx(), y(h) - text.size.height / 2f))
        }
        var hour = Instant.ofEpochSecond(start.toLong()).atZone(zone).withMinute(0).withSecond(0)
        while (hour.toEpochSecond() <= end) {
            val t = hour.toEpochSecond().toDouble()
            if (hour.hour % 6 == 0 && t >= start) {
                drawLine(colors.secondaryText.copy(alpha = 0.18f), Offset(x(t), plot.top), Offset(x(t), plot.bottom), 1.dp.toPx())
                val text = measurer.measure(hourLabel(context, t, zone), axisStyle)
                drawText(text, topLeft = Offset((x(t) - text.size.width / 2f).coerceIn(plot.left, size.width - text.size.width), plot.bottom + 3.dp.toPx()))
            }
            hour = hour.plusHours(1)
        }
    }
}

private fun cloudIcon(cover: Double?): ImageVector = when {
    cover == null -> Icons.Filled.Cloud
    cover < 0.25 -> Icons.Filled.WbSunny
    cover < 0.7 -> Icons.Filled.WbCloudy
    else -> Icons.Filled.Cloud
}

private fun trendIcon(trend: Int?): ImageVector? = when (trend) {
    null -> null
    1 -> Icons.Filled.NorthEast
    -1 -> Icons.Filled.SouthEast
    else -> Icons.Filled.East
}

/**
 * Wind, pressure, temperature and cloud as four even cells (symbol over value), with sunrise,
 * sunset and the moon in a quiet row under them. Wraps at large text sizes. Shows only the
 * sun row when there is no forecast for that moment.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ConditionsGrid(conditions: Conditions) {
    val context = LocalContext.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (conditions.hour != null) {
            FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                conditions.wind?.let {
                    val degrees = conditions.windArrowDegrees
                    ConditionCell(if (degrees == null) Icons.Filled.Air else Icons.Filled.Navigation, it, rotation = degrees?.toFloat() ?: 0f)
                }
                conditions.pressure?.let { ConditionCell(Icons.Filled.Speed, it, trailing = trendIcon(conditions.pressureTrend)) }
                conditions.temperature?.let { ConditionCell(Icons.Filled.Thermostat, it) }
                conditions.cloud?.let { ConditionCell(cloudIcon(conditions.hour.cloudCover), it) }
            }
        }
        // Sun times are missing in polar day or night.
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            conditions.clock(context, conditions.sunrise)?.let { SmallReading(Icons.Filled.WbTwilight, "↑ $it") }
            conditions.clock(context, conditions.sunset)?.let { SmallReading(Icons.Filled.WbTwilight, "↓ $it") }
            MoonIcon(conditions.moonPhaseAngle)
        }
    }
}

@Composable
private fun ConditionCell(icon: ImageVector, text: String, rotation: Float = 0f, trailing: ImageVector? = null) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Icon(icon, null, Modifier.size(20.dp).rotate(rotation), tint = Theme.colors.accent)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(text, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, color = Theme.colors.primaryText, maxLines = 1)
            if (trailing != null) Icon(trailing, null, Modifier.size(12.dp), tint = Theme.colors.secondaryText)
        }
    }
}

@Composable
fun SmallReading(icon: ImageVector, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Icon(icon, null, Modifier.size(14.dp), tint = Theme.colors.accent)
        Text(text, style = MaterialTheme.typography.bodySmall, color = Theme.colors.secondaryText, maxLines = 1)
    }
}

/**
 * How much each factor pushes the index up or down, in words with up to three dots for how
 * hard, with the reading behind each factor.
 */
class Factor(val name: String, val value: Double, val icon: ImageVector? = null, val reading: String? = null, val trend: Int? = null, val moonPhase: Double? = null)

@Composable
fun FactorBreakdown(factors: List<Factor>, title: String = stringResource(R.string.what_drives_this_window)) {
    val colors = Theme.colors
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = colors.secondaryText)
        for (factor in factors) {
            val helps = stringResource(R.string.helps)
            val hurts = stringResource(R.string.hurts)
            val neutral = stringResource(R.string.neutral_2)
            Row(
                Modifier.fillMaxWidth().clearAndSetSemantics {
                    contentDescription = listOfNotNull(factor.name, factor.reading).joinToString(", ")
                    stateDescription = if (factor.value > 0.02) helps else if (factor.value < -0.02) hurts else neutral
                },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Box(Modifier.width(22.dp), contentAlignment = Alignment.Center) {
                    if (factor.moonPhase != null) MoonIcon(factor.moonPhase, 18.dp)
                    else if (factor.icon != null) Icon(factor.icon, null, Modifier.size(20.dp), tint = colors.accent)
                }
                Column(Modifier.weight(1f)) {
                    Text(factor.name, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, color = colors.primaryText)
                    if (factor.reading != null) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(factor.reading, style = MaterialTheme.typography.bodySmall, color = colors.secondaryText)
                            trendIcon(factor.trend)?.let { Icon(it, null, Modifier.size(11.dp), tint = colors.secondaryText) }
                        }
                    }
                }
                FactorEffect(factor.value)
            }
        }
    }
}

@Composable
private fun FactorEffect(value: Double) {
    val colors = Theme.colors
    val tint = if (value > 0.02) colors.positive else if (value < -0.02) colors.negative else colors.secondaryText
    // About ±0.25 is the most a factor gives.
    val strength = if (abs(value) <= 0.02) 0 else if (abs(value) < 0.08) 1 else if (abs(value) < 0.16) 2 else 3
    Row(
        Modifier.background(tint.copy(alpha = 0.13f), CircleShape).padding(horizontal = 9.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(if (value > 0.02) Icons.Filled.ArrowUpward else if (value < -0.02) Icons.Filled.ArrowDownward else Icons.Filled.Remove, null, Modifier.size(12.dp), tint = tint)
        Text(
            stringResource(if (value > 0.02) R.string.helps_2 else if (value < -0.02) R.string.hurts_2 else R.string.neutral),
            style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, color = tint,
        )
        if (strength > 0) {
            Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                repeat(3) { i -> Box(Modifier.size(4.dp).background(if (i < strength) tint else tint.copy(alpha = 0.25f), CircleShape)) }
            }
        }
    }
}

class StripDay(val date: Double, val index: Double?, val isLocked: Boolean)

/**
 * The days ahead as a row of capsules: weekday, date and the day's index. Days past the free
 * horizon show their real date and a lock, never a number.
 */
@Composable
fun DayStrip(days: List<StripDay>, selected: Double?, zone: ZoneId, onTap: (StripDay) -> Unit) {
    val colors = Theme.colors
    val best = days.mapNotNull { it.index }.maxOrNull()
    val pro = stringResource(R.string.bitecurve_pro)
    Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        for (day in days) {
            val isSelected = day.date == selected
            val shape = RoundedCornerShape(16.dp)
            val description = fullDay(day.date, zone)
            val state = if (day.isLocked) pro else day.index?.let { "${it.roundToInt()}" } ?: "–"
            Column(
                Modifier
                    .clip(shape)
                    .background(if (isSelected) colors.accent.copy(alpha = 0.14f) else Color.Transparent)
                    .then(if (isSelected) Modifier.border(1.5.dp, colors.accent, shape) else Modifier)
                    .clickable { onTap(day) }
                    .widthIn(min = 56.dp)
                    .padding(horizontal = 4.dp, vertical = 8.dp)
                    .clearAndSetSemantics { contentDescription = description; stateDescription = state; this.selected = isSelected },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Text(weekdayShort(day.date, zone), style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold, color = if (isSelected) colors.accent else colors.secondaryText, maxLines = 1)
                Text(dayOfMonth(day.date, zone), style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Bold, color = colors.primaryText)
                if (day.isLocked) {
                    Box(Modifier.size(36.dp), contentAlignment = Alignment.Center) {
                        Canvas(Modifier.fillMaxSize()) {
                            drawCircle(colors.secondaryText.copy(alpha = 0.3f), style = Stroke(1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx()))))
                        }
                        Icon(Icons.Filled.Lock, null, Modifier.size(14.dp), tint = colors.secondaryText)
                    }
                } else {
                    IndexGauge(day.index, 36.dp)
                }
                // The best day in view.
                Box(Modifier.size(5.dp).background(if (day.index != null && day.index == best) colors.bite(day.index) else Color.Transparent, CircleShape))
            }
        }
    }
}

/** Today's best window as a coloured pill. */
@Composable
fun WindowPill(context: Context, window: BiteWindow, zone: ZoneId) {
    val color = Theme.colors.bite(window.meanIndex)
    val range = "${clock(context, window.start, zone)} – ${clock(context, window.end, zone)}"
    val description = stringResource(R.string.best_today_x_x, clock(context, window.start, zone), clock(context, window.end, zone))
    Row(
        Modifier.background(color.copy(alpha = 0.14f), CircleShape).padding(horizontal = 12.dp, vertical = 8.dp)
            .clearAndSetSemantics { contentDescription = description },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(Icons.Filled.Schedule, null, Modifier.size(16.dp), tint = color)
        Text(range, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Bold, color = color, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** The app's fish, the same outline as the notification icon (Material has no plain fish). */
val FishGlyph: ImageVector = ImageVector.Builder("Fish", 24.dp, 24.dp, 24f, 24f).addPath(
    addPathNodes("M2,12c3,-4.4 7.5,-6 11.2,-6c3,0 5.2,1.5 6.7,3.4L23,6.4v11.2l-3.1,-3c-1.5,1.9 -3.7,3.4 -6.7,3.4c-3.7,0 -8.2,-1.6 -11.2,-6zM8,10.6a1.1,1.1 0,1 0,0.01 0z"),
    fill = SolidColor(Color.Black), pathFillType = androidx.compose.ui.graphics.PathFillType.EvenOdd,
).build()

@Composable
fun FishIcon(modifier: Modifier = Modifier, tint: Color = Theme.colors.accent) {
    Icon(FishGlyph, null, modifier, tint = tint)
}

@Composable
fun WaterIcon(isSalt: Boolean, modifier: Modifier = Modifier) {
    Icon(if (isSalt) Icons.Filled.Waves else Icons.Filled.WaterDrop, null, modifier, tint = Theme.colors.secondaryText)
}

@Composable
fun Hairline() {
    Spacer(Modifier.fillMaxWidth().height(1.dp).background(Theme.colors.stroke))
}
