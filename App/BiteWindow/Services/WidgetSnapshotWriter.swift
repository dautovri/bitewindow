import Foundation
import SwiftData
import WidgetKit

/// Writes what the widgets show (see `WidgetSnapshot`) from the saved forecasts and tells
/// WidgetKit to redraw. Called whenever forecasts are refreshed, the app comes forward or
/// the list of spots changes.
@MainActor
enum WidgetSnapshotWriter {
    static let days = 7

    static func update(now: Date = Date()) async {
        // The main context outlives this call; models from a throwaway context would dangle.
        let spots = (try? OfflineStore.container.mainContext.fetch(FetchDescriptor<Spot>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let inputs = await DayOutlooks.inputs(for: spots)
        let outlooks = await DayOutlooks.compute(inputs, days: days, now: now)
        let snapshot = WidgetSnapshot(updated: now, spots: inputs.map { input in
            WidgetSnapshot.Spot(id: input.id, name: input.name, timeZoneID: input.timeZone.identifier,
                                days: (outlooks[input.id] ?? []).map {
                                    .init(date: $0.date, index: $0.index, start: $0.window?.start, end: $0.window?.end)
                                })
        })
        // Nothing changed (same forecasts, same minute): spare the widgets a reload.
        if let old = WidgetSnapshot.load(), old.spots == snapshot.spots { return }
        if snapshot.save() {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
        }
    }
}
