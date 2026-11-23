package com.dautovri.bitecurve.data

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** The app's few switches, kept in SharedPreferences and observable from Compose. */
class Prefs(context: Context) {
    private val store: SharedPreferences = context.getSharedPreferences("bitecurve", Context.MODE_PRIVATE)

    private val onboarded = MutableStateFlow(store.getBoolean("didOnboard", false))
    private val alerts = MutableStateFlow(store.getBoolean("biteAlertsEnabled", false))
    private val threshold = MutableStateFlow(store.getFloat("biteAlertThreshold", 65f).toDouble())

    /** Set once the welcome screen was answered (or was never needed). */
    val didOnboard: StateFlow<Boolean> = onboarded
    val alertsEnabled: StateFlow<Boolean> = alerts
    /** Alerts are given for windows at or above this index: 50 or 65. */
    val alertThreshold: StateFlow<Double> = threshold

    fun setDidOnboard(value: Boolean) {
        store.edit().putBoolean("didOnboard", value).apply()
        onboarded.value = value
    }

    fun setAlertsEnabled(value: Boolean) {
        store.edit().putBoolean("biteAlertsEnabled", value).apply()
        alerts.value = value
    }

    fun setAlertThreshold(value: Double) {
        store.edit().putFloat("biteAlertThreshold", value.toFloat()).apply()
        threshold.value = value
    }

    /** The card on the Forecast tab that offers bite alerts was answered, either way. */
    var alertsPromptAnswered: Boolean
        get() = store.getBoolean("alertsPromptAnswered", false)
        set(value) = store.edit().putBoolean("alertsPromptAnswered", value).apply()

    /** The Pro card in the trip log was put away. */
    var logProCardDismissed: Boolean
        get() = store.getBoolean("logProCardDismissed", false)
        set(value) = store.edit().putBoolean("logProCardDismissed", value).apply()

    /** Times the app was opened (this phone only); the Houby card waits for the third. */
    val launchCount: Int get() = store.getInt("launchCount", 0)

    fun recordLaunch() = store.edit().putInt("launchCount", launchCount + 1).apply()

    private val houbyDone = MutableStateFlow(store.getBoolean("houbyPromoDone", false))

    /** The one-time Houby card was tapped or dismissed, or the Settings card was tapped. */
    val houbyPromoDone: StateFlow<Boolean> = houbyDone

    fun setHoubyPromoDone() {
        store.edit().putBoolean("houbyPromoDone", true).apply()
        houbyDone.value = true
    }

    /** Request codes of the alarms laid out last time, so they can be cancelled. */
    var pendingAlertCount: Int
        get() = store.getInt("pendingAlertCount", 0)
        set(value) = store.edit().putInt("pendingAlertCount", value).apply()
}
