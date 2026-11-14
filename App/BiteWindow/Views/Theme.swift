import BiteCore
import CoreLocation
import SwiftUI
import UIKit

/// The app's surfaces and accents: cool water tones instead of the system grey list look,
/// dark enough before dawn and legible in daylight.
enum Theme {
    /// Behind everything.
    static let background = Color(light: 0xEEF3F6, dark: 0x07111A)
    /// A card on the background.
    static let card = Color(light: 0xFFFFFF, dark: 0x0E1E2B)
    /// A recessed strip or pill inside a card.
    static let well = Color(light: 0xE3ECF2, dark: 0x15293A)
    /// Hairline around a card.
    static let stroke = Color(light: 0xCBD5E1, dark: 0x38BDF8, lightOpacity: 0.45, darkOpacity: 0.14)
    /// Buttons, links, the selected tab.
    static let accent = Color(light: 0x0D9488, dark: 0x2DD4BF)
    /// The tide curve.
    static let tide = Color(light: 0x0284C7, dark: 0x38BDF8)
    /// The dark panel that carries Pro; the same in light and dark.
    static let deepWater = Color(light: 0x0F293A, dark: 0x0F293A)

    static let cardRadius: CGFloat = 20
    static let wellRadius: CGFloat = 12
    static let gap: CGFloat = 14
    static let cardPadding: CGFloat = 16
    /// Cards never grow wider than this on iPad; grids take over there.
    static let readableWidth: CGFloat = 640
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

private extension UIColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension View {
    /// A card on the app background: padded, rounded, with a hairline.
    func card(padding: CGFloat = Theme.cardPadding) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }

    /// A recessed strip inside a card.
    func well() -> some View {
        self.padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.well, in: .rect(cornerRadius: Theme.wellRadius, style: .continuous))
    }

    /// The app background behind a scrolling screen, with room above the floating tab bar.
    func screenBackground() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .contentMargins(.bottom, 24, for: .scrollContent)
    }
}

/// A small heading above a card, like a list section header but on the app background.
struct CardHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The weather, sun and moon at one moment at a spot, formatted for the phone's region.
/// Every value comes from the forecast or from astronomy; nothing here is estimated.
struct Conditions {
    let hour: HourConditions?
    /// Pressure change over the three hours before `time`, hPa; nil without enough forecast.
    let pressureDelta: Double?
    let sunrise: Date?
    let sunset: Date?
    let moonPhaseAngle: Double

    /// The zone the clock times are written in.
    let timeZone: TimeZone

    init(at time: Date, hours: [HourConditions], latitude: Double, longitude: Double, calendar: Calendar = .current) {
        timeZone = calendar.timeZone
        let sorted = hours.sorted { $0.time < $1.time }
        // The forecast hour that contains `time`, within an hour and a half at most.
        let nearest = sorted.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
        hour = nearest.flatMap { abs($0.time.timeIntervalSince(time)) <= 5400 ? $0 : nil }
        if let hour, let earlier = sorted.last(where: { $0.time <= hour.time.addingTimeInterval(-3 * 3600 + 60) }),
           hour.time.timeIntervalSince(earlier.time) <= 4 * 3600 {
            pressureDelta = hour.pressureHPa - earlier.pressureHPa
        } else {
            pressureDelta = nil
        }
        let dayStart = calendar.startOfDay(for: time)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let sun = Astro.events(.sun, from: dayStart, to: dayEnd, latitude: latitude, longitude: longitude)
        sunrise = sun.rises.first
        sunset = sun.sets.last
        moonPhaseAngle = Astro.moonPhaseAngle(time)
    }

    var wind: String? {
        hour.map {
            Measurement(value: $0.windSpeedKmh, unit: UnitSpeed.kilometersPerHour)
                .formatted(.measurement(width: .abbreviated, usage: .wind, numberFormatStyle: .number.precision(.fractionLength(0))))
        }
    }

    /// Where the wind blows towards, as a rotation for an arrow that points up at 0.
    var windArrowDegrees: Double? { hour?.windFromDeg.map { $0 + 180 } }

