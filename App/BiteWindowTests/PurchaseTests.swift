import StoreKit
import StoreKitTest
import XCTest
@testable import BiteWindow

/// BiteCurve Pro against Xcode's local App Store (`BiteWindow.storekit`): the plans on sale,
/// buying unlocks, a refund locks again.
@MainActor
final class PurchaseTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "BiteWindow")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        // A new session takes a moment to put its products on sale.
        for _ in 0..<50 where try await Product.products(for: EntitlementManager.subscriptionIDs).count < 2 {
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    override func tearDown() async throws {
        session.clearTransactions()
    }

    /// The local store records purchases and refunds a moment after the call returns.
    private func waitForPro(_ expected: Bool, _ entitlements: EntitlementManager) async throws {
        for _ in 0..<40 {
            await entitlements.refresh()
            if entitlements.isPro == expected { return }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func buy(_ id: String) async throws -> StoreKit.Transaction {
        try await session.buyProduct(identifier: id)
    }

    func testBothPlansAreOnSaleAndOnlyTheYearlyHasAFreeWeek() async throws {
        let products = try await Product.products(for: EntitlementManager.subscriptionIDs)
        let byID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        let annual = try XCTUnwrap(byID[EntitlementManager.annual]?.subscription)
        let monthly = try XCTUnwrap(byID[EntitlementManager.monthly]?.subscription)
        XCTAssertEqual(annual.subscriptionPeriod.unit, .year)
        XCTAssertEqual(annual.introductoryOffer?.paymentMode, .freeTrial)
        // One week, which StoreKit may report as 7 days.
        let trial = try XCTUnwrap(annual.introductoryOffer?.period)
        XCTAssertTrue((trial.unit == .week && trial.value == 1) || (trial.unit == .day && trial.value == 7), "\(trial)")
        XCTAssertEqual(monthly.subscriptionPeriod.unit, .month)
        XCTAssertNil(monthly.introductoryOffer)
        XCTAssertEqual(annual.subscriptionGroupID, monthly.subscriptionGroupID, "one group, so a person holds one plan")
    }

    func testNothingBoughtIsFree() async throws {
        let entitlements = EntitlementManager(listens: false)
        await entitlements.refresh()
        XCTAssertFalse(entitlements.isPro)
    }

    func testBuyingTheYearlyPlanUnlocksProAndARefundLocksAgain() async throws {
        let entitlements = EntitlementManager(listens: false)
        let transaction = try await buy(EntitlementManager.annual)
        try await waitForPro(true, entitlements)
        XCTAssertTrue(entitlements.isPro)

        try session.refundTransaction(identifier: UInt(transaction.id))
        try await waitForPro(false, entitlements)
        XCTAssertFalse(entitlements.isPro)
    }

    func testBuyingTheMonthlyPlanUnlocksPro() async throws {
        let entitlements = EntitlementManager(listens: false)
        _ = try await buy(EntitlementManager.monthly)
        try await waitForPro(true, entitlements)
        XCTAssertTrue(entitlements.isPro)
    }
}
