package com.dautovri.bitecurve.billing

import android.app.Activity
import android.content.Context
import android.util.Log
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.android.billingclient.api.acknowledgePurchase
import com.android.billingclient.api.queryProductDetails
import com.android.billingclient.api.queryPurchasesAsync
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Google Play Billing entitlement state, the counterpart of the iOS `EntitlementManager`.
 * One subscription, `bitecurve_pro`, with the base plans `monthly` and `annual` (the annual
 * one carries the free-trial offer); these must exist in the Play Console.
 *
 * Free: three spots, today and tomorrow. Pro: the hourly curve, tide curve, expected catch,
 * factor breakdown, ten days and unlimited spots.
 */
class Entitlements(context: Context, private val scope: CoroutineScope) : PurchasesUpdatedListener {
    companion object {
        const val productId = "bitecurve_pro"
        const val freeSpotLimit = 3
        /** Free: today and tomorrow. */
        const val freeDays = 2
        /** Pro: the full horizon. */
        const val horizonDays = 10
    }

    /** One way to buy Pro: a base plan, or an offer on one (the free trial). */
    class Plan(val details: ProductDetails, val offer: ProductDetails.SubscriptionOfferDetails) {
        val basePlanId: String get() = offer.basePlanId
        val phases: List<ProductDetails.PricingPhase> get() = offer.pricingPhases.pricingPhaseList
        val hasTrial: Boolean get() = phases.any { it.priceAmountMicros == 0L }
    }

    private val pro = MutableStateFlow(false)
    val isPro: StateFlow<Boolean> = pro

    /** Debug builds only (launch extra `BCPro`): unlocks Pro for screenshots and UI checks. */
    @Volatile var debugPro = false
        set(value) { field = value; pro.value = value || purchased }

    @Volatile private var purchased = false

    // Declared before `init`, which already connects.
    private val connecting = Mutex()

    private val client: BillingClient = BillingClient.newBuilder(context)
        .setListener(this)
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .enableAutoServiceReconnection()
        .build()

    init {
        scope.launch { refresh() }
    }

    /** Connects if needed; false when Play Billing cannot be reached on this device. */
    private suspend fun connect(): Boolean = connecting.withLock {
        // One attempt at a time: Play answers a second startConnection made while the first is
        // still under way with an error, and that caller would wrongly see "unreachable".
        if (client.isReady) return@withLock true
        val done = CompletableDeferred<Boolean>()
        try {
            client.startConnection(object : BillingClientStateListener {
                override fun onBillingSetupFinished(result: BillingResult) {
                    done.complete(result.responseCode == BillingClient.BillingResponseCode.OK)
                }

                override fun onBillingServiceDisconnected() {
                    done.complete(false)
                }
            })
        } catch (e: Exception) {
            Log.i("BiteCurve", "billing connection failed: ${e.message}")
            return@withLock false
        }
        withTimeoutOrNull(15_000) { done.await() } ?: false
    }

    /**
     * Recomputes access from the purchases Play reports for this account (renewals, refunds
     * and purchases made on another device included) and acknowledges new ones.
     */
    suspend fun refresh() {
        if (!connect()) return
        val result = client.queryPurchasesAsync(
            QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build(),
        )
        if (result.billingResult.responseCode != BillingClient.BillingResponseCode.OK) return
        apply(result.purchasesList)
    }

    private suspend fun apply(purchases: List<Purchase>) {
        val ours = purchases.filter { productId in it.products && it.purchaseState == Purchase.PurchaseState.PURCHASED }
        purchased = ours.isNotEmpty()
        pro.value = purchased || debugPro
        // Play refunds a purchase that is not acknowledged within three days.
        for (purchase in ours.filter { !it.isAcknowledged }) {
            client.acknowledgePurchase(AcknowledgePurchaseParams.newBuilder().setPurchaseToken(purchase.purchaseToken).build())
        }
    }

    /** The plans on sale, the trial offer first; null when they could not be loaded. */
    suspend fun plans(): List<Plan>? {
        if (!connect()) return null
        val params = QueryProductDetailsParams.newBuilder().setProductList(
            listOf(
                QueryProductDetailsParams.Product.newBuilder()
                    .setProductId(productId).setProductType(BillingClient.ProductType.SUBS).build(),
            ),
        ).build()
        val result = client.queryProductDetails(params)
        if (result.billingResult.responseCode != BillingClient.BillingResponseCode.OK) return null
        val details = result.productDetailsList?.firstOrNull() ?: return null
        val offers = details.subscriptionOfferDetails ?: return null
        // Per base plan, the offer with a free phase when this account may have it, else the plain plan.
        val plans = offers.groupBy { it.basePlanId }.map { (_, list) ->
            Plan(details, list.firstOrNull { o -> o.pricingPhases.pricingPhaseList.any { it.priceAmountMicros == 0L } } ?: list.first())
        }
        return plans.sortedBy { if (it.basePlanId == "annual") 0 else 1 }.takeIf { it.isNotEmpty() }
    }

    fun buy(activity: Activity, plan: Plan) {
        val params = BillingFlowParams.newBuilder().setProductDetailsParamsList(
            listOf(
                BillingFlowParams.ProductDetailsParams.newBuilder()
                    .setProductDetails(plan.details).setOfferToken(plan.offer.offerToken).build(),
            ),
        ).build()
        client.launchBillingFlow(activity, params)
    }

    override fun onPurchasesUpdated(result: BillingResult, purchases: MutableList<Purchase>?) {
        if (result.responseCode == BillingClient.BillingResponseCode.OK && purchases != null) {
            scope.launch { apply(purchases) }
        } else {
            scope.launch { refresh() }
        }
    }
}
