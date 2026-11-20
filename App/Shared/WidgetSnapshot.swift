import Foundation
import Security
import SwiftUI
import UIKit

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

/// The four bite-index steps, shared by the app (`BiteScale`) and the widgets. The colours
/// differ in lightness as well as hue (viridian, cobalt, copper, slate), so they stay apart
/// with red-green colour blindness, in polarised glasses and in greyscale; each step also
/// has its own shape.
enum WidgetPalette {
    static let accent = Color(light: 0x0F766E, dark: 0x38E2C7)

    /// Steps go by the number shown, so a 49.6 that reads "50" is above average like any 50.
    static func color(_ index: Double) -> Color {
        switch index.rounded() {
        case 65...: return Color(light: 0x046A4E, dark: 0x2EE59D)
        case 50..<65: return Color(light: 0x0062CC, dark: 0x52A8FF)
        case 35..<50: return Color(light: 0xB54708, dark: 0xFB923C)
        default: return Color(light: 0x5E6B7C, dark: 0x8B9BB0)
        }
    }

    /// Text on a solid bite colour: white in light mode, near-black on the bright dark-mode fills.
    static let onSolid = Color(light: 0xFFFFFF, dark: 0x041017)

    /// A shape per step, so the scale reads without colour: diamond, circle, triangle, ring.
    static func symbol(_ index: Double) -> String {
        switch index.rounded() {
        case 65...: return "diamond.fill"
        case 50..<65: return "circle.fill"
        case 35..<50: return "triangle.fill"
        default: return "circle"
        }
    }
}

extension Color {
    /// One colour for light and one for dark appearance, from 0xRRGGBB values.
    init(light: UInt32, dark: UInt32, lightOpacity: Double = 1, darkOpacity: Double = 1) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkOpacity)
                : UIColor(hex: light, alpha: lightOpacity)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}


