package com.dautovri.bitecurve.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Eco
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.dautovri.bitecurve.BuildConfig
import com.dautovri.bitecurve.R

/**
 * Houby, the developer's mushroom forecast app: a card in Settings, and a one-time card on a
 * spot's forecast on a strong bite day. Tapping opens its Google Play listing. Nothing is
 * counted or sent: the launch count and the "done" flag stay in this phone's preferences, and
 * the only tag is the Play referrer, which Play Console uses to count installs from here.
 */
object SisterApp {
    /**
     * Flip to true once Houby is in Google Play production. Until then its listing is not
     * public (a Play link would 404), so neither card shows.
     */
    const val IS_LIVE = false

    const val PACKAGE = "com.ruslandautov.houby"
    private const val REFERRER = "utm_source%3Dbitecurve-app%26utm_medium%3Dxpromo"

    /** The one-time card waits for this launch or later, never the first run. */
    const val FIRST_OFFER_LAUNCH = 3

    /** A good window: the bite alerts' "Strong bite" bar (their default), as on iOS. */
    const val GOOD_WINDOW_INDEX = 65.0

    /** Debug builds only: the launch extra `BCSisterApp` shows the cards while [IS_LIVE] is false. */
    var debugForceLive = false

    /** Debug builds only: the launch extra `BCHoubyAnyWindow` lets any window count as good. */
    var debugAnyWindow = false

    val isEnabled: Boolean get() = IS_LIVE || (BuildConfig.DEBUG && debugForceLive)

    val marketUri: String = "market://details?id=$PACKAGE&referrer=$REFERRER"
    val webUri: String = "https://play.google.com/store/apps/details?id=$PACKAGE&referrer=$REFERRER"

    /**
     * Whether a spot's forecast shows the one-time card: Houby is on Play, the day's best
     * window reaches the strong-bite bar, from the third launch on, after the welcome screen,
     * and never again once it was tapped or dismissed (or the Settings card was tapped).
     */
    fun offersOnSpot(live: Boolean, windowIndex: Double?, launches: Int, didOnboard: Boolean, done: Boolean, anyWindow: Boolean = false): Boolean {
        if (!live || windowIndex == null || done || !didOnboard) return false
        return launches >= FIRST_OFFER_LAUNCH && (anyWindow || windowIndex >= GOOD_WINDOW_INDEX)
    }

    /** Google Play's page for Houby; the web page when the Play Store app is missing. */
    fun openListing(context: Context) {
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(marketUri)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: ActivityNotFoundException) {
            open(context, webUri)
        }
    }
}

/** Icon, name and one line about Houby. With [onDismiss], a close button hides it for good. */
@Composable
fun HoubyPromoCard(onOpen: () -> Unit, onDismiss: (() -> Unit)? = null) {
    val colors = Theme.colors
    val hint = stringResource(R.string.sister_app_open_hint)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            Modifier.weight(1f).clip(RoundedCornerShape(10.dp)).clickable(onClickLabel = hint, role = Role.Button, onClick = onOpen),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // A forest-green tile with a leaf stands in for Houby's icon (no copied artwork).
            Box(Modifier.size(44.dp).background(Color(0xFF3D7345), RoundedCornerShape(11.dp)), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Eco, null, tint = Color.White)
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("Houby", style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold, color = colors.primaryText)
                Text(stringResource(R.string.sister_app_tagline), style = MaterialTheme.typography.bodyMedium, color = colors.secondaryText)
            }
            if (onDismiss == null) Icon(Icons.Filled.ChevronRight, null, tint = colors.secondaryText)
        }
        if (onDismiss != null) {
            IconButton(onDismiss) {
                Box(Modifier.size(30.dp).background(colors.well, CircleShape), contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Close, stringResource(R.string.sister_app_hide), Modifier.size(16.dp), tint = colors.secondaryText)
                }
            }
        }
    }
}

/** The one-time card on a spot's forecast, with its heading. */
@Composable
fun HoubySpotPromo(onOpen: () -> Unit, onDismiss: () -> Unit) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        CardHeader(stringResource(R.string.more_from_the_developer))
        BiteCard(padding = 12.dp) { HoubyPromoCard(onOpen, onDismiss) }
    }
}
