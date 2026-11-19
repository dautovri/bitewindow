package com.dautovri.bitecurve.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.icu.text.MeasureFormat
import android.icu.util.Measure
import android.icu.util.MeasureUnit
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ShowChart
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.RadioButtonChecked
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.dautovri.bitecurve.DebugFlags
import com.dautovri.bitecurve.R
import com.dautovri.bitecurve.billing.Entitlements
import java.time.Period
import java.util.Locale
import kotlin.math.roundToInt

/** Pages linked from Settings and the paywall; the same ones the iOS app links. */
object Legal {
    const val support = "https://apps.dautov.dev/bitecurve/"
    const val privacy = "https://apps.dautov.dev/bitecurve/privacy/"
    /** Where Google Play lets a subscriber change or cancel this subscription. */
    const val manageSubscription = "https://play.google.com/store/account/subscriptions?sku=${Entitlements.productId}&package=com.dautovri.bitecurve"
}

internal fun open(context: Context, url: String) {
    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
}

internal tailrec fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}

/** What the person tapped when the paywall opened; it words the offer for that. */
enum class PaywallContext {
    /** No particular feature: Settings, the trip log. */
    GENERAL,
    /** A locked day, in the planner or a spot's day strip. */
    DAYS,
    /** A locked weekend day while a strong bite is forecast for it. */
    WEEKEND,
    /** The hourly curve of a day other than today. */
    CURVE,
    /** The full factor breakdown or the expected catch. */
    FACTORS,
    /** A fourth spot. */
    SPOTS,
    /** Alerts further ahead than tomorrow. */
    ALERTS,
}

/** "1 month", "1 week" in the phone's language, from a billing period such as P1M. */
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

/** One choice on the paywall, in words: what it is, what it costs, how it renews, and how to buy it. */
private class OfferView(
    val title: String, val note: String?, val badge: String?, val price: String,
    /** What is charged, when, and how it ends. Shown above the button before any purchase starts. */
    val terms: String,
    val button: Int,
    val buy: (Activity) -> Unit,
)

private class Offers(val list: List<OfferView>, val spotsPackPrice: String?, val buySpotsPack: (Activity) -> Unit)

/** A subscription's charge and renewal in one sentence pair, from Play's own price and periods. */
private fun subscriptionTerms(context: Context, period: String, trialPeriod: String?, price: String, phases: String?): String {
    val trial = trialPeriod?.let { periodText(it) }
    val charge = phases ?: when (period) {
        "P1Y" -> if (trial != null) context.getString(R.string.x_free_then_x_per_year, trial, price) else context.getString(R.string.x_per_year, price)
        "P1M" -> if (trial != null) context.getString(R.string.x_free_then_x_per_month, trial, price) else context.getString(R.string.x_per_month, price)
        // A period this app does not sell today.
        else -> "${periodText(period)}: $price"
    }
    return "$charge ${context.getString(R.string.renews_until_cancelled)}"
}

private fun subscriptionOffer(context: Context, period: String, trialPeriod: String?, price: String, saving: Int?, phases: String?, buy: (Activity) -> Unit) = OfferView(
    title = periodText(period), note = null,
    badge = saving?.takeIf { period == "P1Y" }?.let { context.getString(R.string.save_x_percent, it) },
    price = price, terms = subscriptionTerms(context, period, trialPeriod, price, phases),
    // "Free trial" only when Play offers this account the trial.
    button = if (trialPeriod != null && phases == null) R.string.start_free_trial else R.string.subscribe, buy = buy,
)

private fun lifetimeOffer(context: Context, price: String, buy: (Activity) -> Unit) = OfferView(
    title = context.getString(R.string.lifetime), note = context.getString(R.string.one_time_purchase), badge = null, price = price,
    terms = context.getString(R.string.one_payment_of_x, price), button = R.string.buy_lifetime_access, buy = buy,
)

/** How much a year on the annual plan saves against twelve monthly payments, in percent. */
internal fun annualSaving(yearMicros: Long, monthMicros: Long): Int? =
    if (monthMicros <= 0) null else ((1 - yearMicros / (12.0 * monthMicros)) * 100).roundToInt().takeIf { it > 0 }

