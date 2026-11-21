import BiteCore
import Foundation
import os

struct Forecast {
    enum Source { case live, cached, sample }
    /// Why a `.cached` forecast is shown instead of a live one.
    enum Unavailable {
        /// No network, or the server could not be reached.
        case offline
        /// The server answered but had no fresh forecast to give: too many requests (429),
        /// today's weather budget spent (503 "budget"), or another error.
        case serviceBusy
    }
    let hours: [HourConditions]
    let source: Source
    /// When the data was downloaded from the weather service. Nil for sample weather and when
    /// nothing is saved.
    var fetchedAt: Date? = nil
    /// Set for `.cached`: why the live forecast could not be had.
    var unavailable: Unavailable? = nil
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
        /// When the server got this forecast from WeatherKit (missing in very old saved files).
        let fetchedAt: String?
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

    // MARK: One download per place at a time

    /// Requests already on their way, by key. The refresh, a spot card and the detail screen
    /// often ask for the same place at the same moment; they all wait for one request.
    private final class Flights<Value> {
        private let lock = NSLock()
        private var tasks: [String: Task<Value, Never>] = [:]

        func run(_ key: String, _ work: @escaping () async -> Value) async -> Value {
            let task = lock.withLock {
                if let running = tasks[key] { return running }
                let task = Task { await work() }
                tasks[key] = task
                return task
            }
            let value = await task.value
            lock.withLock { if tasks[key] == task { tasks[key] = nil } }
            return value
        }
    }

    private let forecastFlights = Flights<Forecast>()
    private let tideFlights = Flights<TideStation?>()
    private let waterFlights = Flights<WaterEstimate?>()

    /// When each place's forecast last came in live, so a second ask within two minutes
    /// is answered from disk instead of the network.
    private let liveLock = NSLock()
    private var lastLive: [String: Date] = [:]
    private static let liveReuse: TimeInterval = 120

    func forecast(latitude: Double, longitude: Double) async -> Forecast {
        let gh = Geohash.encode(latitude: latitude, longitude: longitude, precision: 5)
        guard baseURL != nil else { return Forecast(hours: Self.sampleHours(), source: .sample) }
        let recent = liveLock.withLock { lastLive[gh].map { Date().timeIntervalSince($0) < Self.liveReuse } ?? false }
        if recent, let saved = cached(latitude: latitude, longitude: longitude) {
            return Forecast(hours: saved.hours, source: .live, fetchedAt: saved.fetchedAt)
        }
        let result = await forecastFlights.run(gh) { await self.downloadForecast(gh: gh, latitude: latitude, longitude: longitude) }
        if result.source == .live { liveLock.withLock { lastLive[gh] = Date() } }
        return result
    }

    private func downloadForecast(gh: String, latitude: Double, longitude: Double) async -> Forecast {
        guard let baseURL else { return Forecast(hours: Self.sampleHours(), source: .sample) }

        var components = URLComponents(url: baseURL.appendingPathComponent("wx"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "gh", value: gh)]
        var unavailable = Forecast.Unavailable.offline
        if let url = components?.url, let (data, response) = await download(url) {
            // Any answer from the server means the network is there; 429 (rate limit) and
            // 503 (daily weather budget spent) mean it has nothing fresh to give right now.
            unavailable = .serviceBusy
            let http = response as? HTTPURLResponse
            if http?.statusCode == 200, case let (hours, fetchedAt)? = Self.decode(data), !hours.isEmpty {
                if http?.value(forHTTPHeaderField: "x-cache") == "stale" {
                    // The server's last good copy while its budget is spent: shown as saved data
                    // with its own time, and kept only when it is newer than the copy on disk.
                    let serverTime = fetchedAt ?? .distantPast
                    // Read now, not before the request: another view may have saved a newer copy meanwhile.
                    if let saved = cached(latitude: latitude, longitude: longitude), (saved.fetchedAt ?? .distantPast) >= serverTime {
                        return Forecast(hours: saved.hours, source: .cached, fetchedAt: saved.fetchedAt, unavailable: .serviceBusy)
                    }
                    try? data.write(to: Self.cacheFile(gh), options: .atomic)
                    return Forecast(hours: hours, source: .cached, fetchedAt: fetchedAt, unavailable: .serviceBusy)
                }
                try? data.write(to: Self.cacheFile(gh), options: .atomic)
                return Forecast(hours: hours, source: .live, fetchedAt: fetchedAt ?? Date())
            }
        }
        guard let saved = cached(latitude: latitude, longitude: longitude) else {
            return Forecast(hours: [], source: .cached, unavailable: unavailable)
        }
        return Forecast(hours: saved.hours, source: .cached, fetchedAt: saved.fetchedAt, unavailable: unavailable)
    }

