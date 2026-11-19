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
 *
 * On sale: one subscription, `bitecurve_pro`, with the base plans `monthly` and `annual` (the
 * annual one carries the free-trial offer), and two one-time products, `bitecurve_pro_lifetime`
 * (all of Pro, for good) and `bitecurve_pack_spots` (unlimited spots only). A product that the
 * Play Console does not have is simply not offered.
 *
 * Free: three spots, today and tomorrow with today's curve. Pro: every day's curve, the tide
 * curve, expected catch, the full factor breakdown, ten days, alerts a week ahead and
 * unlimited spots.
 */
class Entitlements(context: Context, private val scope: CoroutineScope) : PurchasesUpdatedListener {
    companion object {
        const val productId = "bitecurve_pro"
        const val lifetimeId = "bitecurve_pro_lifetime"
        const val spotsPackId = "bitecurve_pack_spots"
        const val freeSpotLimit = 3
        /** Free: today and tomorrow. */
        const val freeDays = 2
        /** Pro: the full horizon. */
        const val horizonDays = 10
    }

    /** One way to subscribe to Pro: a base plan, or an offer on one (the free trial). */
    class Plan(val details: ProductDetails, val offer: ProductDetails.SubscriptionOfferDetails) {
        val basePlanId: String get() = offer.basePlanId
        val phases: List<ProductDetails.PricingPhase> get() = offer.pricingPhases.pricingPhaseList
        val trial: ProductDetails.PricingPhase? get() = phases.firstOrNull { it.priceAmountMicros == 0L }
        /**
         * One price, or one free period and then one price: what the paywall has a sentence for.
         * Anything else (a discounted first period, a trial of several cycles) is shown phase by phase.
         */
        val isPlain: Boolean get() = phases.size == 1 || (phases.size == 2 && phases[0].priceAmountMicros == 0L && phases[0].billingCycleCount == 1)
        /** What is charged again and again once any trial is over. */
        val recurring: ProductDetails.PricingPhase get() = phases.last()
    }

    /** What Play has on sale for this account. */
    class Catalog(val plans: List<Plan>, val lifetime: ProductDetails?, val spotsPack: ProductDetails?)

    /** What this account owns, as Play last reported it. Kept on the phone between launches. */
    private data class Owned(val subscription: Boolean = false, val lifetime: Boolean = false, val spotsPack: Boolean = false)

    private val saved = context.getSharedPreferences("entitlements", Context.MODE_PRIVATE)

    // The last known answer first: alerts laid out in the background, before Play has been
    // asked, must not treat a subscriber as free.
    @Volatile private var owned = Owned(saved.getBoolean("subscription", false), saved.getBoolean("lifetime", false), saved.getBoolean("spotsPack", false))

    private val pro = MutableStateFlow(owned.subscription || owned.lifetime)
    private val spots = MutableStateFlow(owned.subscription || owned.lifetime || owned.spotsPack)
    private val subscribed = MutableStateFlow(owned.subscription)
    private val pending = MutableStateFlow(false)

    val isPro: StateFlow<Boolean> = pro
    /** Pro, or the one-time spots pack. */
    val hasUnlimitedSpots: StateFlow<Boolean> = spots
    /** A running subscription, which Google Play can manage; false for lifetime owners. */
    val hasSubscription: StateFlow<Boolean> = subscribed
    /** A purchase waits for its payment (cash, bank transfer): nothing is unlocked yet. */
    val purchasePending: StateFlow<Boolean> = pending

    /** Debug builds only (launch extra `BCPro`): unlocks Pro for screenshots and UI checks. */
    @Volatile var debugPro = false
        set(value) { field = value; publish() }

    private fun publish() {
        val now = owned
        pro.value = now.subscription || now.lifetime || debugPro
        spots.value = pro.value || now.spotsPack
        subscribed.value = now.subscription
    }

    // Declared before `init`, which already connects.
    private val connecting = Mutex()
    // One refresh at a time: two that overlap could finish out of order and put an older
    // answer over a newer one (a purchase made in between would vanish again).
    private val refreshing = Mutex()

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
                    Log.i("BiteCurve", "billing setup: code ${result.responseCode} \"${result.debugMessage}\"")
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

