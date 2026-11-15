package com.dautovri.bitecurve.ui

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.icu.text.MeasureFormat
import android.icu.util.Measure
import android.icu.util.MeasureUnit
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ShowChart
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.Waves
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.dautovri.bitecurve.R
import com.dautovri.bitecurve.alerts.BiteAlerts
import com.dautovri.bitecurve.billing.Entitlements
import com.android.billingclient.api.ProductDetails
import kotlinx.coroutines.launch
import java.time.Period
import java.util.Locale

/** Pages linked from Settings and the paywall; the same ones the iOS app links. */
object Legal {
    const val support = "https://apps.dautov.dev/bitecurve/"
    const val privacy = "https://apps.dautov.dev/bitecurve/privacy/"
}

private fun open(context: Context, url: String) {
    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
}

private tailrec fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(onPaywall: () -> Unit, onHowItWorks: () -> Unit) {
    val app = app()
    val context = LocalContext.current
    val colors = Theme.colors
    val scope = rememberCoroutineScope()
    val isPro by app.entitlements.isPro.collectAsStateWithLifecycle()
    val alertsOn by app.prefs.alertsEnabled.collectAsStateWithLifecycle()
    val threshold by app.prefs.alertThreshold.collectAsStateWithLifecycle()
    val lastPrefetch by app.forecasts.lastPrefetch.collectAsStateWithLifecycle()
    /** Android refused notifications: the switch goes back off and the footer says where to allow them. */
    var alertsDenied by remember { mutableStateOf(false) }
    var downloading by remember { mutableStateOf(false) }
    var downloadResult by remember { mutableStateOf<String?>(null) }

    fun enableAlerts() {
        if (BiteAlerts.isAuthorized(context)) {
            alertsDenied = false
            app.prefs.setAlertsEnabled(true)
            app.scope.launch { BiteAlerts.reschedule(app) }
        } else {
            alertsDenied = true
            app.prefs.setAlertsEnabled(false)
        }
    }
    val askNotifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { enableAlerts() }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.settings), fontWeight = FontWeight.Bold) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.background),
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
            Column(Modifier.widthIn(max = Theme.readableWidth).padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(Theme.gap)) {
                if (isPro) {
                    BiteCard {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Icon(Icons.Filled.Verified, null, tint = colors.accent)
                            Text(stringResource(R.string.pro_is_active), style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold, color = colors.primaryText)
                        }
                    }
                } else {
                    ProBannerCard(onPaywall)
                }

                Section(
                    footer = stringResource(if (alertsDenied) R.string.notifications_are_off_for_bitecurve_allow_them_i else R.string.a_notification_an_hour_before_a_good_window_at_o),
                ) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.bite_alerts), Modifier.weight(1f), color = colors.primaryText)
                        Switch(alertsOn, { on ->
                            if (!on) {
                                app.prefs.setAlertsEnabled(false)
                                BiteAlerts.cancelAll(app)
                            } else if (Build.VERSION.SDK_INT >= 33 && !BiteAlerts.isAuthorized(context)) {
                                askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
                            } else {
                                enableAlerts()
                            }
                        })
                    }
                    if (alertsOn) {
                        Hairline()
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text(stringResource(R.string.alert_me_for), Modifier.weight(1f), color = colors.primaryText)
                            val options = listOf(50.0 to stringResource(R.string.above_average_50), 65.0 to stringResource(R.string.strong_bite_65))
                            MenuPicker(stringResource(R.string.alert_me_for), options.first { it.first == if (threshold < 60) 50.0 else 65.0 }.second, options) { picked ->
                                app.prefs.setAlertThreshold(picked)
                                app.scope.launch { BiteAlerts.reschedule(app) }
                            }
                        }
                    }
                }

                Section(
                    header = stringResource(R.string.offline),
                    footer = stringResource(R.string.forecasts_for_your_spots_are_saved_on_this_devic),
                ) {
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).clickable(enabled = !downloading) {
                            downloading = true
                            // In the app's scope: leaving Settings must not stop the download.
                            app.scope.launch {
                                val (saved, total) = app.refresh()
                                downloadResult = context.getString(R.string.saved_x_of_x_spots, saved, total)
                                downloading = false
                            }
                        }.padding(vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        if (downloading) {
                            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                            Text(stringResource(R.string.downloading), color = colors.secondaryText)
                        } else {
                            Icon(Icons.Filled.Download, null, tint = colors.accent)
                            Text(stringResource(R.string.download_forecasts_for_all_spots), color = colors.accent)
                        }
                    }
                    downloadResult?.let { Text(it, color = colors.secondaryText) }
                    if (lastPrefetch > 0) Text(stringResource(R.string.last_download_x, relative(lastPrefetch)), color = colors.secondaryText)
                }

                Section {
                    LinkRow(stringResource(R.string.how_the_score_works), onHowItWorks)
                }

                Section {
                    LinkRow(stringResource(R.string.support)) { open(context, Legal.support) }
                    Hairline()
                    LinkRow(stringResource(R.string.privacy_policy)) { open(context, Legal.privacy) }
                }
            }
        }
    }
}

