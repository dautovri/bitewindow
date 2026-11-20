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
        case .crucianCarp: return String(localized: "Crucian carp")
        case .commonCarp: return String(localized: "Common carp")
        case .europeanPerch: return String(localized: "Perch")
        case .commonBream: return String(localized: "Bream")
        case .general: return String(localized: "Any fish")
        case .europeanSeaBass: return String(localized: "Sea bass")
        case .atlanticCod: return String(localized: "Cod")
        case .atlanticMackerel: return String(localized: "Mackerel")
        case .seaTrout: return String(localized: "Sea trout")
        case .flounder: return String(localized: "Flounder")
        case .stripedBass: return String(localized: "Striped bass")
        case .redDrum: return String(localized: "Red drum")
        }
    }

    /// Side-view illustration in Assets.xcassets/Fish (360 px wide, about 18 KB each).
    var image: Image { Image("Fish/\(rawValue)") }
}

/// Colour and wording for a bite index. 50 is neutral.
enum BiteScale {
    static func color(_ index: Double?) -> Color {
        guard let index else { return .secondary }
        // Four clearly different steps, so 51 and 68 no longer look alike. A slow day is
        // quiet slate, not alarm red: nothing is wrong, the fish are just not feeding.
        return WidgetPalette.color(index)
    }

    /// Text on a solid bite colour.
    static let onSolid = WidgetPalette.onSolid

    /// The step's shape (diamond, circle, triangle, ring), so no reading depends on colour alone.
    static func symbol(_ index: Double) -> String { WidgetPalette.symbol(index) }

    static func label(_ index: Double) -> String {
        switch index.rounded() {
        case 65...: return String(localized: "Strong bite")
        case 50..<65: return String(localized: "Above average")
        case 35..<50: return String(localized: "Below average")
        default: return String(localized: "Slow")
        }
    }
}

/// An open 270° dial filled to the index, like a marine gauge, with a tick at 12 o'clock for
/// the neutral 50: an arc that passes the tick is above average without reading the number.
/// `nil` draws the empty dial.
struct IndexGauge: View {
    let index: Double?
    var size: CGFloat = 44

    /// The dial covers three quarters of the circle, open at the bottom.
    static let sweep = 0.75