private fun offers(context: Context, entitlements: Entitlements, catalog: Entitlements.Catalog): Offers {
    val year = catalog.plans.firstOrNull { it.recurring.billingPeriod == "P1Y" }?.recurring
    val month = catalog.plans.firstOrNull { it.recurring.billingPeriod == "P1M" }?.recurring
    val saving = if (year != null && month != null && year.priceCurrencyCode == month.priceCurrencyCode) annualSaving(year.priceAmountMicros, month.priceAmountMicros) else null
    val list = catalog.plans.map { plan ->
        subscriptionOffer(
            context, plan.recurring.billingPeriod, plan.trial?.billingPeriod, plan.recurring.formattedPrice, saving,
            // Every phase as Play has it, for an offer the sentences above would misstate.
            plan.phases.joinToString("  →  ") { "${it.billingCycleCount.coerceAtLeast(1)} × ${periodText(it.billingPeriod)}: ${it.formattedPrice}" }.takeIf { !plan.isPlain },
        ) { entitlements.buy(it, plan) }
    } + listOfNotNull(catalog.lifetime?.let { product -> lifetimeOffer(context, product.oneTimePurchaseOfferDetails?.formattedPrice ?: "") { entitlements.buy(it, product) } })
    val pack = catalog.spotsPack
    return Offers(list, pack?.oneTimePurchaseOfferDetails?.formattedPrice) { activity -> pack?.let { entitlements.buy(activity, it) } }
}

/** Debug builds only (launch extra `BCSamplePlans`): made-up prices, to see the paywall without Google Play. Nothing can be bought. */
private fun sampleOffers(context: Context) = Offers(
    listOf(
        subscriptionOffer(context, "P1Y", "P1W", "€44.99", annualSaving(44_990_000, 8_990_000), null) {},
        subscriptionOffer(context, "P1M", null, "€8.99", null, null) {},
        lifetimeOffer(context, "€79.99") {},
    ),
    "€9.99",
) {}

