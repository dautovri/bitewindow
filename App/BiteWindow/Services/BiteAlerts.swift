import BiteCore
import Foundation
import SwiftData
import UserNotifications
import os

/// Local notifications for good bite windows, scheduled on the phone from the saved forecasts.
/// Nothing is sent from a server and nothing about the spots leaves the device.
///
/// Two kinds, both only for windows at or above the chosen index:
/// - an hour before a window starts ("Best window starts in an hour");
/// - at 19:00 the evening before the best such day among all spots ("Tomorrow looks strong").
///
/// Everything pending is replaced each time forecasts are refreshed (app comes forward,
/// background refresh), so an alert always reflects the latest forecast the phone has seen.
@MainActor
enum BiteAlerts {
    static let enabledKey = "biteAlertsEnabled"
    static let thresholdKey = "biteAlertThreshold"
    static let defaultThreshold = 65.0
    /// How far ahead alerts are laid out, so they keep coming for a week without the app opened.
    static let horizonDays = 7
    /// iOS keeps at most 64 pending notifications per app.
    private static let maxPending = 40
    private static let prefix = "bite."

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var threshold: Double {
        let stored = UserDefaults.standard.double(forKey: thresholdKey)
        return stored > 0 ? stored : defaultThreshold
    }

    /// Asks iOS for permission (the first time) and reports whether alerts can be shown.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    /// Removes every pending alert of ours.
    static func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
    }

    /// Replaces the pending alerts with ones worked out from the saved forecasts.
    /// Does nothing visible when alerts are off or not allowed.
    static func reschedule(now: Date = Date()) async {
        await cancelAll()
        guard isEnabled, await isAuthorized() else { return }
        // The main context outlives this call; models from a throwaway context would dangle.
        let spots = (try? OfflineStore.container.mainContext.fetch(FetchDescriptor<Spot>())) ?? []
        let inputs = await DayOutlooks.inputs(for: spots)
        let days = await DayOutlooks.compute(inputs, days: horizonDays, now: now)
        let plan = plan(inputs: inputs, days: days, threshold: threshold, now: now)
        Logger(subsystem: "com.dautovri.bitecurve", category: "alerts")
            .info("scheduling \(min(plan.count, maxPending)) bite alerts, first: \(plan.first.map { "\($0.fireDate.formatted(.iso8601)) \($0.title) | \($0.body)" } ?? "-", privacy: .public)")
        let center = UNUserNotificationCenter.current()
        for alert in plan.prefix(maxPending) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, alert.fireDate.timeIntervalSince(Date())), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: prefix + alert.id, content: content, trigger: trigger))
        }
    }

    struct Alert: Equatable {
        let id: String
        let fireDate: Date
        let title: String
        let body: String
    }

    /// The alerts for these forecasts, soonest first. Pure, so it can be tested.
    nonisolated static func plan(inputs: [SpotSummaryInput], days: [UUID: [DayOutlook]], threshold: Double,
                                 now: Date) -> [Alert] {
        var alerts: [Alert] = []
        // Best qualifying spot per evening, for the "tomorrow" heads-up.
        var eveBest: [Date: (input: SpotSummaryInput, window: BiteWindow)] = [:]

        for input in inputs {
            for day in days[input.id] ?? [] {
                guard let window = day.window, window.meanIndex >= threshold else { continue }
                let index = Int(window.meanIndex.rounded())
                let range = "\(window.start.clock(in: input.timeZone)) – \(window.end.clock(in: input.timeZone))"

                let soon = window.start.addingTimeInterval(-3600)
                if soon > now.addingTimeInterval(300) {
                    alerts.append(Alert(id: "soon.\(input.id.uuidString).\(Int(day.date.timeIntervalSince1970))",
                                        fireDate: soon,
                                        title: input.name,
                                        body: String(localized: "Best window starts in an hour: \(range), bite index \(index).")))
                }

                // 19:00 the evening before, on the spot's clock.
                if let eve = input.calendar.date(byAdding: .hour, value: -5, to: day.date), eve > now.addingTimeInterval(300) {
                    if let current = eveBest[eve], current.window.meanIndex >= window.meanIndex { continue }
                    eveBest[eve] = (input, window)
                }
            }
        }

        for (eve, best) in eveBest {
            let index = Int(best.window.meanIndex.rounded())
            let range = "\(best.window.start.clock(in: best.input.timeZone)) – \(best.window.end.clock(in: best.input.timeZone))"
            alerts.append(Alert(id: "eve.\(Int(eve.timeIntervalSince1970))",
                                fireDate: eve,
                                title: String(localized: "Tomorrow looks good for fishing"),
                                body: String(localized: "\(best.input.name): bite index \(index), best \(range).")))
        }
        return alerts.sorted { $0.fireDate < $1.fireDate }
    }
}
