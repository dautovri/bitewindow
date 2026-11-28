import Observation
import StoreKit

/// StoreKit 2 entitlement state. Product IDs must match App Store Connect
/// (one subscription group "Pro" with annual + monthly; lifetime is a non-consumable).
@MainActor
@Observable
final class EntitlementManager {
    static let annual = "bitecurve.pro.annual"
    static let monthly = "bitecurve.pro.monthly"
    static let lifetime = "bitecurve.pro.lifetime"
    static let subscriptionIDs = [annual, monthly]
    static let allIDs: Set<String> = [annual, monthly, lifetime]

    static let freeSpotLimit = 3
    /// Days with a forecast window for free users (today and tomorrow), everywhere it shows:
    /// screens, planner, alerts and widgets.
    static let freeDays = 2
    /// The last known Pro state, for code that runs without the environment (alerts, widgets,
    /// background refresh). Written by `refresh()`.
    nonisolated static let cachedProKey = "isProCached"
    nonisolated static var cachedIsPro: Bool { UserDefaults.standard.bool(forKey: cachedProKey) }

    private(set) var isPro = false
    private var updates: Task<Void, Never>?

    /// `listens: false` leaves StoreKit alone until `refresh()` is called (unit tests).
    init(listens: Bool = true) {
        guard listens else { return }
        // Renewals, refunds, Family Sharing changes and purchases made outside the app.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                await self?.refresh()
            }
        }
        Task { [weak self] in await self?.refresh() }
    }

    /// Recomputes access from verified current entitlements. StoreKit keeps a
    /// subscription in `currentEntitlements` during the billing grace period.
    func refresh() async {
        isPro = await Self.updateCachedPro()
    }

    /// Reads the verified entitlements and stores the result in `cachedIsPro`. Also called by the
    /// background refresh, which may run (after an update, a purchase elsewhere or a refund)
    /// before any screen has refreshed the cached state.
    @discardableResult
    static func updateCachedPro() async -> Bool {
        var pro = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.revocationDate == nil, allIDs.contains(transaction.productID) {
                pro = true
            }
        }
        #if DEBUG
        // `-BCPro YES` unlocks Pro in Debug builds (screenshots, UI checks).
        if UserDefaults.standard.bool(forKey: "BCPro") { pro = true }
        #endif
        UserDefaults.standard.set(pro, forKey: cachedProKey)
        return pro
    }
}
