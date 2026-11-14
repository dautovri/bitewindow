import SwiftUI
import WidgetKit

@main
struct BiteWidgetsBundle: WidgetBundle {
    var body: some Widget {
        BiteForecastWidget()
    }
}

struct BiteEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct BiteProvider: TimelineProvider {
    func placeholder(in context: Context) -> BiteEntry {
        BiteEntry(date: Date(), snapshot: .sample())
    }

    func getSnapshot(in context: Context, completion: @escaping (BiteEntry) -> Void) {
        // The widget gallery shows a filled example; a placed widget shows the real thing.
        completion(BiteEntry(date: Date(), snapshot: context.isPreview ? (WidgetSnapshot.load() ?? .sample()) : WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BiteEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.load()
        let dates = snapshot?.refreshDates(from: now).prefix(40) ?? [now]
        let entries = dates.map { BiteEntry(date: $0, snapshot: snapshot) }
        // The app reloads the timeline whenever it scores new forecasts; this is the fallback.
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(6 * 3600))))
    }
}

struct BiteForecastWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: BiteProvider()) { entry in
            BiteWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color("WidgetBackground") }
        }
        .configurationDisplayName("Bite forecast")
        .description("Your best spot and its best window, today or the next good day.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct BiteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BiteEntry

    private var picks: [WidgetSnapshot.Pick] { entry.snapshot?.picks(at: entry.date) ?? [] }

    var body: some View {
        if let first = picks.first {
            switch family {
            case .systemMedium: MediumView(picks: Array(picks.prefix(3)), now: entry.date)
            case .accessoryCircular: CircularView(pick: first)
            case .accessoryRectangular: RectangularView(pick: first, now: entry.date)
            case .accessoryInline:
                Text(verbatim: "\(first.spot.name) \(Int(first.index.rounded())) · \(clock(first.start, first.spot.timeZone))")
            default: SmallView(pick: first, now: entry.date)
            }
        } else {
            EmptyStateView(hasSpots: !(entry.snapshot?.spots.isEmpty ?? true), family: family)
        }
    }
}

private func clock(_ date: Date, _ timeZone: TimeZone) -> String {
    var style = Date.FormatStyle(date: .omitted, time: .shortened)
    style.timeZone = timeZone
    return date.formatted(style)
}

/// "Today" is left unsaid; a later day is named.
private func dayLabel(_ pick: WidgetSnapshot.Pick) -> String? {
    guard pick.isLater else { return nil }
    var style = Date.FormatStyle().weekday(.wide)
    style.timeZone = pick.spot.timeZone
    return pick.day.date.formatted(style)
}

private struct Ring: View {
    let index: Double
    var size: CGFloat = 58

    var body: some View {
        let width = max(4, size * 0.12)
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: width)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, index)) / 100))
                .stroke(WidgetPalette.color(index), style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(verbatim: "\(Int(index.rounded()))")
                .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
    }
}

private struct SmallView: View {
    let pick: WidgetSnapshot.Pick
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Ring(index: pick.index)
                Spacer(minLength: 0)
                Image(systemName: "fish.fill")
                    .font(.footnote)
                    .foregroundStyle(WidgetPalette.accent)
            }
            Spacer(minLength: 0)
            Text(verbatim: pick.spot.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let day = dayLabel(pick) {
                Text(verbatim: day).font(.caption2).foregroundStyle(.secondary)
            }
            Text(verbatim: "\(clock(pick.start, pick.spot.timeZone)) – \(clock(pick.end, pick.spot.timeZone))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(WidgetPalette.color(pick.index))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MediumView: View {
    let picks: [WidgetSnapshot.Pick]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(picks, id: \.spot.id) { pick in
                HStack(spacing: 10) {
                    Ring(index: pick.index, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: pick.spot.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(verbatim: [dayLabel(pick), "\(clock(pick.start, pick.spot.timeZone)) – \(clock(pick.end, pick.spot.timeZone))"]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(WidgetPalette.color(pick.index))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
            if picks.count < 3 { Spacer(minLength: 0) }
        }
    }
}

private struct CircularView: View {
    let pick: WidgetSnapshot.Pick

    var body: some View {
        Gauge(value: pick.index, in: 0...100) {
            Image(systemName: "fish.fill")
        } currentValueLabel: {
            Text(verbatim: "\(Int(pick.index.rounded()))")
        }
        .gaugeStyle(.accessoryCircular)
        .accessibilityLabel(Text(verbatim: pick.spot.name))
    }
}

private struct RectangularView: View {
    let pick: WidgetSnapshot.Pick
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: pick.spot.name)
                .font(.headline)
                .lineLimit(1)
                .widgetAccentable()
            Text(verbatim: [dayLabel(pick), "\(clock(pick.start, pick.spot.timeZone)) – \(clock(pick.end, pick.spot.timeZone))"]
                .compactMap { $0 }.joined(separator: " · "))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("Bite index \(Int(pick.index.rounded()))")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EmptyStateView: View {
    let hasSpots: Bool
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryCircular:
            Image(systemName: "fish.fill")
        case .accessoryInline:
            Text(verbatim: "BiteCurve")
        default:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "fish.fill").foregroundStyle(WidgetPalette.accent)
                Text(hasSpots ? "Open BiteCurve to update the forecast." : "Add a spot in BiteCurve to see its bite forecast here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

extension WidgetSnapshot {
    /// Example data for the widget gallery.
    static func sample(now: Date = Date()) -> WidgetSnapshot {
        let today = Calendar.current.startOfDay(for: now)
        func spot(_ name: String, _ index: Double, _ hour: Double) -> Spot {
            let start = today.addingTimeInterval(hour * 3600)
            let late = max(start, now.addingTimeInterval(1800))
            return Spot(id: UUID(), name: name, timeZoneID: TimeZone.current.identifier,
                        days: [Day(date: today, index: index, start: late, end: late.addingTimeInterval(7200))])
        }
        return WidgetSnapshot(updated: now, spots: [spot("Lake Fork", 72, 16), spot("Mill Pond", 58, 17.5), spot("North Bay", 44, 6)])
    }
}
