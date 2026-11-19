package com.dautovri.bitecurve.alerts

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.dautovri.bitecurve.BiteCurveApp
import com.dautovri.bitecurve.MainActivity
import com.dautovri.bitecurve.R
import com.dautovri.bitecurve.billing.Entitlements
import com.dautovri.bitecurve.core.BiteWindow
import com.dautovri.bitecurve.data.DayOutlook
import com.dautovri.bitecurve.data.DayOutlooks
import com.dautovri.bitecurve.data.SpotSummaryInput
import com.dautovri.bitecurve.data.nowSeconds
import com.dautovri.bitecurve.ui.clock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import kotlin.math.roundToInt

/**
 * Port of App/BiteWindow/Services/BiteAlerts.swift: local notifications for good bite windows,
 * laid out on the phone from the saved forecasts. Nothing is sent from a server and nothing
 * about the spots leaves the device.
 *
 * Two kinds, both only for windows at or above the chosen index:
 * - an hour before a window starts;
 * - at 19:00 the evening before the best such day among all spots.
 *
 * Everything pending is replaced each time forecasts are refreshed, so an alert always
 * reflects the latest forecast the phone has seen.
 */
object BiteAlerts {
    const val channelId = "bite"
    /** How far ahead Pro alerts are laid out, so they keep coming for a week without the app opened. */
    const val horizonDays = 7

    /** Free alerts cover the days the free forecast shows: today and tomorrow, as on iOS. */
    fun horizon(isPro: Boolean): Int = if (isPro) horizonDays else minOf(horizonDays, Entitlements.freeDays)
    private const val maxPending = 40

    data class Alert(val id: String, val fireDate: Double, val title: String, val body: String)

    /** The wording, so `plan` can be tested without Android. */
    interface Wording {
        fun clock(time: Double, zone: ZoneId): String
        fun startsInAnHour(range: String, index: Int): String
        fun tomorrowTitle(): String
        fun tomorrowBody(spot: String, index: Int, range: String): String
    }

    /** The alerts for these forecasts, soonest first. Pure. */
    fun plan(inputs: List<SpotSummaryInput>, days: Map<String, List<DayOutlook>>, threshold: Double, now: Double, wording: Wording): List<Alert> {
        val alerts = ArrayList<Alert>()
        // Best qualifying spot per evening, for the "tomorrow" heads-up.
        val eveBest = HashMap<Double, Pair<SpotSummaryInput, BiteWindow>>()

        for (input in inputs) {
            for (day in days[input.id] ?: emptyList()) {
                val window = day.window ?: continue
                if (window.meanIndex < threshold) continue
                val index = window.meanIndex.roundToInt()
                val range = "${wording.clock(window.start, input.zone)} – ${wording.clock(window.end, input.zone)}"

                val soon = window.start - 3600
                if (soon > now + 300) {
                    alerts.add(Alert("soon.${input.id}.${day.date.toLong()}", soon, input.name, wording.startsInAnHour(range, index)))
                }

                // 19:00 the evening before, on the spot's clock.
                val eve = Instant.ofEpochSecond(day.date.toLong()).atZone(input.zone).minusHours(5).toEpochSecond().toDouble()
                if (eve > now + 300) {
                    val current = eveBest[eve]
                    if (current != null && current.second.meanIndex >= window.meanIndex) continue
                    eveBest[eve] = input to window
                }
            }
        }

        for ((eve, best) in eveBest) {
            val (input, window) = best
            val range = "${wording.clock(window.start, input.zone)} – ${wording.clock(window.end, input.zone)}"
            alerts.add(Alert("eve.${eve.toLong()}", eve, wording.tomorrowTitle(), wording.tomorrowBody(input.name, window.meanIndex.roundToInt(), range)))
        }
        return alerts.sortedBy { it.fireDate }
    }

    fun createChannel(context: Context) {
        val channel = NotificationChannel(channelId, context.getString(R.string.bite_alerts), NotificationManager.IMPORTANCE_DEFAULT)
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    fun isAuthorized(context: Context): Boolean {
        val granted = Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        return granted && NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    private fun pending(context: Context, code: Int, alert: Alert?): PendingIntent {
        val intent = Intent(context, AlertReceiver::class.java).setAction("com.dautovri.bitecurve.ALERT.$code")
        if (alert != null) intent.putExtra("title", alert.title).putExtra("body", alert.body).putExtra("code", code)
        return PendingIntent.getBroadcast(context, code, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** Removes every pending alert of ours. */
    fun cancelAll(context: Context) {
        val app = context.applicationContext as BiteCurveApp
        val alarms = context.getSystemService(AlarmManager::class.java)
        for (code in 0 until maxOf(app.prefs.pendingAlertCount, maxPending)) alarms.cancel(pending(context, code, null))
        app.prefs.pendingAlertCount = 0
    }

    /**
     * Replaces the pending alerts with ones worked out from the saved forecasts.
     * Does nothing visible when alerts are off or not allowed. Returns the plan.
     */
    suspend fun reschedule(context: Context, now: Double = nowSeconds()): List<Alert> {
        val app = context.applicationContext as BiteCurveApp
        cancelAll(context)
        if (!app.prefs.alertsEnabled.value || !isAuthorized(context)) return emptyList()
        val inputs = DayOutlooks.inputs(app.store.data.value.spots, app.forecasts)
        val days = DayOutlooks.compute(inputs, horizon(app.entitlements.isPro.value), now)
        val wording = object : Wording {
            override fun clock(time: Double, zone: ZoneId) = clock(context, time, zone)
            override fun startsInAnHour(range: String, index: Int) =
                context.getString(R.string.best_window_starts_in_an_hour_x_bite_index_x, range, index)
            override fun tomorrowTitle() = context.getString(R.string.tomorrow_looks_good_for_fishing)
            override fun tomorrowBody(spot: String, index: Int, range: String) =
                context.getString(R.string.x_bite_index_x_best_x, spot, index, range)
        }
        val plan = plan(inputs, days, app.prefs.alertThreshold.value, now, wording).take(maxPending)
        Log.i("BiteCurve", "scheduling ${plan.size} bite alerts, first: ${plan.firstOrNull()?.let { "${Instant.ofEpochSecond(it.fireDate.toLong())} ${it.title} | ${it.body}" } ?: "-"}")
        val alarms = context.getSystemService(AlarmManager::class.java)
        plan.forEachIndexed { code, alert ->
            // Inexact on purpose: within a few minutes is fine an hour ahead, and it needs
            // no "alarms and reminders" permission.
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, (alert.fireDate * 1000).toLong(), pending(context, code, alert))
        }
        app.prefs.pendingAlertCount = plan.size
        return plan
    }

    fun show(context: Context, code: Int, title: String, body: String) {
        if (!isAuthorized(context)) return
        val open = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_stat_fish)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        try {
            NotificationManagerCompat.from(context).notify(1000 + code, notification)
        } catch (e: SecurityException) {
            Log.i("BiteCurve", "notification not allowed")
        }
    }
}

class AlertReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val title = intent.getStringExtra("title") ?: return
        BiteAlerts.show(context, intent.getIntExtra("code", 0), title, intent.getStringExtra("body") ?: "")
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val result = goAsync()
        CoroutineScope(Dispatchers.Default).launch {
            try {
                BiteAlerts.reschedule(context)
            } finally {
                result.finish()
            }
        }
    }
}
