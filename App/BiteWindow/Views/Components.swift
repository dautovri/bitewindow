import BiteCore
import Charts
import SwiftUI

extension Species {
    /// `displayName` in BiteCore is English only; the app shows this.
    var localizedName: String {
        switch self {
        case .largemouthBass: return String(localized: "Largemouth bass")
        case .walleye: return String(localized: "Walleye")
        case .northernPike: return String(localized: "Northern pike")
        case .rainbowTrout: return String(localized: "Rainbow trout")
        }
    }
}

/// Colour and wording for a bite index. 50 is neutral.
enum BiteScale {
    static func color(_ index: Double?) -> Color {
        guard let index else { return .secondary }
        // Four clearly different steps, so 51 and 68 no longer look alike. A slow day is
        // quiet slate, not alarm red: nothing is wrong, the fish are just not feeding.
        switch index {
        case 65...: return Color(light: 0x059669, dark: 0x34D399)
        case 50..<65: return Color(light: 0x0891B2, dark: 0x22D3EE)
        case 35..<50: return Color(light: 0xD97706, dark: 0xFBBF24)
        default: return Color(light: 0x64748B, dark: 0x94A3B8)
        }
    }

    static func label(_ index: Double) -> String {
        switch index {
        case 65...: return String(localized: "Strong bite")
        case 50..<65: return String(localized: "Above average")
        case 35..<50: return String(localized: "Below average")
        default: return String(localized: "Slow")
        }
    }
}

/// Ring filled to the index, with the number in the middle. `nil` draws an empty ring.
struct IndexGauge: View {
    let index: Double?
    var size: CGFloat = 44

    var body: some View {
        let lineWidth = max(3, size * 0.11)
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, index ?? 0)) / 100))
                .stroke(BiteScale.color(index), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(index.map { "\(Int($0.rounded()))" } ?? "–")
                .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bite index")
        .accessibilityValue(index.map { String(localized: "\(Int($0.rounded())) of 100") } ?? String(localized: "not available"))
    }
}

/// One day's bite curve with night shaded, the best window marked and a line at the current
/// time. With no points it draws the day's frame only (the free tier shows that, never a
/// made-up curve); `domain` then gives the day.
struct BiteCurveChart: View {
    let points: [ScorePoint]
    let window: BiteWindow?
    var sunrise: Date? = nil
    var sunset: Date? = nil
    var domain: ClosedRange<Date>? = nil
    var timeZone: TimeZone = .current

    private var span: ClosedRange<Date>? {
        if let domain { return domain }
        guard let first = points.first, let last = points.last, first.time < last.time else { return nil }
        return first.time...last.time
    }

    private var now: Date? {
        let t = Date()
        guard let span, span.contains(t) else { return nil }
        return t
    }

    private var zoneCalendar: Calendar { var c = Calendar.current; c.timeZone = timeZone; return c }

    var body: some View {
        let color = BiteScale.color(window?.meanIndex)
        let night = Color(light: 0x0B1522, dark: 0x000000, lightOpacity: 0.07, darkOpacity: 0.32)
        Chart {
            if let span {
                // Before sunrise and after sunset, so dawn and dusk peaks read at a glance.
                if let sunrise, sunrise > span.lowerBound {
                    RectangleMark(xStart: .value("Night start", span.lowerBound), xEnd: .value("Sunrise", min(sunrise, span.upperBound)))
                        .foregroundStyle(night)
                }
                if let sunset, sunset < span.upperBound {
                    RectangleMark(xStart: .value("Sunset", max(sunset, span.lowerBound)), xEnd: .value("Night end", span.upperBound))
                        .foregroundStyle(night)
                }
            }
            if let window {
                RectangleMark(xStart: .value("Window start", window.start), xEnd: .value("Window end", window.end))
                    .foregroundStyle(color.opacity(0.18))
            }
            ForEach(points, id: \.time) { point in
                AreaMark(x: .value("Time", point.time), y: .value("Index", point.index))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.32), color.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.time), y: .value("Index", point.index))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .foregroundStyle(color)
            }
            RuleMark(y: .value("Neutral", 50))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(Color.secondary.opacity(0.5))
            if let now {
                RuleMark(x: .value("Now", now))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(Color.primary.opacity(0.6))
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: span ?? Date()...Date().addingTimeInterval(86_400))
        .chartYAxis { AxisMarks(values: [0, 50, 100]) }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6, calendar: zoneCalendar)) { _ in
                AxisGridLine()
                AxisValueLabel(format: Date.FormatStyle(timeZone: timeZone).hour())
            }
        }
        .accessibilityLabel("Bite index through the day")
    }
}