/**
 * What Pro adds, worded for what was tapped, and what Play has on sale: pick a plan, read what
 * it costs and how it renews, then one button. When nothing can be loaded (no network, no Play
 * Store on the device) it says so, with a retry and "restore purchases".
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun PaywallDialog(context: PaywallContext, onDismiss: () -> Unit) {
    val app = app()
    val android = LocalContext.current
    val colors = Theme.colors
    val isPro by app.entitlements.isPro.collectAsStateWithLifecycle()
    val unlimitedSpots by app.entitlements.hasUnlimitedSpots.collectAsStateWithLifecycle()
    val pending by app.entitlements.purchasePending.collectAsStateWithLifecycle()
    var attempt by remember { mutableIntStateOf(0) }
    var offers by remember { mutableStateOf<Offers?>(null) }
    var loadFailed by remember { mutableStateOf(false) }
    var selected by remember { mutableIntStateOf(0) }

    // Bought what was asked for: nothing left to offer here.
    LaunchedEffect(isPro, unlimitedSpots) { if (isPro || (context == PaywallContext.SPOTS && unlimitedSpots)) onDismiss() }
    LaunchedEffect(attempt) {
        loadFailed = false
        offers = if (DebugFlags.samplePlans) sampleOffers(android) else app.entitlements.catalog()?.let { offers(android, app.entitlements, it) }
        loadFailed = offers == null
    }

    val (headline, sub) = when (context) {
        PaywallContext.GENERAL -> R.string.bitecurve_pro to null
        PaywallContext.DAYS -> R.string.paywall_headline_days to R.string.paywall_sub_days
        PaywallContext.WEEKEND -> R.string.a_strong_bite_is_forecast_this_weekend to R.string.paywall_sub_days
        PaywallContext.CURVE -> R.string.paywall_headline_curve to R.string.paywall_sub_curve
        PaywallContext.FACTORS -> R.string.paywall_headline_factors to R.string.paywall_sub_factors
        PaywallContext.SPOTS -> R.string.paywall_headline_spots to R.string.paywall_sub_spots
        PaywallContext.ALERTS -> R.string.paywall_headline_alerts to R.string.paywall_sub_alerts
    }

    Dialog(onDismiss, DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(colors.background).safeDrawingPadding()) {
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 16.dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Spacer(Modifier.height(28.dp))
                FishIcon(Modifier.size(40.dp))
                Text(
                    stringResource(headline), Modifier.widthIn(max = Theme.readableWidth), style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold, color = colors.primaryText, textAlign = TextAlign.Center,
                )
                if (sub != null) {
                    Text(stringResource(sub), Modifier.widthIn(max = Theme.readableWidth), style = MaterialTheme.typography.bodyLarge, color = colors.secondaryText, textAlign = TextAlign.Center)
                }
                // Scannable rows instead of a paragraph.
                Column(Modifier.widthIn(max = Theme.readableWidth), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    ProBenefit(Icons.Filled.CalendarMonth, stringResource(R.string.s_10_day_outlook_for_every_spot))
                    ProBenefit(Icons.AutoMirrored.Filled.ShowChart, stringResource(R.string.hourly_bite_and_tide_curves))
                    ProBenefit(FishGlyph, stringResource(R.string.expected_catch_tuned_to_your_log))
                    ProBenefit(Icons.Filled.Notifications, stringResource(R.string.bite_alerts_a_week_ahead))
                    ProBenefit(Icons.Filled.Place, stringResource(R.string.unlimited_spots))
                }
                if (pending) {
                    Well(Modifier.widthIn(max = Theme.readableWidth).fillMaxWidth()) {
                        Text(stringResource(R.string.purchase_pending), style = MaterialTheme.typography.bodyMedium, color = colors.primaryText)
                    }
                }

                val loaded = offers
                when {
                    loaded != null -> {
                        val choice = loaded.list[selected.coerceIn(0, loaded.list.lastIndex)]
                        Column(Modifier.widthIn(max = Theme.readableWidth).selectableGroup(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            loaded.list.forEachIndexed { i, offer -> OfferCard(offer, isSelected = offer === choice) { selected = i } }
                        }
                        Text(
                            choice.terms, Modifier.widthIn(max = Theme.readableWidth), style = MaterialTheme.typography.bodySmall,
                            color = colors.secondaryText, textAlign = TextAlign.Center,
                        )
                        Button({ android.activity()?.let { choice.buy(it) } }, Modifier.widthIn(max = Theme.readableWidth).fillMaxWidth().heightIn(min = 52.dp)) {
                            Text(stringResource(choice.button), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        }
                        // The one single-feature purchase, offered only to someone who ran out of spots.
                        val packPrice = loaded.spotsPackPrice
                        if (context == PaywallContext.SPOTS && packPrice != null && !unlimitedSpots) {
                            TextButton({ android.activity()?.let { loaded.buySpotsPack(it) } }) {
                                Text(stringResource(R.string.only_need_more_spots, packPrice), textAlign = TextAlign.Center)
                            }
                        }
                    }
                    loadFailed -> {
                        Text(stringResource(R.string.could_not_load_subscription_plans), color = colors.secondaryText, textAlign = TextAlign.Center)
                        Button({ attempt += 1 }) { Text(stringResource(R.string.try_again)) }
                    }
                    else -> CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 3.dp)
                }
                // Side by side where they fit; one under the other in longer languages.
                FlowRow(horizontalArrangement = Arrangement.Center, itemVerticalAlignment = Alignment.CenterVertically) {
                    TextButton({ app.entitlements.requestRefresh() }) { Text(stringResource(R.string.restore_purchases), style = MaterialTheme.typography.bodySmall) }
                    TextButton({ open(android, Legal.privacy) }) { Text(stringResource(R.string.privacy_policy), style = MaterialTheme.typography.bodySmall) }
                }
            }
            IconButton(onDismiss, Modifier.align(Alignment.TopEnd).padding(8.dp)) {
                Icon(Icons.Filled.Close, stringResource(R.string.close), tint = colors.primaryText)
            }
        }
    }
}

/** One choice on the paywall: what it is, a note under it, and what it costs. */
@Composable
private fun OfferCard(offer: OfferView, isSelected: Boolean, onSelect: () -> Unit) {
    val colors = Theme.colors
    val shape = RoundedCornerShape(Theme.cardRadius)
    Row(
        Modifier.fillMaxWidth().clip(shape).background(colors.card)
            .border(if (isSelected) 2.dp else 1.dp, if (isSelected) colors.accent else colors.stroke, shape)
            .selectable(isSelected, role = Role.RadioButton, onClick = onSelect)
            .padding(horizontal = 14.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            if (isSelected) Icons.Filled.RadioButtonChecked else Icons.Filled.RadioButtonUnchecked, null,
            tint = if (isSelected) colors.accent else colors.secondaryText,
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(offer.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = colors.primaryText)
                val badge = offer.badge
                if (badge != null) {
                    Text(
                        badge, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, color = colors.accent,
                        modifier = Modifier.background(colors.accent.copy(alpha = 0.14f), CircleShape).padding(horizontal = 8.dp, vertical = 3.dp),
                    )
                }
            }
            offer.note?.let { note -> Text(note, style = MaterialTheme.typography.bodySmall, color = colors.secondaryText) }
        }
        Text(offer.price, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = colors.primaryText)
    }
}

/** One line of what Pro adds. */
@Composable
private fun ProBenefit(icon: ImageVector, text: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(icon, null, Modifier.size(24.dp), tint = Theme.colors.accent)
        Text(text, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium, color = Theme.colors.primaryText)
    }
}
