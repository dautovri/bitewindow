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

    /** Offer the Pro trial once, after the first spot has a forecast. */
    var offerTrialAfterFirstSpot: Boolean
        get() = store.getBoolean("offerTrialAfterFirstSpot", false)
        set(value) = store.edit().putBoolean("offerTrialAfterFirstSpot", value).apply()

    /** Request codes of the alarms laid out last time, so they can be cancelled. */
    var pendingAlertCount: Int
        get() = store.getInt("pendingAlertCount", 0)
        set(value) = store.edit().putInt("pendingAlertCount", value).apply()
}
