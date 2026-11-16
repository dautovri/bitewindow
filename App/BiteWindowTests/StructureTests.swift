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
}
