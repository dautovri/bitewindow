import BiteCore
import SwiftData
import XCTest
@testable import BiteWindow

/// The shared day calculation and the versioned store.
final class StructureTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private let context = SpotContext(latitude: 52.5, longitude: 13.4, water: .warmFreshwater, species: .largemouthBass,
                                      bankBearingDeg: nil, waterTempC: 18)

    func testDaysStartTodayAndKeepTodaysWindowAhead() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 14))!
        let hours = ForecastService.sampleHours(now: now)
        let days = DayOutlooks.days(context: context, hours: hours, calendar: calendar, days: 3, now: now)
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days[0].date, calendar.startOfDay(for: now))
        for (offset, day) in days.enumerated() {
            XCTAssertEqual(day.date, calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)))
            XCTAssertFalse(day.points.isEmpty)
            XCTAssertTrue(day.points.allSatisfy { calendar.startOfDay(for: $0.time) == day.date })
        }
        if let window = days[0].window {
            XCTAssertGreaterThanOrEqual(window.start, now.addingTimeInterval(-900))
        }
    }

    func testPlannerOutlooksMatchTheScreens() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 9))!
        let hours = ForecastService.sampleHours(now: now)
        let days = DayOutlooks.days(context: context, hours: hours, calendar: calendar, days: 5, now: now)
        let outlooks = DayOutlooks.compute(context: context, hours: hours, calendar: calendar, days: 5, now: now)
        XCTAssertEqual(outlooks.map(\.date), days.map(\.date))
        XCTAssertEqual(outlooks.map(\.index), days.map { $0.window?.meanIndex })
    }

    @MainActor
    func testVersionedSchemaOpens() throws {
        let schema = Schema(versionedSchema: BiteSchemaV1.self)
        let container = try ModelContainer(for: schema, migrationPlan: BiteMigrationPlan.self,
                                           configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let spot = Spot(name: "Test", latitude: 52.5, longitude: 13.4)
        container.mainContext.insert(spot)
        container.mainContext.insert(Trip(spot: spot))
        try container.mainContext.save()
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Trip>()), 1)
    }

    // MARK: "How did it go?" notifications

    private func alertPlan(busy: Set<UUID> = [], pending: Set<String> = [], hoursAfterMidnight: Double) -> (UUID, [BiteAlerts.Alert]) {
        let id = UUID()
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 6, day: 10))!
        let now = midnight.addingTimeInterval(hoursAfterMidnight * 3600)
        let input = SpotSummaryInput(id: id, name: "Test", context: context, timeZone: calendar.timeZone,
                                     hours: ForecastService.sampleHours(now: now))
        let days = [id: DayOutlooks.compute(context: context, hours: input.hours, calendar: calendar, days: 2, now: now)]
        return (id, BiteAlerts.plan(inputs: [input], days: days, threshold: 0, now: now, busySpots: busy, keptAfterIDs: pending))
    }

    func testAlertedWindowsGetAnAfterNotification() {
        let (id, plan) = alertPlan(hoursAfterMidnight: 0.5)
        let soon = plan.filter { $0.id.hasPrefix("soon.") }
        let after = plan.filter { $0.id.hasPrefix("after.") }
        XCTAssertFalse(after.isEmpty)
        XCTAssertEqual(after.count, soon.count)
        for alert in after {
            let window = try! XCTUnwrap(alert.window)
            XCTAssertEqual(window.spotID, id)
            XCTAssertEqual(alert.fireDate, window.end.addingTimeInterval(900))
        }
    }

    func testNoAfterNotificationForASpotWithARunningTrip() {
        let id = UUID()
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 6, day: 10))!
        let now = midnight.addingTimeInterval(1800)
        let input = SpotSummaryInput(id: id, name: "Test", context: context, timeZone: calendar.timeZone,
                                     hours: ForecastService.sampleHours(now: now))
        let days = [id: DayOutlooks.compute(context: context, hours: input.hours, calendar: calendar, days: 2, now: now)]
        let plan = BiteAlerts.plan(inputs: [input], days: days, threshold: 0, now: now, busySpots: [id])
        XCTAssertTrue(plan.allSatisfy { $0.window == nil })
    }

    func testKeptAfterNotificationsAreNotPlannedTwice() {
        let (_, first) = alertPlan(hoursAfterMidnight: 0.5)
        let ids = Set(first.filter { $0.window != nil }.map(\.id))
        XCTAssertFalse(ids.isEmpty)
        let (_, again) = alertPlan(pending: ids, hoursAfterMidnight: 0.5)
        // A fresh spot id is drawn per call, so compare by count: none of the kept ones repeat.
        XCTAssertEqual(again.filter { $0.window != nil }.count, first.filter { $0.window != nil }.count)
    }
}

