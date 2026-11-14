import Foundation
import Security
import SwiftUI

/// What the widgets show, written by the app each time forecasts are scored and read by the
/// widget extension from a shared keychain group. The widget does no scoring or
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

    static let widgetKind = "BiteForecast"

    // The snapshot travels from the app to the widget extension as one item in a keychain
    // group both are signed into. An app group folder would be the usual place, but an app
    // group has to be registered by hand in the developer portal (Apple's API cannot), and a
    // keychain group needs nothing beyond the team's own prefix. The item is a few kilobytes.
    private static let service = "com.dautovri.bitecurve.widget-snapshot"

    /// `<team prefix>com.dautovri.bitecurve.shared`, as in both targets' entitlements. The
    /// prefix comes from the build (Info.plist) and is empty in unsigned simulator builds.
    private static var accessGroup: String {
        let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? ""
        return prefix + "com.dautovri.bitecurve.shared"
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "snapshot",
         kSecAttrAccessGroup as String: accessGroup]
    }

    static func load() -> WidgetSnapshot? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Returns false when the item could not be written (the keychain group is missing from
    /// the signature).
    @discardableResult
    func save() -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        SecItemDelete(Self.baseQuery as CFDictionary)
        var item = Self.baseQuery
        item[kSecValueData as String] = data
        // Readable by the widget whenever the phone has been unlocked once since boot.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
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
