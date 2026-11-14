import BiteCore
import CoreLocation
import Observation

/// What Apple's geocoder knows about a point on the map: the lake, river or sea there (if
/// any), the country and the time zone. Needs a connection but no location permission: the
/// coordinates are the crosshair's, not the phone's.
struct SpotSuggestion: Sendable {
    /// The water's name, e.g. "Lake Minnetonka" or "Baltic Sea".
    var waterName: String?
    /// Salt when the point is in a sea, fresh in inland water; nil when neither was found.
    var water: WaterType?
    var regionCode: String?
    var timeZoneID: String?
    /// False when the geocoder did not answer in time (offline): nothing is known either way.
    var answered = false

    /// The geocoder answered and found no water at the point.
    var looksLikeLand: Bool { answered && water == nil }

    /// Asks the geocoder, giving up after `timeout` seconds so adding a spot never hangs. The
    /// two run as separate tasks and the first to finish answers: a task group would wait for
    /// the geocoder even after the timeout, and offline that can take half a minute.
    static func lookup(latitude: Double, longitude: Double, timeout: TimeInterval = 3) async -> SpotSuggestion {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<SpotSuggestion, Never>) in
            Task {
                let found = await geocode(latitude: latitude, longitude: longitude)
                if await once.claim() { continuation.resume(returning: found ?? SpotSuggestion()) }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if await once.claim() { continuation.resume(returning: SpotSuggestion()) }
            }
        }
    }

    /// Lets exactly one of the two racers resume the continuation.
    private actor Once {
        private var claimed = false
        func claim() -> Bool {
            if claimed { return false }
            claimed = true
            return true
        }
    }

    private static func geocode(latitude: Double, longitude: Double) async -> SpotSuggestion? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        var suggestion = SpotSuggestion(answered: true)
        suggestion.regionCode = placemark.isoCountryCode
        suggestion.timeZoneID = placemark.timeZone?.identifier
        if let lake = placemark.inlandWater, !lake.isEmpty {
            suggestion.waterName = lake
            suggestion.water = .warmFreshwater
        } else if let sea = placemark.ocean, !sea.isEmpty {
            suggestion.waterName = sea
            suggestion.water = .inshoreSalt
        }
        return suggestion
    }
}

/// Centres the map on the phone, on request only. Location is never needed to use the app:
/// permission is asked the first time the button is tapped, and only "while using".
@MainActor
@Observable
final class LocationCenter: NSObject, @MainActor CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    /// Counts up each time the map should fly to the phone's position.
    private(set) var centerRequests = 0
    /// True after the user refused: the button then explains where to allow it.
    private(set) var isDenied = false
    @ObservationIgnored private var wantsCenter = false

    override init() {
        super.init()
        manager.delegate = self
        isAuthorized = statusAllows
    }

    /// Observed, so the map shows the "you are here" dot only once location is allowed:
    /// asking MapKit for the dot earlier would make iOS show the permission prompt unasked.
    private(set) var isAuthorized = false

    private var statusAllows: Bool {
        manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
    }

    func requestCenter() {
        switch manager.authorizationStatus {
        case .notDetermined:
            wantsCenter = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            isDenied = true
        default:
            centerRequests += 1
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        isDenied = manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
        isAuthorized = statusAllows
        if wantsCenter, isAuthorized {
            wantsCenter = false
            centerRequests += 1
        }
    }
}
