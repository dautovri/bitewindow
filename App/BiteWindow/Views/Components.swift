import BiteCore
import Charts
import SwiftUI

/// Colour and wording for a bite index. 50 is neutral.
enum BiteScale {
    static func color(_ index: Double?) -> Color {
        guard let index else { return .secondary }
        switch index {
        case 65...: return .green
        case 50..<65: return .teal
        case 35..<50: return .orange
        default: return .red
        }
    }

    static func label(_ index: Double) -> String {
        switch index {
        case 65...: return "Strong bite"
        case 50..<65: return "Above average"
        case 35..<50: return "Below average"
        default: return "Slow"
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
        .accessibilityValue(index.map { "\(Int($0.rounded())) of 100" } ?? "not available")
    }
}

/// One day's bite curve with the best window shaded and a marker at the current time.
struct BiteCurveChart: View {
    let points: [ScorePoint]
    let window: BiteWindow?

    private var now: Date? {
        let t = Date()
        guard let first = points.first, let last = points.last, t >= first.time, t <= last.time else { return nil }
        return t
    }

    var body: some View {
        Chart {
            if let window {
                RectangleMark(xStart: .value("Window start", window.start), xEnd: .value("Window end", window.end))
                    .foregroundStyle(Color.green.opacity(0.16))
            }
            ForEach(points, id: \.time) { point in
                AreaMark(x: .value("Time", point.time), y: .value("Index", point.index))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Color.teal.opacity(0.35), Color.teal.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.time), y: .value("Index", point.index))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.teal)
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
        .chartYAxis { AxisMarks(values: [0, 50, 100]) }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .accessibilityLabel("Bite index through the day")
    }
}

struct TideChart: View {
    let samples: [TideStation.Sample]

    var body: some View {
        Chart(samples, id: \.time) { sample in
            AreaMark(x: .value("Time", sample.time), y: .value("Tide (m)", sample.height))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(LinearGradient(colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.03)],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", sample.time), y: .value("Tide (m)", sample.height))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Color.blue)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .accessibilityLabel("Tide height through the day")
    }
}

/// How much each factor pushes the index up or down, as diverging bars.
struct FactorBreakdown: View {
    struct Factor: Identifiable {
        let name: String
        /// Weighted contribution w·z; about ±0.25 at the extremes.
        let value: Double
        var id: String { name }
    }

    let factors: [Factor]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What drives this window")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(factors) { factor in
                HStack {
                    Text(factor.name).font(.subheadline)
                    Spacer()
                    bar(factor.value)
                    Image(systemName: factor.value > 0.02 ? "arrow.up" : factor.value < -0.02 ? "arrow.down" : "minus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(color(factor.value))
                        .frame(width: 16)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(factor.name)
                .accessibilityValue(factor.value > 0.02 ? "helps" : factor.value < -0.02 ? "hurts" : "neutral")
            }
        }
        .padding(.vertical, 4)
    }

    private func color(_ value: Double) -> Color {
        value > 0.02 ? .green : value < -0.02 ? .red : .secondary
    }

    private func bar(_ value: Double) -> some View {
        let half: CGFloat = 50
        let magnitude = CGFloat(min(1, abs(value) / 0.25))
        return ZStack {
            Capsule().fill(Color.secondary.opacity(0.15)).frame(width: half * 2, height: 6)
            Capsule().fill(color(value))
                .frame(width: max(2, half * magnitude), height: 6)
                .offset(x: (value < 0 ? -1 : 1) * half * magnitude / 2)
            Rectangle().fill(Color.secondary).frame(width: 1, height: 10)
        }
    }
}

struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
