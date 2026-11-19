package com.dautovri.bitecurve

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.automirrored.filled.ShowChart
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.dautovri.bitecurve.alerts.BiteAlerts
import com.dautovri.bitecurve.data.nowSeconds
import com.dautovri.bitecurve.ui.BiteTheme
import com.dautovri.bitecurve.ui.ForecastScreen
import com.dautovri.bitecurve.ui.HowItWorksScreen
import com.dautovri.bitecurve.ui.LogScreen
import com.dautovri.bitecurve.ui.MapRequest
import com.dautovri.bitecurve.ui.MapScreen
import com.dautovri.bitecurve.ui.PaywallContext
import com.dautovri.bitecurve.ui.PaywallDialog
import com.dautovri.bitecurve.ui.PlannerScreen
import com.dautovri.bitecurve.ui.SettingsScreen
import com.dautovri.bitecurve.ui.SpotDetailScreen
import com.dautovri.bitecurve.ui.Theme
import com.dautovri.bitecurve.ui.WelcomeChoice
import com.dautovri.bitecurve.ui.WelcomeScreen
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as BiteCurveApp
        if (BuildConfig.DEBUG) DebugFlags.apply(app, intent)
        setContent { BiteTheme { Root() } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (BuildConfig.DEBUG) DebugFlags.apply(application as BiteCurveApp, intent)
    }
}

// Tabs: Forecast, Planner, Map, Log. Settings opens from the gear on the Forecast tab.
private const val mapTab = 2
private const val logTab = 3

/** A screen pushed over the tabs. */
private sealed interface Pushed {
    data class Detail(val spotId: String, val day: Double?) : Pushed
    data object Settings : Pushed
    data object HowItWorks : Pushed
}

@Composable
private fun Root() {
    val app = com.dautovri.bitecurve.ui.app()
    val colors = Theme.colors
    var tab by rememberSaveable { mutableIntStateOf(0) }
    val stack = remember { mutableStateListOf<Pushed>() }
    var paywall by remember { mutableStateOf<PaywallContext?>(null) }
    var mapRequest by remember { mutableStateOf<MapRequest?>(null) }
    val didOnboard by app.prefs.didOnboard.collectAsStateWithLifecycle()
    var showWelcome by remember { mutableStateOf(false) }

    // A first launch with nothing saved gets the welcome screen; anyone who already has
    // spots never sees it.
    LaunchedEffect(Unit) {
        if (!app.prefs.didOnboard.value) {
            if (app.store.data.value.spots.isEmpty() && !DebugFlags.skipWelcome) showWelcome = true else app.prefs.setDidOnboard(true)
        }
    }
    // Refresh saved forecasts whenever the app comes forward, at most hourly.
    LifecycleResumeEffect(Unit) {
        app.scope.launch {
            if (nowSeconds() - app.forecasts.lastPrefetch.value > 3600) app.refresh()
            // No download due, but time has passed: lay the alerts out again from now.
            else BiteAlerts.reschedule(app)
        }
        app.scope.launch { app.entitlements.refresh() }
        onPauseOrDispose { }
    }

    BackHandler(stack.isNotEmpty()) { stack.removeAt(stack.lastIndex) }

    if (showWelcome && !didOnboard) {
        WelcomeScreen { choice ->
            app.prefs.setDidOnboard(true)
            showWelcome = false
            when (choice) {
                WelcomeChoice.LOCATE -> { mapRequest = MapRequest.LOCATE; tab = mapTab }
                WelcomeChoice.SEARCH -> { mapRequest = MapRequest.SEARCH; tab = mapTab }
                WelcomeChoice.SKIP -> {}
            }
        }
        return
    }

    val top = stack.lastOrNull()
    Box(Modifier.fillMaxSize()) {
        when (top) {
            is Pushed.Detail -> SpotDetailScreen(
                top.spotId, top.day, onBack = { stack.remove(top) }, onPaywall = { paywall = it },
                // The running trip lives on the Log tab.
                onTripStarted = { stack.clear(); tab = logTab },
            )
            Pushed.Settings -> SettingsScreen(onBack = { stack.remove(top) }, onPaywall = { paywall = it }, onHowItWorks = { stack.add(Pushed.HowItWorks) })
            Pushed.HowItWorks -> HowItWorksScreen { stack.remove(top) }
            null -> Scaffold(
                containerColor = colors.background,
                bottomBar = {
                    NavigationBar(containerColor = colors.card) {
                        val tabs = listOf(
                            R.string.forecast to Icons.AutoMirrored.Filled.ShowChart, R.string.planner to Icons.Filled.CalendarMonth,
                            R.string.map to Icons.Filled.Map, R.string.log to Icons.AutoMirrored.Filled.MenuBook,
                        )
                        tabs.forEachIndexed { i, (title, icon) ->
                            NavigationBarItem(
                                selected = tab == i, onClick = { tab = i },
                                icon = { Icon(icon, null) }, label = { Text(stringResource(title), maxLines = 1) },
                                colors = NavigationBarItemDefaults.colors(
                                    selectedIconColor = colors.accent, selectedTextColor = colors.accent, indicatorColor = colors.accent.copy(alpha = 0.16f),
                                    unselectedIconColor = colors.secondaryText, unselectedTextColor = colors.secondaryText,
                                ),
                            )
                        }
                    }
                },
            ) { padding ->
                // The tab bar already covers the system bar at the bottom; the screens inside must not pad for it again.
                Box(Modifier.fillMaxSize().padding(bottom = padding.calculateBottomPadding()).consumeWindowInsets(WindowInsets.navigationBars)) {
                    when (tab) {
                        0 -> ForecastScreen(onAddSpot = { tab = mapTab }, onOpen = { stack.add(Pushed.Detail(it.id, null)) }, onSettings = { stack.add(Pushed.Settings) })
                        1 -> PlannerScreen(onOpen = { spot, day -> stack.add(Pushed.Detail(spot.id, day)) }, onPaywall = { paywall = it })
                        mapTab -> MapScreen(
                            mapRequest, onRequestHandled = { mapRequest = null },
                            // The first spot: straight to its forecast, curve and all.
                            onFirstSpot = { spot -> tab = 0; stack.add(Pushed.Detail(spot.id, null)) },
                            onPaywall = { paywall = it },
                        )
                        else -> LogScreen(onPaywall = { paywall = it })
                    }
                }
            }
        }
    }
    paywall?.let { context -> PaywallDialog(context) { paywall = null } }
}
