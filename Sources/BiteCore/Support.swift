import Foundation

// MARK: - Personalization

/// Conjugate Gamma–Poisson catch-rate multiplier for one user or one water body.
/// `mean` multiplies the global expected catch; it shrinks toward 1 until
/// roughly 20–30 trips have been logged. Zero-catch trips must be included.
public struct CatchRateMultiplier: Codable, Sendable, Equatable {
    public private(set) var alpha: Double
    public private(set) var beta: Double

    public init(alpha: Double = 5, beta: Double = 5) {
        self.alpha = alpha; self.beta = beta
    }

    public var mean: Double { alpha / beta }

    /// - Parameters:
    ///   - catches: fish caught on the trip (may be 0).
    ///   - expected: model-expected catch for that trip (rate × hours).
    public mutating func update(catches: Int, expected: Double) {
        guard catches >= 0, expected > 0 else { return }
        alpha += Double(catches)
        beta += expected
    }
}

// MARK: - Pressure

public enum Barometry {
    public static func hPa(fromKPa kPa: Double) -> Double { kPa * 10 }

    /// Device samples older than this are never read again: `fuse` only uses
    /// readings taken during a trip, and trips over `CatchModel.maxTripHours`
    /// are ignored. Three days leaves margin for a trip left running.
    public static let sampleRetention: TimeInterval = 72 * 3600

    /// Reduces station pressure to sea level.
    public static func seaLevel(stationHPa p: Double, altitudeMeters h: Double, tempC t: Double) -> Double {
        p * pow(1 - 0.0065 * h / (t + 0.0065 * h + 273.15), -5.257)
    }

    /// Median offset of device readings against forecast pressure at the same instants.
    public static func bias(device: [Double], forecast: [Double]) -> Double? {
        let diffs = zip(device, forecast).map { $0 - $1 }.sorted()
        guard !diffs.isEmpty else { return nil }
        let mid = diffs.count / 2
        return diffs.count % 2 == 0 ? (diffs[mid - 1] + diffs[mid]) / 2 : diffs[mid]
    }
}

// MARK: - Geohash

public enum Geohash {
    private static let alphabet = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    public static func encode(latitude: Double, longitude: Double, precision: Int = 5) -> String {
        var lat = (-90.0, 90.0), lon = (-180.0, 180.0)
        var hash = "", bit = 0, ch = 0, even = true
        while hash.count < precision {
            if even {
                let mid = (lon.0 + lon.1) / 2
                if longitude >= mid { ch = ch << 1 | 1; lon.0 = mid } else { ch = ch << 1; lon.1 = mid }
            } else {
                let mid = (lat.0 + lat.1) / 2
                if latitude >= mid { ch = ch << 1 | 1; lat.0 = mid } else { ch = ch << 1; lat.1 = mid }
            }
            even.toggle()
            bit += 1
            if bit == 5 { hash.append(alphabet[ch]); bit = 0; ch = 0 }
        }
        return hash
    }

    /// Centre of the cell, or nil for an invalid hash.
    public static func decode(_ hash: String) -> (latitude: Double, longitude: Double)? {
        var lat = (-90.0, 90.0), lon = (-180.0, 180.0)
        var even = true
        for c in hash.lowercased() {
            guard let idx = alphabet.firstIndex(of: c) else { return nil }
            for shift in stride(from: 4, through: 0, by: -1) {
                let on = (idx >> shift) & 1 == 1
                if even {
                    let mid = (lon.0 + lon.1) / 2
                    if on { lon.0 = mid } else { lon.1 = mid }
                } else {
                    let mid = (lat.0 + lat.1) / 2
                    if on { lat.0 = mid } else { lat.1 = mid }
                }
                even.toggle()
            }
        }
        return hash.isEmpty ? nil : ((lat.0 + lat.1) / 2, (lon.0 + lon.1) / 2)
    }
}