    /// One GET that finishes even when the caller is cancelled. Views load in `.task`, which
    /// SwiftUI cancels whenever the view is rebuilt (a tab switch right after adding a spot did
    /// exactly that); a cancelled request left a new spot without weather until the next launch.
    private func download(_ url: URL) async -> (Data, URLResponse)? {
        let session = session
        var request = URLRequest(url: url)
        // Lets the worker answer with its last good copy (`x-cache: stale`) when its daily
        // WeatherKit budget is spent; app 1.2.0 never sends this and gets a 503 instead.
        request.setValue("1", forHTTPHeaderField: "x-accept-stale")
        return await Task.detached {
            do {
                return try await session.data(for: request)
            } catch {
                Logger(subsystem: "com.dautovri.bitecurve", category: "network")
                    .info("GET \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value
    }

    /// One JSON POST to the worker; the HTTP status, or nil when it could not be reached.
    func post(path: String, body: Data) async -> Int? {
        guard let baseURL else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let session = session
        return await Task.detached {
            ((try? await session.data(for: request))?.1 as? HTTPURLResponse)?.statusCode
        }.value
    }

    /// The forecast saved on disk for this location, without touching the network.
    func cached(latitude: Double, longitude: Double) -> Forecast? {
        let file = Self.cacheFile(Geohash.encode(latitude: latitude, longitude: longitude, precision: 5))
        guard let data = try? Data(contentsOf: file), case let (hours, fetchedAt)? = Self.decode(data), !hours.isEmpty else { return nil }
        // The server's own time when the file has it: a copy saved from the server's cache can
        // be up to an hour older than the moment it was saved here.
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        return Forecast(hours: hours, source: .cached, fetchedAt: fetchedAt ?? attributes?[.modificationDate] as? Date)
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
            await waterEstimate(latitude: place.latitude, longitude: place.longitude, isSalt: place.isSalt)
        }
        if saved > 0 {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastPrefetchKey)
        }
        return saved
    }

    /// The bite curve over a finished trip from the real forecast. Empty with sample weather
    /// or no spot, so the personal fit and the scorecard never learn from synthetic conditions.
    func tripPoints(context: SpotContext?, from: Date, to: Date) async -> [ScorePoint] {
        guard let context else { return [] }
        let forecast = await forecast(latitude: context.latitude, longitude: context.longitude)
        guard forecast.source != .sample else { return [] }
        // One step past the end, so the curve brackets the whole trip however short it was.
        return Forecaster.curve(context: context, hours: forecast.hours, from: from, to: to.addingTimeInterval(900))
    }

    // MARK: Water temperature

    /// Estimated water temperature for a spot from the backend (`/water`): the satellite
    /// sea-surface analysis at sea, a model from 30 days of air temperature inland.
    struct WaterEstimate: Codable, Equatable {
        enum Source: String, Codable { case sst, air }
        let tempC: Double
        let source: Source
    }

    private struct WaterPayload: Codable {
        let tempC: Double?
        let source: String?
    }

    /// The estimate saved on disk, without touching the network. Water changes by tenths of a
    /// degree a day, so a copy up to ten days old is still better than none (offline trips).
    func cachedWaterEstimate(latitude: Double, longitude: Double, isSalt: Bool) -> WaterEstimate? {
        let file = Self.waterFile(latitude: latitude, longitude: longitude, isSalt: isSalt)
        // Asked on every redraw of a spot: the disk is read at most once a minute per spot.
        waterLock.lock()
        if let memo = waterMemo[file.path], Date().timeIntervalSince(memo.at) < 60 {
            waterLock.unlock()
            return memo.estimate
        }
        waterLock.unlock()
        let estimate = readWaterEstimate(file)
        waterLock.lock()
        waterMemo[file.path] = (estimate, Date())
        waterLock.unlock()
        return estimate
    }

    private let waterLock = NSLock()
    private var waterMemo: [String: (estimate: WaterEstimate?, at: Date)] = [:]

    private func readWaterEstimate(_ file: URL) -> WaterEstimate? {
        guard let saved = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
              Date().timeIntervalSince(saved) < 10 * 86_400,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(WaterEstimate.self, from: data)
    }

    /// Downloads the estimate when the saved one is older than 12 hours. Returns the best
    /// available answer; nil with no backend, no network and nothing saved, or no estimate.
    @discardableResult
    func waterEstimate(latitude: Double, longitude: Double, isSalt: Bool) async -> WaterEstimate? {
        let file = Self.waterFile(latitude: latitude, longitude: longitude, isSalt: isSalt)
        let cached = cachedWaterEstimate(latitude: latitude, longitude: longitude, isSalt: isSalt)
        if cached != nil, let saved = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(saved) < 12 * 3600 { return cached }
        return await waterFlights.run(file.path) {
            await self.downloadWaterEstimate(latitude: latitude, longitude: longitude, isSalt: isSalt, cached: cached)
        }
    }

    private func downloadWaterEstimate(latitude: Double, longitude: Double, isSalt: Bool,
                                       cached: WaterEstimate?) async -> WaterEstimate? {
        let file = Self.waterFile(latitude: latitude, longitude: longitude, isSalt: isSalt)
        guard let baseURL else { return cached }
        var components = URLComponents(url: baseURL.appendingPathComponent("water"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "gh", value: Geohash.encode(latitude: latitude, longitude: longitude, precision: 5)),
            URLQueryItem(name: "kind", value: isSalt ? "salt" : "fresh"),
        ]
        guard let url = components?.url,
              let result = await download(url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder().decode(WaterPayload.self, from: result.0),
              let temp = payload.tempC, let source = payload.source.flatMap(WaterEstimate.Source.init(rawValue:)),
              (-3...40).contains(temp) else { return cached }
        let estimate = WaterEstimate(tempC: temp, source: source)
        if let data = try? JSONEncoder().encode(estimate) { try? data.write(to: file, options: .atomic) }
        waterLock.lock()
        waterMemo[file.path] = (estimate, Date())
        waterLock.unlock()
        return estimate
    }

    private static func waterFile(latitude: Double, longitude: Double, isSalt: Bool) -> URL {
        let gh = Geohash.encode(latitude: latitude, longitude: longitude, precision: 5)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("water-\(isSalt ? "salt" : "fresh")-\(gh).json")
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
        let cached = Self.savedTide(file)
        if let cached {
            let saved = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            let maxAge: TimeInterval = cached.station == nil ? 86_400 : 30 * 86_400
            if let saved, Date().timeIntervalSince(saved) < maxAge { return cached.station }
        }
        return await tideFlights.run(gh) { await self.downloadTide(gh: gh, file: file, cached: cached?.station) }
    }

    /// The saved tide station, however old, without touching the network.
    func cachedTideStation(latitude: Double, longitude: Double) -> TideStation? {
        let gh = Geohash.encode(latitude: latitude, longitude: longitude, precision: 5)
        return Self.savedTide(Self.cacheFile("tide-\(gh)"))?.station
    }

    private static func savedTide(_ file: URL) -> TidePayload? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(TidePayload.self, from: $0) }
    }

    private func downloadTide(gh: String, file: URL, cached: TideStation?) async -> TideStation? {
        guard let baseURL else { return cached }
        var components = URLComponents(url: baseURL.appendingPathComponent("tide"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "gh", value: gh)]
        guard let url = components?.url,
              let result = await download(url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder().decode(TidePayload.self, from: result.0) else { return cached }
        try? result.0.write(to: file, options: .atomic)
        return payload.station
    }

    /// The hours of a worker answer, and when the worker fetched them.
    private static func decode(_ data: Data) -> ([HourConditions], Date?)? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fetchedAt = payload.fetchedAt.flatMap { plain.date(from: $0) ?? fractional.date(from: $0) }
        let hours: [HourConditions] = payload.hours.compactMap { h in
            guard let time = plain.date(from: h.t) ?? fractional.date(from: h.t) else { return nil }
            return HourConditions(time: time, pressureHPa: h.p, cloudCover: h.c,
                                  windSpeedKmh: h.ws, windFromDeg: h.wd, airTempC: h.ta)
        }
        // A time in the future would make a saved copy look fresher than it is.
        return (hours, fetchedAt.map { min($0, Date()) })
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
