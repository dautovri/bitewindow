package com.dautovri.bitecurve.ui

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.dautovri.bitecurve.R
import com.dautovri.bitecurve.alerts.BiteAlerts
import kotlinx.coroutines.launch

/**
 * Returns the action that turns bite alerts on, asking Android for notifications first where
 * it must. `onResult` hears whether they are on now; false means Android refused.
 */
@Composable
fun rememberTurnOnAlerts(onResult: (Boolean) -> Unit): () -> Unit {
    val app = app()
    val context = LocalContext.current
    fun finish() {
        val allowed = BiteAlerts.isAuthorized(context)
        // Decided, here or in Settings: the card on the Forecast tab has nothing left to ask.
        app.prefs.alertsPromptAnswered = true
        app.prefs.setAlertsEnabled(allowed)
        if (allowed) app.scope.launch { BiteAlerts.reschedule(app) }
        onResult(allowed)
    }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { finish() }
    return {
        if (Build.VERSION.SDK_INT >= 33 && !BiteAlerts.isAuthorized(context)) ask.launch(Manifest.permission.POST_NOTIFICATIONS) else finish()
    }
}

/**
 * Offers bite alerts once, on the Forecast tab, to someone who has a spot and has not switched
 * them on. Not a paywall: alerts for today and tomorrow are free.
 */
@Composable
fun AlertsPromptCard(onAnswered: () -> Unit) {
    val app = app()
    val colors = Theme.colors
    fun answered() {
        app.prefs.alertsPromptAnswered = true
        onAnswered()
    }
    // Refused by Android: the card goes away all the same; Settings says where to allow them.
    val turnOn = rememberTurnOnAlerts { answered() }
    BiteCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(Icons.Filled.Notifications, null, Modifier.size(22.dp), tint = colors.accent)
                Text(stringResource(R.string.alerts_card_title), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = colors.primaryText)
            }
            Text(stringResource(R.string.alerts_card_body), style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(turnOn) { Text(stringResource(R.string.turn_on_bite_alerts), fontWeight = FontWeight.SemiBold) }
                TextButton({ answered() }) { Text(stringResource(R.string.not_now)) }
            }
        }
    }
}
