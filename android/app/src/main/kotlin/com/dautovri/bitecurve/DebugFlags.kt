package com.dautovri.bitecurve

import android.content.Intent
import com.dautovri.bitecurve.alerts.BiteAlerts
import kotlinx.coroutines.launch
import com.dautovri.bitecurve.core.Species
import com.dautovri.bitecurve.core.WaterType
import com.dautovri.bitecurve.data.Spot
import com.dautovri.bitecurve.data.Trip
import com.dautovri.bitecurve.data.nowSeconds

/**
 * Launch extras for UI checks, screenshots and failure drills, the counterpart of the iOS
 * app's `-BC…` launch arguments. Read in debug builds only (see `MainActivity`):
 *
 *   adb shell am start -n com.dautovri.bitecurve/.MainActivity --ez BCPro true \
 *       --ez BCSeedSpots true --ez BCSkipWelcome true --es BCAPIBase http://10.255.255.1
 *
 * - `BCPro`: unlocks Pro.
 * - `BCAPIBase`: another host for the worker (an unroutable one, or a local server answering 503).
 * - `BCSeedSpots`: adds three sample spots and a short trip log.
 * - `BCSkipWelcome`: keeps the welcome screen away.
 * - `BCSamplePlans`: the paywall shows made-up plans instead of asking Google Play (nothing can be bought).
 * - `BCAlertNow`: shows the next planned bite alert at once, to see it without waiting for it.
 * - `BCSisterApp`: shows the Houby cards while `SisterApp.IS_LIVE` is false.
 * - `BCHoubyAnyWindow`: any window counts as good for the one-time Houby card.
 */
object DebugFlags {
    var skipWelcome = false
        private set
    var samplePlans = false
        private set

    fun apply(app: BiteCurveApp, intent: Intent?) {
        val extras = intent?.extras ?: return
        if (extras.containsKey("BCPro")) app.entitlements.debugPro = extras.getBoolean("BCPro")
        if (extras.containsKey("BCAPIBase")) app.apiBaseOverride = extras.getString("BCAPIBase")?.takeIf { it.isNotBlank() }
        if (extras.containsKey("BCSkipWelcome")) skipWelcome = extras.getBoolean("BCSkipWelcome")
        if (extras.containsKey("BCSisterApp")) com.dautovri.bitecurve.ui.SisterApp.debugForceLive = extras.getBoolean("BCSisterApp")
        if (extras.containsKey("BCHoubyAnyWindow")) com.dautovri.bitecurve.ui.SisterApp.debugAnyWindow = extras.getBoolean("BCHoubyAnyWindow")
        if (extras.containsKey("BCSamplePlans")) samplePlans = extras.getBoolean("BCSamplePlans")
        if (extras.getBoolean("BCAlertNow")) {
            app.scope.launch {
                BiteAlerts.reschedule(app).firstOrNull()?.let { BiteAlerts.show(app, 99, it.title, it.body) }
            }
        }
        // Next to whatever is saved already, once.
        if (extras.getBoolean("BCSeedSpots") && app.store.data.value.spots.none { it.name == "Lake Minnetonka" }) seed(app)
    }

    private fun seed(app: BiteCurveApp) {
        val minnetonka = Spot(name = "Lake Minnetonka", latitude = 44.933, longitude = -93.563, waterRaw = WaterType.WARM_FRESHWATER.raw, speciesRaw = Species.WALLEYE.raw)
        val fork = Spot(name = "Lake Fork", latitude = 32.84, longitude = -95.58, waterRaw = WaterType.WARM_FRESHWATER.raw, speciesRaw = Species.LARGEMOUTH_BASS.raw, createdAt = nowSeconds() + 1)
        val taneycomo = Spot(name = "Lake Taneycomo", latitude = 36.66, longitude = -93.23, waterRaw = WaterType.COLD_FRESHWATER.raw, speciesRaw = Species.RAINBOW_TROUT.raw, createdAt = nowSeconds() + 2)
        listOf(minnetonka, fork, taneycomo).forEach(app.store::addSpot)
        val day = 86_400.0
        for ((spot, daysAgo, hours, fish) in listOf(
            Seed(minnetonka, 2.0, 3.0, 4), Seed(minnetonka, 9.0, 2.5, 0), Seed(fork, 16.0, 3.0, 0), Seed(fork, 5.0, 4.0, 6), Seed(taneycomo, 12.0, 3.5, 2),
        )) {
            val start = nowSeconds() - daysAgo * day
            // Timed fish and a forecast record, so the forecast check has something to show.
            val strong = fish > 0
            app.store.addTrip(
                Trip(
                    spotId = spot.id, startedAt = start, endedAt = start + hours * 3600, catchCount = fish,
                    catchTimes = (0 until fish).map { start + (it + 0.5) / maxOf(1, fish) * hours * 3600 },
                    bandHours = if (strong) listOf(0.0, 0.5, hours * 0.4, hours * 0.6 - 0.5) else listOf(hours * 0.6, hours * 0.4, 0.0, 0.0),
                    bandCatches = if (strong) listOf(0, 0, fish / 3, fish - fish / 3) else listOf(0, 0, 0, 0),
                    forecastIndex = if (strong) 64.0 else 31.0,
                    expectedCatch = 0.5 * hours,
                ),
            )
        }
    }

    private data class Seed(val spot: Spot, val daysAgo: Double, val hours: Double, val fish: Int)
}