struct TideChart: View {
    let samples: [TideStation.Sample]
    var timeZone: TimeZone = .current

    private var zoneCalendar: Calendar { var c = Calendar.current; c.timeZone = timeZone; return c }

    var body: some View {
        Chart(samples, id: \.time) { sample in
            AreaMark(x: .value("Time", sample.time), y: .value("Tide (m)", sample.height))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(LinearGradient(colors: [Theme.tide.opacity(0.3), Theme.tide.opacity(0.03)],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", sample.time), y: .value("Tide (m)", sample.height))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Theme.tide)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6, calendar: zoneCalendar)) { _ in
                AxisGridLine()
                AxisValueLabel(format: Date.FormatStyle(timeZone: timeZone).hour())
            }
        }
        .accessibilityLabel("Tide height through the day")
    }
}

/// How much each factor pushes the index up or down, as diverging bars, with the reading
/// behind each factor so the bar is not an abstract number.
struct FactorBreakdown: View {
    struct Factor: Identifiable {
        let name: String
        /// Weighted contribution w·z; about ±0.25 at the extremes.
        let value: Double
        var symbol: String = "circle"
        /// The measurement the factor rests on in this window, already formatted; nil when it has none to show.
        var reading: String? = nil
        var readingSymbol: String? = nil
        var id: String { name }
    }

    let factors: [Factor]

    private static let positive = Color(light: 0x059669, dark: 0x34D399)
    private static let negative = Color(light: 0xD97706, dark: 0xFBBF24)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What drives this window")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(factors) { factor in
                HStack(spacing: 10) {
                    Image(systemName: factor.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: factor.name).font(.subheadline.weight(.medium))
                        if let reading = factor.reading {
                            HStack(spacing: 3) {
                                Text(verbatim: reading).monospacedDigit()
                                if let symbol = factor.readingSymbol { Image(systemName: symbol).font(.caption2.weight(.bold)) }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    bar(factor.value)
                    Image(systemName: factor.value > 0.02 ? "arrow.up" : factor.value < -0.02 ? "arrow.down" : "minus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(color(factor.value))
                        .frame(width: 16)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: [factor.name, factor.reading].compactMap { $0 }.joined(separator: ", ")))
                .accessibilityValue(factor.value > 0.02 ? String(localized: "helps") : factor.value < -0.02 ? String(localized: "hurts") : String(localized: "neutral"))
            }
        }
    }

    private func color(_ value: Double) -> Color {
        value > 0.02 ? Self.positive : value < -0.02 ? Self.negative : .secondary
    }

    private func bar(_ value: Double) -> some View {
        let half: CGFloat = 44
        let magnitude = CGFloat(min(1, abs(value) / 0.25))
        return ZStack {
            Capsule().fill(Theme.well).frame(width: half * 2, height: 8)
            Capsule().fill(color(value))
                .frame(width: max(3, half * magnitude), height: 8)
                .offset(x: (value < 0 ? -1 : 1) * half * magnitude / 2)
            Rectangle().fill(Color.secondary).frame(width: 1.5, height: 12)
        }
    }
}

struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(verbatim: value).font(.title3.weight(.bold)).monospacedDigit()
            Text(verbatim: label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