    var pressure: String? {
        hour.map {
            Measurement(value: $0.pressureHPa, unit: UnitPressure.hectopascals)
                // Inches of mercury move in hundredths; hectopascals in whole numbers.
                .formatted(.measurement(width: .abbreviated, usage: .barometric,
                                        numberFormatStyle: .number.precision(.fractionLength(Locale.current.measurementSystem == .us ? 2 : 0))))
        }
    }

    /// Rising, falling or steady over three hours (a change under 0.5 hPa counts as steady).
    var pressureTrendSymbol: String? {
        pressureDelta.map { $0 > 0.5 ? "arrow.up.right" : $0 < -0.5 ? "arrow.down.right" : "arrow.right" }
    }

    var temperature: String? {
        hour.map {
            // -0.3 °C would print as "-0 °C"; the + 0 turns a negative zero into a plain one.
            Measurement(value: $0.airTempC, unit: UnitTemperature.celsius).converted(to: UnitTemperature(forLocale: .current, usage: .weather))
                .value.rounded() + 0
        }.map { (value: Double) in
            Measurement(value: value, unit: UnitTemperature(forLocale: .current, usage: .weather))
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
        }
    }

    var cloud: String? {
        hour.map { $0.cloudCover.formatted(.percent.precision(.fractionLength(0))) }
    }

    var cloudSymbol: String {
        guard let cover = hour?.cloudCover else { return "cloud" }
        return cover < 0.25 ? "sun.max.fill" : cover < 0.7 ? "cloud.sun.fill" : "cloud.fill"
    }