    private suspend fun purchases(type: String): List<Purchase>? {
        val result = client.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(type).build())
        return result.purchasesList.takeIf { result.billingResult.responseCode == BillingClient.BillingResponseCode.OK }
    }

    /**
     * Recomputes access from the purchases Play reports for this account (renewals, refunds
     * and purchases made on another device included) and acknowledges new ones. A kind of
     * product Play cannot be asked about keeps its last known state.
     *
     * Runs in the app's scope, not the caller's: a screen that closes because Pro has just
     * been unlocked must not cancel the acknowledgement that follows.
     */
    suspend fun refresh() = scope.launch {
        refreshing.withLock {
            if (!connect()) return@withLock
            val subscriptions = purchases(BillingClient.ProductType.SUBS)
            val oneTime = purchases(BillingClient.ProductType.INAPP)
            fun List<Purchase>.owns(id: String) = any { id in it.products && it.purchaseState == Purchase.PurchaseState.PURCHASED }
            val before = owned
            store(
                Owned(
                    subscription = subscriptions?.owns(productId) ?: before.subscription,
                    lifetime = oneTime?.owns(lifetimeId) ?: before.lifetime,
                    spotsPack = oneTime?.owns(spotsPackId) ?: before.spotsPack,
                ),
            )
            val all = (subscriptions ?: emptyList()) + (oneTime ?: emptyList())
            if (subscriptions != null && oneTime != null) pending.value = all.any { it.purchaseState == Purchase.PurchaseState.PENDING }
            acknowledge(all.filter { it.purchaseState == Purchase.PurchaseState.PURCHASED })
        }
    }.join()

    /** `refresh` for a button: returns at once. */
    fun requestRefresh() {
        scope.launch { refresh() }
    }

    private fun store(next: Owned) {
        owned = next
        saved.edit().putBoolean("subscription", next.subscription).putBoolean("lifetime", next.lifetime).putBoolean("spotsPack", next.spotsPack).apply()
        publish()
    }

    /** Play refunds a purchase, one-time or subscription, that is not acknowledged within three days. */
    private suspend fun acknowledge(purchases: List<Purchase>) {
        for (purchase in purchases.filter { !it.isAcknowledged }) {
            val result = client.acknowledgePurchase(AcknowledgePurchaseParams.newBuilder().setPurchaseToken(purchase.purchaseToken).build())
            Log.i("BiteCurve", "billing acknowledge ${purchase.products}: code ${result.responseCode}")
        }
    }

    private suspend fun details(type: String, ids: List<String>): List<ProductDetails>? {
        val params = QueryProductDetailsParams.newBuilder().setProductList(
            ids.map { QueryProductDetailsParams.Product.newBuilder().setProductId(it).setProductType(type).build() },
        ).build()
        // The callback form rather than the coroutine one: only it says why a product was left out.
        val answer = CompletableDeferred<Pair<BillingResult, com.android.billingclient.api.QueryProductDetailsResult>>()
        client.queryProductDetailsAsync(params) { billing, products -> answer.complete(billing to products) }
        val (billing, products) = withTimeoutOrNull(15_000) { answer.await() } ?: return null
        // Why a paywall stays empty is otherwise invisible: Play's own answer goes to the log.
        // Status 3 is "product not found": no such product for this account (not a tester yet,
        // a product the Play Console does not have, or a new one Play has not started serving).
        Log.i(
            "BiteCurve",
            "billing products ($type): code ${billing.responseCode} \"${billing.debugMessage}\", ${products.productDetailsList.size} found, " +
                "left out: ${products.unfetchedProductList.joinToString { "${it.productId} status ${it.statusCode}" }.ifEmpty { "none" }}",
        )
        return products.productDetailsList.takeIf { billing.responseCode == BillingClient.BillingResponseCode.OK }
    }

    /** Everything on sale, the trial offer first; null when the subscription could not be loaded. */
    suspend fun catalog(): Catalog? {
        if (!connect()) return null
        val details = details(BillingClient.ProductType.SUBS, listOf(productId))?.firstOrNull() ?: return null
        val offers = details.subscriptionOfferDetails ?: return null
        Log.i("BiteCurve", "billing offers: ${offers.joinToString { "${it.basePlanId}/${it.offerId ?: "-"}" }}")
        // Per base plan, the offer with a free phase when this account may have it, else the plain plan.
        val plans = offers.groupBy { it.basePlanId }.map { (_, list) ->
            // Play does not promise an order: without a trial it is the base plan itself, not whichever offer comes first.
            Plan(details, list.firstOrNull { o -> o.pricingPhases.pricingPhaseList.any { it.priceAmountMicros == 0L } } ?: list.firstOrNull { it.offerId == null } ?: list.first())
        }.sortedBy { if (it.basePlanId == "annual") 0 else 1 }
        if (plans.isEmpty()) return null
        // The one-time products are extras: without them the subscription is still sold.
        val oneTime = details(BillingClient.ProductType.INAPP, listOf(lifetimeId, spotsPackId)) ?: emptyList()
        fun sellable(id: String) = oneTime.firstOrNull { it.productId == id && it.oneTimePurchaseOfferDetails != null }
        return Catalog(plans, sellable(lifetimeId), sellable(spotsPackId))
    }

    fun buy(activity: Activity, plan: Plan) = launch(
        activity,
        BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(plan.details).setOfferToken(plan.offer.offerToken).build(),
    )

    /** A one-time product: lifetime Pro or the spots pack. */
    fun buy(activity: Activity, product: ProductDetails) {
        val params = BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(product)
        product.oneTimePurchaseOfferDetails?.offerToken?.takeIf { it.isNotEmpty() }?.let { params.setOfferToken(it) }
        launch(activity, params.build())
    }

    private fun launch(activity: Activity, product: BillingFlowParams.ProductDetailsParams) {
        val result = client.launchBillingFlow(activity, BillingFlowParams.newBuilder().setProductDetailsParamsList(listOf(product)).build())
        Log.i("BiteCurve", "billing flow: code ${result.responseCode} \"${result.debugMessage}\"")
    }

    override fun onPurchasesUpdated(result: BillingResult, purchases: MutableList<Purchase>?) {
        scope.launch {
            // What was just bought counts at once, even if asking Play for the rest fails right now.
            val bought = purchases?.takeIf { result.responseCode == BillingClient.BillingResponseCode.OK }
                ?.filter { it.purchaseState == Purchase.PurchaseState.PURCHASED } ?: emptyList()
            if (bought.isNotEmpty()) {
                refreshing.withLock {
                    val before = owned
                    store(
                        Owned(
                            subscription = before.subscription || bought.any { productId in it.products },
                            lifetime = before.lifetime || bought.any { lifetimeId in it.products },
                            spotsPack = before.spotsPack || bought.any { spotsPackId in it.products },
                        ),
                    )
                    acknowledge(bought)
                }
            }
            // Then the whole picture (pending, cancelled, already owned): this call only carries the purchase that changed.
            refresh()
        }
    }
}
