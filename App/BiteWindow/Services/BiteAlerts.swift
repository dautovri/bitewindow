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
    private static let maxPending = 60
    /// Category of the "How did it go?" notification after an alerted window, and its actions.
    nonisolated static let afterCategory = "bite.after"
    static let actionNoFish = "bite.after.0"
    static let actionOneFish = "bite.after.1"
    static let actionMoreFish = "bite.after.more"
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

    /// The latest reschedule; the next one waits for it. Two running at once could each cancel
    /// before the other adds, leaving alerts from an older forecast behind.
    private static var last: Task<Void, Never>?

    /// Replaces the pending alerts with ones worked out from the saved forecasts.
    /// Does nothing visible when alerts are off or not allowed. Calls run one after another;
    /// `now` defaults to the moment each one starts.
    static func reschedule(now: Date? = nil) async {
        let previous = last
        let task = Task { @MainActor in
            await previous?.value
            await run(now: now ?? Date())
        }
        last = task
        await task.value
    }

    private static func run(now: Date) async {
        let center = UNUserNotificationCenter.current()
        let spots = (try? OfflineStore.container.mainContext.fetch(FetchDescriptor<Spot>())) ?? []
        let busy = Set(spots.filter { $0.activeTrip != nil }.map(\.id))
        let existing = Set(spots.map(\.id))
        // An "after" notification whose window was already alerted stays as it is: once the
        // window has begun, today's forecast no longer offers it, so it could not be planned again.
        // Dropped only when that spot now has a running trip or no longer exists.
        var kept: Set<String> = []
        for request in await center.pendingNotificationRequests() where request.identifier.hasPrefix(prefix + "after.") {
            let info = request.content.userInfo
            guard let start = info["start"] as? Double,
                  let spot = (info["spotID"] as? String).flatMap(UUID.init(uuidString:)), existing.contains(spot), !busy.contains(spot),
                  start - 3600 <= now.timeIntervalSince1970 + 300 else { continue }
            kept.insert(request.identifier)
        }
        let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) && !kept.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        guard isEnabled, await isAuthorized() else {
            center.removePendingNotificationRequests(withIdentifiers: Array(kept))
            return
        }
        let inputs = await DayOutlooks.inputs(for: spots)
        // Free users get alerts for the days they can see in the app: today and tomorrow.
        let horizon = EntitlementManager.cachedIsPro ? horizonDays : EntitlementManager.freeDays
        let days = await DayOutlooks.compute(inputs, days: horizon, now: now)
        let plan = plan(inputs: inputs, days: days, threshold: threshold, now: now, busySpots: busy,
                        keptAfterIDs: Set(kept.map { String($0.dropFirst(prefix.count)) }))
        Logger(subsystem: "com.dautovri.bitecurve", category: "alerts")
            .info("scheduling \(min(plan.count, maxPending)) bite alerts, first: \(plan.first.map { "\($0.fireDate.formatted(.iso8601)) \($0.title) | \($0.body)" } ?? "-", privacy: .public)")
        for alert in plan.prefix(max(0, maxPending - kept.count)) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            if let window = alert.window {
                content.categoryIdentifier = afterCategory
                content.userInfo = ["spotID": window.spotID.uuidString,
                                    "start": window.start.timeIntervalSince1970,
                                    "end": window.end.timeIntervalSince1970]
            }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, alert.fireDate.timeIntervalSince(Date())), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: prefix + alert.id, content: content, trigger: trigger))
        }
    }

    struct Alert: Equatable {
        /// The window an "after" notification asks about.
        struct Window: Equatable {
            let spotID: UUID
            let start: Date
            let end: Date
        }

        let id: String
        let fireDate: Date
        let title: String
        let body: String
        var window: Window? = nil
    }

    /// The alerts for these forecasts, soonest first. Pure, so it can be tested.
    /// `busySpots`: spots with a running trip (no "how did it go?" for them). `keptAfterIDs`:
    /// "after" notifications still pending from an earlier plan, left alone.
    nonisolated static func plan(inputs: [SpotSummaryInput], days: [UUID: [DayOutlook]], threshold: Double,
                                 now: Date, busySpots: Set<UUID> = [], keptAfterIDs: Set<String> = []) -> [Alert] {
        var alerts: [Alert] = []
        // Best qualifying spot per evening, for the "tomorrow" heads-up.
        var eveBest: [Date: (input: SpotSummaryInput, window: BiteWindow)] = [:]

        for input in inputs {
            for day in days[input.id] ?? [] {
                guard let window = day.window, window.meanIndex >= threshold else { continue }
                let index = Int(window.meanIndex.rounded())
                let range = "\(window.start.clock(in: input.timeZone)) – \(window.end.clock(in: input.timeZone))"

                let soon = window.start.addingTimeInterval(-3600)
                let alerted = soon > now.addingTimeInterval(300)
                if alerted {
                    alerts.append(Alert(id: "soon.\(input.id.uuidString).\(Int(day.date.timeIntervalSince1970))",
                                        fireDate: soon,
                                        title: input.name,
                                        body: String(localized: "Best window starts in an hour: \(range), bite index \(index).")))
                }

                // A quarter of an hour after the window, one tap logs how it went. Only for
                // windows alerted in this plan, so switching alerts on mid-window never asks.
                let afterID = "after.\(input.id.uuidString).\(Int(day.date.timeIntervalSince1970))"
                let after = window.end.addingTimeInterval(900)
                if alerted, !busySpots.contains(input.id), !keptAfterIDs.contains(afterID), after > now.addingTimeInterval(300) {
                    alerts.append(Alert(id: afterID, fireDate: after, title: input.name,
                                        body: String(localized: "How did \(range) go?"),
                                        window: .init(spotID: input.id, start: window.start, end: window.end)))
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

/// Receives taps on BiteCurve's notifications: the "How did it go?" actions log the trip.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()

    /// Installs the handler and the "after" actions. Call once at launch.
    @MainActor
    static func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        let none = UNNotificationAction(identifier: BiteAlerts.actionNoFish, title: String(localized: "No fish"), options: [])
        let one = UNNotificationAction(identifier: BiteAlerts.actionOneFish, title: String(localized: "1 fish"), options: [])
        let more = UNTextInputNotificationAction(identifier: BiteAlerts.actionMoreFish, title: String(localized: "2+ fish"), options: [],
                                                 textInputButtonTitle: String(localized: "Save"),
                                                 textInputPlaceholder: String(localized: "Fish"))
        center.setNotificationCategories([UNNotificationCategory(identifier: BiteAlerts.afterCategory,
                                                                 actions: [none, one, more], intentIdentifiers: [])])
    }

    /// Alerts show while the app is open too.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard response.notification.request.content.categoryIdentifier == BiteAlerts.afterCategory,
              let id = (info["spotID"] as? String).flatMap(UUID.init(uuidString:)),
              let start = info["start"] as? Double, let end = info["end"] as? Double else { return }
        let catches: Int
        switch response.actionIdentifier {
        case BiteAlerts.actionNoFish: catches = 0
        case BiteAlerts.actionOneFish: catches = 1
        case BiteAlerts.actionMoreFish:
            // The first number typed, 2 to 500; 2 when there is none.
            let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
            let digits = text.drop { !$0.isASCII || !$0.isNumber }.prefix { $0.isASCII && $0.isNumber }
            catches = min(max(Int(digits) ?? 2, 2), 500)
        default: return
        }
        await TripRecorder.logWindow(spotID: id, start: Date(timeIntervalSince1970: start),
                                     end: Date(timeIntervalSince1970: end), catches: catches)
    }
}
