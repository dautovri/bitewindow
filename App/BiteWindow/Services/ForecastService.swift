import BiteCore
import Foundation

struct Forecast {
    enum Source { case live, cached, sample }
    let hours: [HourConditions]
    let source: Source
    /// When the data was downloaded. Nil for sample weather and when nothing is saved.
    var fetchedAt: Date? = nil
}

/// Loads hourly weather from the cache worker (backend/), keyed by geohash-5.
/// Falls back to the last response on disk when offline, and to synthetic
/// sample weather when no backend is configured.
final class ForecastService {
    static let shared = ForecastService()

    private struct Payload: Codable {
        struct Hour: Codable {
            let t: String
            let p: Double
            let c: Double
            let ws: Double
            let wd: Double?
            let ta: Double
        }
        let gh: String
        let hours: [Hour]
    }

    /// One spot to keep available offline.
    struct Place: Sendable {
        let latitude: Double
        let longitude: Double
        let isSalt: Bool
    }

    /// UserDefaults key: time of the last successful `prefetch`, seconds since 1970.
    static let lastPrefetchKey = "lastPrefetch"

    /// Short timeouts: with one bar of signal the saved forecast should show
    /// within seconds, not after URLSession's default 60 s.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    var isConfigured: Bool { baseURL != nil }

    private var baseURL: URL? {
        #if DEBUG
        // `-BCAPIBase <url>` points Debug builds at another host (failure drills).
        if let override = UserDefaults.standard.string(forKey: "BCAPIBase"), let url = URL(string: override) { return url }
        #endif
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "BiteAPIBase") as? String,
              !raw.contains("REPLACE"), let url = URL(string: raw) else { return nil }
        return url
    }

    func forecast(latitude: Double, longitude: Double) async -> Forecast {
        let gh = Geohash.encode(latitude: latitude, longitude: longitude, precision: 5)
        guard let baseURL else { return Forecast(hours: Self.sampleHours(), source: .sample) }

        var components = URLComponents(url: baseURL.appendingPathComponent("wx"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "gh", value: gh)]
        if let url = components?.url {
            do {
                let (data, response) = try await session.data(from: url)
                if (response as? HTTPURLResponse)?.statusCode == 200, let hours = Self.decode(data), !hours.isEmpty {
                    try? data.write(to: Self.cacheFile(gh), options: .atomic)
                    return Forecast(hours: hours, source: .live, fetchedAt: Date())
                }
            } catch {
                // Offline or backend down: fall through to the disk cache.
            }
        }
        return cached(latitude: latitude, longitude: longitude) ?? Forecast(hours: [], source: .cached)
    }

    /// The forecast saved on disk for this location, without touching the network.
    func cached(latitude: Double, longitude: Double) -> Forecast? {
        let file = Self.cacheFile(Geohash.encode(latitude: latitude, longitude: longitude, precision: 5))
        guard let data = try? Data(contentsOf: file), let hours = Self.decode(data), !hours.isEmpty else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        return Forecast(hours: hours, source: .cached, fetchedAt: attributes?[.modificationDate] as? Date)
    }

    /// Downloads and saves the forecast (and tide constants for saltwater) for
    /// every place, so they are there when the signal is gone. Returns how many
    /// forecasts were saved.
    func prefetch(_ places: [Place]) async -> Int {
        guard isConfigured else { return 0 }
        var saved = 0
        for place in places {
            let result = await forecast(latitude: place.latitude, longitude: place.longitude)
            if result.source == .live { saved += 1 }
            if place.isSalt {
                _ = await tideStation(latitude: place.latitude, longitude: place.longitude)
            }
        }
        if saved > 0 {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastPrefetchKey)
        }
        return saved
    }

    /// Expected catch for a trip under the global model. Uses the real forecast
    /// when there is one; sample weather and missing data count as neutral, so
    /// the personal fit never learns from synthetic conditions.
    func expectedCatch(context: SpotContext?, from: Date, to: Date) async -> Double {
        var points: [ScorePoint] = []
        if let context {
            let forecast = await forecast(latitude: context.latitude, longitude: context.longitude)
            if forecast.source != .sample {
                points = Forecaster.curve(context: context, hours: forecast.hours, from: from, to: to)
            }
        }
        return CatchModel.expectedCatch(points: points, from: from, to: to)
    }

    private struct TidePayload: Codable {
        let gh: String
        let station: TideStation?
    }

    /// Harmonic constants for the nearest NOAA station, or nil when there is
    /// none in range, no backend, or no network and nothing cached. Constants
    /// change on the scale of years, but a saved answer is re-checked after 30
    /// days (1 day for "no station") so one bad response cannot stick for good.
    /// A stale copy is still used when the refresh fails.
    func tideStation(latitude: Double, longitude: Double) async -> TideStation? {
        let gh = Geohash.encode(latitude: latitude, longitude: longitude, precision: 5)
        let file = Self.cacheFile("tide-\(gh)")
        let cached = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(TidePayload.self, from: $0) }
        if let cached {
            let saved = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            let maxAge: TimeInterval = cached.station == nil ? 86_400 : 30 * 86_400
            if let saved, Date().timeIntervalSince(saved) < maxAge { return cached.station }
        }
        guard let baseURL else { return cached?.station }
        var components = URLComponents(url: baseURL.appendingPathComponent("tide"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "gh", value: gh)]
        guard let url = components?.url,
              let result = try? await session.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder().decode(TidePayload.self, from: result.0) else { return cached?.station }
        try? result.0.write(to: file, options: .atomic)
        return payload.station
    }

    private static func decode(_ data: Data) -> [HourConditions]? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return payload.hours.compactMap { h in
            guard let time = plain.date(from: h.t) ?? fractional.date(from: h.t) else { return nil }
            return HourConditions(time: time, pressureHPa: h.p, cloudCover: h.c,
                                  windSpeedKmh: h.ws, windFromDeg: h.wd, airTempC: h.ta)
        }
    }

    private static func cacheFile(_ gh: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(gh.hasPrefix("tide-") ? "\(gh).json" : "forecast-\(gh).json")
    }

    /// Deterministic synthetic weather so the app runs before the backend exists.
    static func sampleHours(now: Date = Date()) -> [HourConditions] {
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 3600).rounded(.down) * 3600 - 48 * 3600)
        return (0..<(48 + 240)).map { i in
            let x = Double(i)
            return HourConditions(time: start.addingTimeInterval(x * 3600),
                                  pressureHPa: 1015 + 6 * sin(x / 30),
                                  cloudCover: 0.5 + 0.4 * sin(x / 17),
                                  windSpeedKmh: 14 + 8 * sin(x / 11),
                                  windFromDeg: 240,
                                  airTempC: 16 + 5 * sin((x - 9) * .pi / 12))
        }
    }
}