    var body: some View {
        let lineWidth = max(3, size * 0.1)
        let value = max(0, min(100, index ?? 0)) / 100
        ZStack {
            Circle()
                .trim(from: 0, to: Self.sweep)
                .stroke(Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: Self.sweep * value)
                .stroke(BiteScale.color(index), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
            // The neutral 50, at the top of the dial, cut out of the arc so an arc that ends
            // right at 50 does not hide it.
            Capsule()
                .fill(Color.primary.opacity(0.7))
                .frame(width: max(1.5, size * 0.035), height: lineWidth + max(3, size * 0.06))
                .padding(.horizontal, max(1.5, size * 0.03))
                .background(Theme.card, in: .capsule)
                .offset(y: -size / 2 + lineWidth / 2)
            Text(index.map { "\(Int($0.rounded()))" } ?? "–")
                .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .offset(y: size * 0.03)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bite index")
        .accessibilityValue(index.map { String(localized: "\(Int($0.rounded())) of 100") } ?? String(localized: "not available"))
    }
}

/// A score as a tile: solid for a strong bite, outlined for above average, dashed for below,
/// flat for slow, with the step's shape beside the number. Used where many scores sit side
/// by side (day strip, planner), so they read without colour and without rings.
struct ScoreTile: View {
    let index: Double
    var size = CGSize(width: 46, height: 40)
    var showsShape = true

    var body: some View {
        let color = BiteScale.color(index)
        let strong = index.rounded() >= 65
        HStack(spacing: 3) {
            if showsShape {
                Image(systemName: BiteScale.symbol(index))
                    .font(.system(size: 7, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(verbatim: "\(Int(index.rounded()))")
                .font(.system(.callout, design: .rounded, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 2)
        .foregroundStyle(strong ? BiteScale.onSolid : (index.rounded() < 35 ? Theme.ink2 : color))
        .frame(width: size.width, height: size.height)
        .background(fill(color), in: .rect(cornerRadius: Theme.cellRadius, style: .continuous))
        .overlay { border(color) }
    }

    private func fill(_ color: Color) -> Color {
        switch index.rounded() {
        case 65...: return color
        case 50..<65: return color.opacity(0.14)
        case 35..<50: return color.opacity(0.12)
        default: return Theme.well
        }
    }

    @ViewBuilder private func border(_ color: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cellRadius, style: .continuous)
        switch index.rounded() {
        case 50..<65: shape.strokeBorder(color, lineWidth: 1.5)
        case 35..<50: shape.strokeBorder(color, style: StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
        default: EmptyView()
        }
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
    /// Off when a tide chart sits right under it on the same clock: the hours show once, below.
    var showsTimeLabels = true

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
                PointMark(x: .value("Now", now), y: .value("Top", 100))
                    .symbolSize(30)
                    .foregroundStyle(Color.primary.opacity(0.75))
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: span ?? Date()...Date().addingTimeInterval(86_400))
        .chartYAxis { AxisMarks(values: [0, 50, 100]) }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6, calendar: zoneCalendar)) { _ in
                AxisGridLine()
                if showsTimeLabels {
                    AxisValueLabel(format: Date.FormatStyle(timeZone: timeZone).hour())
                }
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

    private static let positive = WidgetPalette.color(70)
    private static let negative = WidgetPalette.color(40)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What drives this window")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(factors) { factor in
                VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Image(systemName: factor.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Theme.ink2)
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
                    effect(factor.value)
                }
                DivergingBar(value: factor.value, color: color(factor.value))
                    .padding(.leading, 32)
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

    /// Says in words which way the factor pushes, with up to three dots for how hard
    /// (about ±0.25 is the most a factor gives).
    private func effect(_ value: Double) -> some View {
        let tint = color(value)
        let strength = abs(value) <= 0.02 ? 0 : abs(value) < 0.08 ? 1 : abs(value) < 0.16 ? 2 : 3
        return HStack(spacing: 5) {
            Image(systemName: value > 0.02 ? "arrow.up" : value < -0.02 ? "arrow.down" : "minus")
                .font(.caption2.weight(.heavy))
            Text(value > 0.02 ? "Helps" : value < -0.02 ? "Hurts" : "Neutral")
                .font(.caption.weight(.semibold))
            if strength > 0 {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(i < strength ? tint : tint.opacity(0.25)).frame(width: 4, height: 4)
                    }
                }
            }
        }
        .foregroundStyle(tint)
        .padding(.vertical, 5)
        .padding(.horizontal, 9)
        .background(tint.opacity(0.13), in: .capsule)
        .fixedSize()
    }
}

/// A factor's push as a bar from a centre line: right helps, left hurts; ±0.25 fills a side.
private struct DivergingBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let half = proxy.size.width / 2
            let length = min(1, abs(value) / 0.25) * half
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.well)
                Rectangle().fill(Color.secondary.opacity(0.5))
                    .frame(width: 1.5, height: proxy.size.height + 4)
                    .offset(x: half - 0.75)
                Capsule().fill(color)
                    .frame(width: max(abs(value) > 0.02 ? 3 : 0, length))
                    .offset(x: value >= 0 ? half : half - length)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
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

/// Apple requires its Weather mark and a link to its legal page wherever WeatherKit data is
/// shown (guideline 5.2.5). The forecast comes from WeatherKit through our server, so the app
/// has no WeatherKit entitlement and shows the mark as text.
struct AppleWeatherAttribution: View {
    static let legalURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "\u{F8FF} Weather")
                .accessibilityLabel(Text(verbatim: "Apple Weather"))
            Link("Other data sources", destination: Self.legalURL)
                .tint(Theme.accent)
        }
        .font(.footnote)
    }
}
