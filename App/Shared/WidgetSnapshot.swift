import Foundation
import SwiftUI

/// What the widgets show, written by the app each time forecasts are scored and read by the
/// widget extension from the shared app-group folder. The widget does no scoring or
/// networking of its own: it shows what the app last worked out, day by day.
struct WidgetSnapshot: Codable, Equatable {
    struct Day: Codable, Equatable {
        /// Midnight at the spot.
        let date: Date
        let index: Double?
        let start: Date?
        let end: Date?
    }

    struct Spot: Codable, Equatable, Identifiable {
        let id: UUID
        let name: String
        let timeZoneID: String
        let days: [Day]

        var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }
    }

    let updated: Date
    let spots: [Spot]

    static let appGroup = "group.com.dautovri.bitecurve"
    static let widgetKind = "BiteForecast"

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("widget-snapshot.json")
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Returns false when the shared folder is not there (no app-group entitlement).
    @discardableResult
    func save() -> Bool {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// One spot's outlook for the moment `now`: today's window while it is still ahead or
    /// running, otherwise the next day that has one.
    struct Pick: Equatable {
        let spot: Spot
        let day: Day
        let index: Double
        let start: Date
        let end: Date
        /// True when the window is on a later day than `now`.
        let isLater: Bool
    }

    func pick(for spot: Spot, at now: Date) -> Pick? {
        var calendar = Calendar.current
        calendar.timeZone = spot.timeZone
        let today = calendar.startOfDay(for: now)
        for day in spot.days.sorted(by: { $0.date < $1.date }) where day.date >= today {
            guard let index = day.index, let start = day.start, let end = day.end, end > now else { continue }
            return Pick(spot: spot, day: day, index: index, start: start, end: end, isLater: day.date > today)
        }
        return nil
    }

    /// Every spot's pick at `now`: today's windows before later days, then by index.
    func picks(at now: Date) -> [Pick] {
        spots.compactMap { pick(for: $0, at: now) }
            .sorted { a, b in
                if a.isLater != b.isLater { return !a.isLater }
                return a.index > b.index
            }
    }

    /// Moments at which a widget should redraw: now, each window's end (the pick moves on)
    /// and each spot's midnights.
    func refreshDates(from now: Date) -> [Date] {
        var dates: Set<Date> = [now]
        for spot in spots {
            for day in spot.days {
                if day.date > now { dates.insert(day.date) }
                if let end = day.end, end > now { dates.insert(end.addingTimeInterval(1)) }
            }
        }
        return dates.sorted()
    }
}

/// The app's four index colours, for the widgets (the app's own copy lives in `BiteScale`).
enum WidgetPalette {
    static let accent = Color(red: 0.05, green: 0.58, blue: 0.53)

    static func color(_ index: Double) -> Color {
        switch index {
        case 65...: return Color(red: 0.02, green: 0.59, blue: 0.41)
        case 50..<65: return Color(red: 0.03, green: 0.57, blue: 0.70)
        case 35..<50: return Color(red: 0.85, green: 0.47, blue: 0.02)
        default: return Color(red: 0.39, green: 0.45, blue: 0.55)
        }
    }
}
