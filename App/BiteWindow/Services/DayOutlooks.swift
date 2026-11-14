import BiteCore
import Foundation

/// One day at a spot: its best two-hour window, if the forecast still has one.
struct DayOutlook: Sendable, Identifiable, Equatable {
    /// Midnight at the spot.
    let date: Date
    let window: BiteWindow?
    var id: Date { date }
    var index: Double? { window?.meanIndex }
}

/// A spot's data in a form that can leave the main actor (the planner, alerts and widgets
/// score many days at once).
struct SpotSummaryInput: Sendable {
    let id: UUID
    let name: String
    let context: SpotContext
    let timeZone: TimeZone
    let hours: [HourConditions]

    var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar
    }
}

enum DayOutlooks {
    /// The next `days` days at a spot, today first, as the Forecast tab scores them: today's
    /// window starts no earlier than now. Empty without any forecast hours and no tide.
    static func compute(context: SpotContext, hours: [HourConditions], calendar: Calendar, days: Int,
                        now: Date = Date()) -> [DayOutlook] {
        let today = calendar.startOfDay(for: now)
        guard days > 0, let end = calendar.date(byAdding: .day, value: days, to: today) else { return [] }
        let points = Forecaster.curve(context: context, hours: hours, from: today, to: end, fillMissingWeather: true)
        let cutoff = now.addingTimeInterval(-900)
        let byDay = Dictionary(grouping: points.filter { $0.time < end }) { calendar.startOfDay(for: $0.time) }
        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let window = Forecaster.bestWindow(in: byDay[day] ?? [], notBefore: day == today ? cutoff : nil)
            return DayOutlook(date: day, window: window)
        }
    }

    /// Every saved spot with its saved forecast (no network), ready to score off the main actor.
    @MainActor
    static func inputs(for spots: [Spot]) async -> [SpotSummaryInput] {
        var out: [SpotSummaryInput] = []
        for spot in spots {
            let hours = ForecastService.shared.cached(latitude: spot.latitude, longitude: spot.longitude)?.hours ?? []
            var context = spot.context
            if spot.isSalt {
                context.tide = await ForecastService.shared.tideStation(latitude: spot.latitude, longitude: spot.longitude)
            }
            out.append(SpotSummaryInput(id: spot.id, name: spot.name, context: context, timeZone: spot.timeZone, hours: hours))
        }
        return out
    }

    /// `days` days for each spot, computed off the main actor.
    static func compute(_ inputs: [SpotSummaryInput], days: Int, now: Date = Date()) async -> [UUID: [DayOutlook]] {
        await Task.detached(priority: .userInitiated) {
            var out: [UUID: [DayOutlook]] = [:]
            for input in inputs {
                out[input.id] = compute(context: input.context, hours: input.hours, calendar: input.calendar, days: days, now: now)
            }
            return out
        }.value
    }
}
