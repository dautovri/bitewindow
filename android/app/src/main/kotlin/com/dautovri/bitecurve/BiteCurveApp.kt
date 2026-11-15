package com.dautovri.bitecurve

import android.app.Application
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import com.dautovri.bitecurve.alerts.BiteAlerts
import com.dautovri.bitecurve.billing.Entitlements
import com.dautovri.bitecurve.data.ForecastService
import com.dautovri.bitecurve.data.Prefs
import com.dautovri.bitecurve.data.Store
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import java.io.File
import java.util.concurrent.TimeUnit

class BiteCurveApp : Application() {
    lateinit var store: Store
    lateinit var forecasts: ForecastService
    lateinit var prefs: Prefs
    lateinit var entitlements: Entitlements

    /** Work that must outlive the screen that started it (downloads, ending a trip). */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /**
     * Debug builds only: another host for the worker, set by the launch extra `BCAPIBase`
     * (failure drills). Lives for this process only.
     */
    @Volatile var apiBaseOverride: String? = null

    override fun onCreate() {
        super.onCreate()
        store = Store.open(this)
        prefs = Prefs(this)
        forecasts = ForecastService(File(filesDir, "forecasts")) { apiBaseOverride ?: BuildConfig.API_BASE }
        entitlements = Entitlements(this, scope)
        BiteAlerts.createChannel(this)
        scheduleBackgroundRefresh()
    }

    /** Places to keep available offline: every saved spot. */
    fun places(): List<ForecastService.Place> =
        store.data.value.spots.map { ForecastService.Place(it.latitude, it.longitude, it.isSalt) }

    /** Downloads forecasts for all spots; alerts follow the newest forecast the phone has. */
    suspend fun refresh(): Pair<Int, Int> {
        val all = places()
        val saved = forecasts.prefetch(all)
        BiteAlerts.reschedule(this)
        return saved to all.size
    }

    /**
     * Asks Android for a refresh about every six hours while there is a connection. Android
     * decides when it runs; opening the app with signal is the reliable path.
     */
    private fun scheduleBackgroundRefresh() {
        val request = PeriodicWorkRequestBuilder<RefreshWorker>(6, TimeUnit.HOURS)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(this).enqueueUniquePeriodicWork("refresh", ExistingPeriodicWorkPolicy.KEEP, request)
    }
}
