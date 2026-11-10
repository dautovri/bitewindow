import Observation
import StoreKit

/// StoreKit 2 entitlement state. Product IDs must match App Store Connect
/// (one subscription group "Pro" with annual + monthly; lifetime is a non-consumable).
@MainActor
@Observable
final class EntitlementManager {
    static let annual = "bitewindow.pro.annual"
    static let monthly = "bitewindow.pro.monthly"
    static let lifetime = "bitewindow.pro.lifetime"
    static let subscriptionIDs = [annual, monthly]
    static let allIDs: Set<String> = [annual, monthly, lifetime]

    static let freeSpotLimit = 3

    private(set) var isPro = false
    private var updates: Task<Void, Never>?

    init() {
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
        var pro = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.revocationDate == nil, Self.allIDs.contains(transaction.productID) {
                pro = true
            }
        }
        isPro = pro
    }
}