    /// The moon as it looks: eight phases from new to waning crescent.
    var moonSymbol: String {
        let names = ["moonphase.new.moon", "moonphase.waxing.crescent", "moonphase.first.quarter", "moonphase.waxing.gibbous",
                     "moonphase.full.moon", "moonphase.waning.gibbous", "moonphase.last.quarter", "moonphase.waning.crescent"]
        let index = Int(((moonPhaseAngle + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        return names[min(max(index, 0), 7)]
    }

    func clock(_ date: Date?) -> String? {
        date.map { $0.clock(in: timeZone) }
    }
}

/// One reading with its symbol, used in the weather strips.
struct Reading: View {
    let symbol: String
    let text: String
    var rotation: Double? = nil
    var trailingSymbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .rotationEffect(.degrees(rotation ?? 0))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(verbatim: text).monospacedDigit()
            if let trailingSymbol {
                Image(systemName: trailingSymbol).font(.caption2.weight(.bold)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .font(.footnote)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// Wind, pressure with its trend, temperature and cloud in one row; wraps to two rows when
/// the text size is large. Shows nothing when there is no forecast for that moment.
struct WeatherStrip: View {
    let conditions: Conditions

    var body: some View {
        if conditions.hour != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { items }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) { wind; pressure }
                    HStack(spacing: 14) { temperature; cloud }
                }
            }
            .foregroundStyle(.primary)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var items: some View {
        wind; pressure; temperature; cloud
    }

    @ViewBuilder private var wind: some View {
        if let text = conditions.wind {
            if let degrees = conditions.windArrowDegrees {
                Reading(symbol: "location.north.fill", text: text, rotation: degrees)
            } else {
                Reading(symbol: "wind", text: text)
            }
        }
    }

    @ViewBuilder private var pressure: some View {
        if let text = conditions.pressure {
            Reading(symbol: "barometer", text: text, trailingSymbol: conditions.pressureTrendSymbol)
        }
    }

    @ViewBuilder private var temperature: some View {
        if let text = conditions.temperature { Reading(symbol: "thermometer.medium", text: text) }
    }

    @ViewBuilder private var cloud: some View {
        if let text = conditions.cloud { Reading(symbol: conditions.cloudSymbol, text: text) }
    }
}

/// Wind, pressure, temperature and cloud as four even cells (symbol over value), with sunrise,
/// sunset and the moon in a quiet row under them. Two rows of two at large text sizes.
/// Shows only the sun row when there is no forecast for that moment.
struct ConditionsGrid: View {
    let conditions: Conditions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if conditions.hour != nil {
                ViewThatFits(in: .horizontal) {
                    // Natural widths with even gaps: a long pressure reading never runs into the next cell.
                    HStack(alignment: .top, spacing: 0) {
                        wind; Spacer(minLength: 10); pressure; Spacer(minLength: 10); temperature; Spacer(minLength: 10); cloud
                    }
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                        GridRow { wind; pressure }
                        GridRow { temperature; cloud }
                    }
                    // The largest text sizes: one reading per line.
                    VStack(alignment: .leading, spacing: 10) { wind; pressure; temperature; cloud }
                }
            }
            SunMoonStrip(conditions: conditions)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var wind: some View {
        if let text = conditions.wind {
            Cell(symbol: conditions.windArrowDegrees == nil ? "wind" : "location.north.fill",
                 rotation: conditions.windArrowDegrees, text: text)
        }
    }

    @ViewBuilder private var pressure: some View {
        if let text = conditions.pressure {
            Cell(symbol: "barometer", text: text, trailingSymbol: conditions.pressureTrendSymbol)
        }
    }

    @ViewBuilder private var temperature: some View {
        if let text = conditions.temperature { Cell(symbol: "thermometer.medium", text: text) }
    }

    @ViewBuilder private var cloud: some View {
        if let text = conditions.cloud { Cell(symbol: conditions.cloudSymbol, text: text) }
    }

    private struct Cell: View {
        let symbol: String
        var rotation: Double? = nil
        let text: String
        var trailingSymbol: String? = nil

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: symbol)
                    .font(.body)
                    .symbolRenderingMode(.hierarchical)
                    .rotationEffect(.degrees(rotation ?? 0))
                    .foregroundStyle(Theme.accent)
                    .frame(height: 20)
                    .accessibilityHidden(true)
                HStack(spacing: 2) {
                    Text(verbatim: text).monospacedDigit()
                    if let trailingSymbol {
                        Image(systemName: trailingSymbol).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            }
            .fixedSize()
        }
    }
}

/// Sunrise, sunset and the moon's phase in one row. Sun times are missing in polar day or night.
struct SunMoonStrip: View {
    let conditions: Conditions

    @ViewBuilder private var items: some View {
        if let rise = conditions.clock(conditions.sunrise) { Reading(symbol: "sunrise.fill", text: rise) }
        if let set = conditions.clock(conditions.sunset) { Reading(symbol: "sunset.fill", text: set) }
        Image(systemName: conditions.moonSymbol)
            .font(.footnote)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Theme.accent)
            .accessibilityLabel("Moon")
    }

    var body: some View {
        // Stacked at the largest text sizes, so the times are never cut off.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { items }
            VStack(alignment: .leading, spacing: 6) { items }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

extension Date {
    /// The time of day in a given zone, in the phone's 12- or 24-hour style.
    func clock(in timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        return formatted(style)
    }

    /// A date format written in a given zone.
    func formatted(_ style: Date.FormatStyle, in timeZone: TimeZone) -> String {
        var style = style
        style.timeZone = timeZone
        return formatted(style)
    }
}

/// Looks up a spot's time zone from its coordinates with Apple's geocoder. This needs a
/// connection but no location permission: the coordinates are the spot's, not the phone's.
@MainActor
enum SpotTimeZone {
    private static var inFlight: Set<UUID> = []
    /// When each spot was last asked about: a failed lookup (offline, open sea) is not
    /// repeated on every redraw, which the geocoder would answer by refusing all requests.
    private static var lastAttempt: [UUID: Date] = [:]

    static func resolveIfNeeded(_ spot: Spot) async {
        guard spot.timeZoneID == nil, !inFlight.contains(spot.id),
              Date().timeIntervalSince(lastAttempt[spot.id] ?? .distantPast) > 300 else { return }
        lastAttempt[spot.id] = Date()
        inFlight.insert(spot.id)
        defer { inFlight.remove(spot.id) }
        let location = CLLocation(latitude: spot.latitude, longitude: spot.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first,
              let zone = placemark.timeZone else { return }
        spot.timeZoneID = zone.identifier
        try? spot.modelContext?.save()
    }
}