@Composable
private fun Section(header: String? = null, footer: String? = null, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (header != null) CardHeader(header)
        BiteCard { Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { content() } }
        if (footer != null) Text(footer, Modifier.padding(horizontal = 4.dp), style = MaterialTheme.typography.bodySmall, color = Theme.colors.secondaryText)
    }
}

@Composable
private fun LinkRow(title: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).clickable(onClick = onClick).padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f), color = Theme.colors.primaryText)
        Icon(Icons.Filled.ChevronRight, null, tint = Theme.colors.secondaryText)
    }
}

@Composable
private fun ProBannerCard(onSeePlans: () -> Unit) {
    val colors = Theme.colors
    val shape = RoundedCornerShape(Theme.cardRadius)
    Column(
        Modifier.fillMaxWidth().background(colors.deepWater, shape).border(1.dp, colors.stroke, shape).padding(Theme.cardPadding),
        verticalArrangement = Arrangement.spacedBy(Theme.gap),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            FishIcon(Modifier.size(24.dp), Color(0xFF2DD4BF))
            Text(stringResource(R.string.bitecurve_pro), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = Color.White)
        }
        Text(stringResource(R.string.hourly_bite_curve_tide_curve_expected_catch_tune), style = MaterialTheme.typography.bodyMedium, color = Color.White.copy(alpha = 0.85f))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            for (icon in listOf(Icons.AutoMirrored.Filled.ShowChart, Icons.Filled.Waves, FishGlyph, Icons.Filled.CalendarMonth)) {
                Box(Modifier.size(36.dp).background(Color.White.copy(alpha = 0.1f), RoundedCornerShape(Theme.wellRadius)), contentAlignment = Alignment.Center) {
                    Icon(icon, null, Modifier.size(18.dp), tint = Color(0xFF2DD4BF))
                }
            }
        }
        Button(onSeePlans, Modifier.fillMaxWidth()) { Text(stringResource(R.string.see_pro_plans), fontWeight = FontWeight.SemiBold) }
    }
}

/** "1 month", "7 days" in the phone's language, from a billing period such as P1M. */
private fun periodText(iso: String): String {
    val period = runCatching { Period.parse(iso) }.getOrNull() ?: return iso
    val (count, unit) = when {
        period.years > 0 -> period.years to MeasureUnit.YEAR
        period.months > 0 -> period.months to MeasureUnit.MONTH
        period.days % 7 == 0 && period.days > 0 -> period.days / 7 to MeasureUnit.WEEK
        else -> period.days to MeasureUnit.DAY
    }
    return MeasureFormat.getInstance(Locale.getDefault(), MeasureFormat.FormatWidth.WIDE).format(Measure(count, unit))
}

/** A plan's price as Play gives it, phase by phase: "7 days: Free → 1 year: €39.99". */
private fun priceText(phases: List<ProductDetails.PricingPhase>): String =
    phases.joinToString("  →  ") { "${periodText(it.billingPeriod)}: ${it.formattedPrice}" }

/**
 * What Pro adds and the plans Play offers. When the plans cannot be loaded (no network, no
 * Play Store on the device) it says so, with a retry and "restore purchases".
 */
