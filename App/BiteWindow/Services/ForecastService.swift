import BiteCore
import Foundation

struct Forecast {
    enum Source { case live, cached, sample }
    let hours: [HourConditions]
    let source: Source
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

    private var baseURL: URL? {
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
                let (data, response) = try await URLSession.shared.data(from: url)
                if (response as? HTTPURLResponse)?.statusCode == 200, let hours = Self.decode(data), !hours.isEmpty {
                    try? data.write(to: Self.cacheFile(gh), options: .atomic)
                    return Forecast(hours: hours, source: .live)
                }
            } catch {
                // Offline or backend down: fall through to the disk cache.
            }
        }
        if let data = try? Data(contentsOf: Self.cacheFile(gh)), let hours = Self.decode(data), !hours.isEmpty {
            return Forecast(hours: hours, source: .cached)
        }
        return Forecast(hours: [], source: .cached)
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
        return dir.appendingPathComponent("forecast-\(gh).json")
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
