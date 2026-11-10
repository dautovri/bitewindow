import BiteCore
import CoreMotion
import Observation

/// Reads the phone barometer through CMAltimeter. Foreground only.
/// Requires NSMotionUsageDescription. The altimeter instance is held strongly
/// for the lifetime of the sampler — a short-lived instance delivers nothing.
@MainActor
@Observable
final class PressureSampler {
    private let altimeter = CMAltimeter()
    private var burst: [Double] = []
    private var lastStored: Date?

    private(set) var latestHPa: Double?
    private(set) var isRunning = false

    var isAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    /// `onSample` receives a 10-reading mean of station pressure, at most once per 10 minutes.
    func start(onSample: @escaping (Double) -> Void) {
        guard isAvailable, !isRunning else { return }
        isRunning = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let kPa = data?.pressure.doubleValue else { return }
            Task { @MainActor in
                self?.ingest(Barometry.hPa(fromKPa: kPa), onSample: onSample)
            }
        }
    }

    func stop() {
        altimeter.stopRelativeAltitudeUpdates()
        isRunning = false
        burst.removeAll()
    }

    private func ingest(_ hPa: Double, onSample: (Double) -> Void) {
        burst.append(hPa)
        guard burst.count >= 10 else { return }
        let mean = burst.reduce(0, +) / Double(burst.count)
        burst.removeAll()
        latestHPa = mean
        let now = Date()
        if lastStored == nil || now.timeIntervalSince(lastStored!) >= 600 {
            lastStored = now
            onSample(mean)
        }
    }
}