@Composable
fun PaywallDialog(onDismiss: () -> Unit) {
    val app = app()
    val context = LocalContext.current
    val colors = Theme.colors
    val scope = rememberCoroutineScope()
    val isPro by app.entitlements.isPro.collectAsStateWithLifecycle()
    var attempt by remember { mutableIntStateOf(0) }
    var plans by remember { mutableStateOf<List<Entitlements.Plan>?>(null) }
    var loadFailed by remember { mutableStateOf(false) }

    LaunchedEffect(isPro) { if (isPro) onDismiss() }
    LaunchedEffect(attempt) {
        loadFailed = false
        plans = app.entitlements.plans()
        loadFailed = plans == null
    }

    Dialog(onDismiss, DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(colors.background).safeDrawingPadding()) {
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Spacer(Modifier.height(24.dp))
                FishIcon(Modifier.size(44.dp))
                Text(stringResource(R.string.bitecurve_pro), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = colors.primaryText)
                // Scannable rows instead of a paragraph.
                Column(Modifier.widthIn(max = Theme.readableWidth), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    ProBenefit(Icons.AutoMirrored.Filled.ShowChart, stringResource(R.string.hourly_bite_and_tide_curves))
                    ProBenefit(Icons.Filled.CalendarMonth, stringResource(R.string.s_10_day_outlook_for_every_spot))
                    ProBenefit(FishGlyph, stringResource(R.string.expected_catch_tuned_to_your_log))
                    ProBenefit(Icons.Filled.Place, stringResource(R.string.unlimited_spots))
                }
                Spacer(Modifier.height(4.dp))
                val loaded = plans
                when {
                    loaded != null -> Column(Modifier.widthIn(max = Theme.readableWidth), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        for (plan in loaded) {
                            BiteCard(onClick = { context.activity()?.let { app.entitlements.buy(it, plan) } }) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                        Text(periodText(plan.phases.last().billingPeriod), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = colors.primaryText)
                                        Text(priceText(plan.phases), style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText)
                                    }
                                    Icon(Icons.Filled.ChevronRight, null, tint = colors.accent)
                                }
                            }
                        }
                    }
                    loadFailed -> {
                        Text(stringResource(R.string.could_not_load_subscription_plans), color = colors.secondaryText, textAlign = TextAlign.Center)
                        Button({ attempt += 1 }) { Text(stringResource(R.string.try_again)) }
                    }
                    else -> CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 3.dp)
                }
                TextButton({ scope.launch { app.entitlements.refresh() } }) { Text(stringResource(R.string.restore_purchases)) }
                TextButton({ open(context, Legal.privacy) }) { Text(stringResource(R.string.privacy_policy), style = MaterialTheme.typography.bodySmall) }
            }
            IconButton(onDismiss, Modifier.align(Alignment.TopEnd).padding(8.dp)) {
                Icon(Icons.Filled.Close, stringResource(R.string.close), tint = colors.secondaryText)
            }
        }
    }
}

/** One line of what Pro adds, on the paywall. */
@Composable
private fun ProBenefit(icon: ImageVector, text: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(icon, null, Modifier.size(24.dp), tint = Theme.colors.accent)
        Text(text, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium, color = Theme.colors.primaryText)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HowItWorksScreen(onBack: () -> Unit) {
    val colors = Theme.colors
    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.how_the_score_works)) },
                navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.close)) } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.background),
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
            Column(Modifier.widthIn(max = Theme.readableWidth).padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(Theme.gap)) {
                Section { Text(stringResource(R.string.the_bite_index_combines_light_water_temperature), color = colors.primaryText) }
                Section(header = stringResource(R.string.what_the_evidence_supports)) {
                    Text(stringResource(R.string.low_light_at_dawn_and_dusk_suitable_water_temper), color = colors.primaryText)
                    Hairline()
                    Text(stringResource(R.string.barometric_pressure_is_used_only_as_a_sign_of_pa), color = colors.primaryText)
                    Hairline()
                    Text(stringResource(R.string.solunar_tables_failed_to_predict_trout_catch_rat), color = colors.primaryText)
                }
                Section(header = stringResource(R.string.weights)) {
                    Text(stringResource(R.string.the_starting_weights_are_estimates_your_trip_log), color = colors.primaryText)
                }
            }
        }
    }
}
