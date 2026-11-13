import XCTest
@testable import BiteCore

final class BiteCoreTests: XCTestCase {
    func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: Astro

    func testJulianDayAtJ2000() {
        XCTAssertEqual(Astro.julianDay(utc(2000, 1, 1, 12)), 2451545.0, accuracy: 1e-6)
    }

    func testBerlinSolsticeSunriseSunset() {
        // Berlin, 21 June 2026: sunrise 04:43 CEST, sunset 21:33 CEST.
        let e = Astro.events(.sun, from: utc(2026, 6, 21), to: utc(2026, 6, 22), latitude: 52.52, longitude: 13.405)
        XCTAssertEqual(e.rises.count, 1)
        XCTAssertEqual(e.sets.count, 1)
        XCTAssertEqual(e.rises[0].timeIntervalSince(utc(2026, 6, 21, 2, 43)), 0, accuracy: 240)
        XCTAssertEqual(e.sets[0].timeIntervalSince(utc(2026, 6, 21, 19, 33)), 0, accuracy: 240)
    }

    func testSolarNoonAtGreenwichNearTwelve() {
        let e = Astro.events(.sun, from: utc(2026, 3, 20), to: utc(2026, 3, 21), latitude: 51.48, longitude: 0)
        XCTAssertEqual(e.upperTransits.count, 1)
        // Equation of time on 20 March is about -7.5 min, so transit is ~12:07 UT.
        XCTAssertEqual(e.upperTransits[0].timeIntervalSince(utc(2026, 3, 20, 12, 7)), 0, accuracy: 180)
    }

    func testMoonPhaseAtKnownNewAndFullMoon() {
        // New moon 2000-01-06 18:14 UT; full moon 2000-01-21 04:40 UT.
        let new = Astro.moonPhaseAngle(utc(2000, 1, 6, 18, 14))
        XCTAssertLessThan(min(new, 360 - new), 1.5)
        XCTAssertEqual(Astro.moonPhaseAngle(utc(2000, 1, 21, 4, 40)), 180, accuracy: 1.5)
        XCTAssertGreaterThan(Astro.moonIllumination(utc(2000, 1, 21, 4, 40)), 0.99)
    }

    func testMoonEventsAreConsistent() {
        let from = utc(2026, 11, 10), to = utc(2026, 11, 13)
        let e = Astro.events(.moon, from: from, to: to, latitude: 38.72, longitude: -9.14)
        // Lunar day is ~24h50m: expect 2–3 of each event in 72 h.
        for list in [e.rises, e.sets, e.upperTransits, e.lowerTransits] {
            XCTAssertTrue((2...4).contains(list.count), "got \(list.count)")
        }
        // Hour angle is ~0 at upper transit and altitude peaks there.
        for t in e.upperTransits {
            XCTAssertEqual(Astro.hourAngle(.moon, date: t, longitude: -9.14), 0, accuracy: 0.05)
            let a = Astro.altitude(.moon, date: t, latitude: 38.72, longitude: -9.14)
            XCTAssertGreaterThan(a, Astro.altitude(.moon, date: t.addingTimeInterval(3600), latitude: 38.72, longitude: -9.14))
            XCTAssertGreaterThan(a, Astro.altitude(.moon, date: t.addingTimeInterval(-3600), latitude: 38.72, longitude: -9.14))
        }
        // Successive upper transits are a lunar day apart.
        if e.upperTransits.count >= 2 {
            let gap = e.upperTransits[1].timeIntervalSince(e.upperTransits[0]) / 3600
            XCTAssertEqual(gap, 24.84, accuracy: 0.5)
        }
    }

    func testFullMoonRisesNearSunset() {
        // Full moon 2000-01-21: moonrise within ~75 min of sunset at mid latitudes.
        let day = utc(2000, 1, 20, 12), end = utc(2000, 1, 21, 12)
        let sun = Astro.events(.sun, from: day, to: end, latitude: 40, longitude: 0)
        let moon = Astro.events(.moon, from: day, to: end, latitude: 40, longitude: 0)
        XCTAssertEqual(moon.rises.count, 1)
        XCTAssertEqual(moon.rises[0].timeIntervalSince(sun.sets[0]), 0, accuracy: 75 * 60)
    }

    // MARK: Terms

    func testPressureTermSigns() {
        let t0 = utc(2026, 5, 1)
        func series(_ f: (Double) -> Double) -> Terms.PressureSeries {
            Terms.PressureSeries((0...72).map { (t0.addingTimeInterval(Double($0) * 3600), f(Double($0))) })
        }
        let at = t0.addingTimeInterval(60 * 3600)
        let stable = Terms.pressure(series { _ in 1015 }, at: at, cloudCover: 0.5)
        let falling = Terms.pressure(series { 1030 - $0 * 1.0 }, at: at, cloudCover: 0.8)
        let bluebird = Terms.pressure(series { 990 + $0 * 0.5 }, at: at, cloudCover: 0.0)
        XCTAssertEqual(stable, 0.075, accuracy: 1e-9)   // only the stability bonus
        XCTAssertGreaterThan(falling, 0.3)
        XCTAssertLessThan(bluebird, -0.5)
        // No history -> neutral.
        XCTAssertEqual(Terms.pressure(series { _ in 1015 }, at: t0, cloudCover: 0.5), 0)
    }

    func testSolunarPeaksAtMajor() {
        let major = utc(2026, 5, 1, 6)
        let peak = Terms.solunar(at: major, majors: [major], minors: [], phaseAngle: 0)
        let off = Terms.solunar(at: major.addingTimeInterval(4 * 3600), majors: [major], minors: [], phaseAngle: 0)
        XCTAssertEqual(peak, 1, accuracy: 1e-9)
        XCTAssertLessThan(off, -0.99)
        let minor = Terms.solunar(at: major, majors: [], minors: [major], phaseAngle: 90)
        XCTAssertEqual(minor, 2 * 0.6 * 0.75 - 1, accuracy: 1e-9)
    }

    func testLightTerm() {
        let sunrise = utc(2026, 5, 1, 5)
        let dawn = Terms.light(at: sunrise, sunrise: sunrise, sunset: nil, cloudCover: 1)
        let noonClear = Terms.light(at: sunrise.addingTimeInterval(6 * 3600), sunrise: sunrise, sunset: nil, cloudCover: 0)
        XCTAssertEqual(dawn, 1, accuracy: 1e-9)
        XCTAssertEqual(noonClear, -1, accuracy: 1e-6)
    }

    func testThermalCurve() {
        XCTAssertEqual(Terms.thermal(waterTempC: 22, species: .walleye), 1, accuracy: 1e-9)
        XCTAssertEqual(Terms.thermal(waterTempC: 31, species: .walleye), -1, accuracy: 1e-9)
        XCTAssertEqual(Terms.thermal(waterTempC: 40, species: .walleye), -1, accuracy: 1e-9)
        XCTAssertLessThan(Terms.thermal(waterTempC: 4, species: .walleye), -0.9)
        XCTAssertEqual(Terms.waterTempStep(previousC: 10, airMean7dC: 18, tauDays: 8), 11, accuracy: 1e-9)
    }

    func testWindTerm() {
        XCTAssertEqual(Terms.wind(speedKmh: 18, towardDeg: 90, bankBearingDeg: 90), 1, accuracy: 1e-9)
        XCTAssertEqual(Terms.wind(speedKmh: 18, towardDeg: nil, bankBearingDeg: nil), 0.6, accuracy: 1e-9)
        XCTAssertEqual(Terms.wind(speedKmh: 40, towardDeg: 90, bankBearingDeg: 90), -1)
        XCTAssertEqual(Terms.waveHeight(windMs: 10, fetchMeters: 9810), 1.6e-3 * 10 * 1000.0.squareRoot(), accuracy: 1e-9)
    }

    func testPriorWeightsStayBelowOne() {
        for water in WaterType.allCases {
            let w = Weights.prior(water: water)
            let sum = w.light + w.thermal + w.wind + w.pressure + w.solunar + w.tide
            XCTAssertLessThanOrEqual(sum, 1.0 + 1e-9)
            XCTAssertGreaterThan(sum, 0.7)
        }
        XCTAssertEqual(Weights.prior(water: .warmFreshwater, species: .largemouthBass).solunar, 0.05)
    }

    func testDefaultSpeciesByRegion() {
        XCTAssertEqual(Species.defaultSpecies(forRegion: "US"), .walleye)
        XCTAssertEqual(Species.defaultSpecies(forRegion: "ca"), .walleye)
        XCTAssertEqual(Species.defaultSpecies(forRegion: "MX"), .walleye)
        XCTAssertEqual(Species.defaultSpecies(forRegion: "DE"), .northernPike)
        XCTAssertEqual(Species.defaultSpecies(forRegion: "FI"), .northernPike)
        XCTAssertEqual(Species.defaultSpecies(forRegion: "JP"), .northernPike)
        XCTAssertEqual(Species.defaultSpecies(forRegion: nil), .northernPike)
        XCTAssertEqual(Species.defaultSpecies(forRegion: ""), .northernPike)
    }

    // MARK: Forecaster

    func makeHours(from start: Date, count: Int) -> [HourConditions] {
        (0..<count).map {
            HourConditions(time: start.addingTimeInterval(Double($0) * 3600), pressureHPa: 1015,
                           cloudCover: 0.5, windSpeedKmh: 15, windFromDeg: 270, airTempC: 18)
        }
    }

    func testCurveAndBestWindowFavourTwilight() {
        let dayStart = utc(2026, 6, 21), dayEnd = utc(2026, 6, 22)
        let hours = makeHours(from: dayStart.addingTimeInterval(-48 * 3600), count: 97)
        let ctx = SpotContext(latitude: 52.52, longitude: 13.405, water: .warmFreshwater,
                              species: .walleye, waterTempC: 21)
        let points = Forecaster.curve(context: ctx, hours: hours, from: dayStart, to: dayEnd)
        XCTAssertEqual(points.count, 97)
        XCTAssertTrue(points.allSatisfy { (0...100).contains($0.index) })

        let window = try! XCTUnwrap(Forecaster.bestWindow(in: points))
        XCTAssertEqual(window.end.timeIntervalSince(window.start), 7200, accuracy: 1)
        let sun = Astro.events(.sun, from: dayStart, to: dayEnd, latitude: 52.52, longitude: 13.405)
        let mid = window.start.addingTimeInterval(3600)
        let toTwilight = min(abs(mid.timeIntervalSince(sun.rises[0])), abs(mid.timeIntervalSince(sun.sets[0])))
        XCTAssertLessThan(toTwilight, 2.5 * 3600)

        // Midday must score below the best window.
        let noon = points.first { $0.time == utc(2026, 6, 21, 11) }!
        XCTAssertLessThan(noon.index, window.meanIndex)
    }

    func testCurveSkipsInstantsWithoutWeather() {
        let start = utc(2026, 6, 21)
        let hours = makeHours(from: start, count: 6)
        let ctx = SpotContext(latitude: 0, longitude: 0, water: .warmFreshwater, species: .walleye)
        let points = Forecaster.curve(context: ctx, hours: hours, from: start, to: start.addingTimeInterval(12 * 3600), step: 3600)
        XCTAssertEqual(points.count, 6)
        XCTAssertTrue(points.allSatisfy { $0.contributions.thermal == 0 })
    }

    func testIndexIsNeutralAtZero() {
        XCTAssertEqual(Forecaster.index(for: Contributions()), 50, accuracy: 1e-9)
    }

    func testDepthAdvice() {
        XCTAssertNotNil(Forecaster.depthAdvice(maxDepthMeters: 15, surfaceTempC: 26, species: .walleye))
        XCTAssertNil(Forecaster.depthAdvice(maxDepthMeters: 4, surfaceTempC: 26, species: .walleye))
        XCTAssertNil(Forecaster.depthAdvice(maxDepthMeters: 15, surfaceTempC: 15, species: .walleye))
    }

    // MARK: Tide

    func testS2OnlyTideHasHighWaterAtMidnightAndNoonUT() {
        let st = TideStation(id: "t", name: "t", meanLevel: 2,
                             constituents: [.init(name: "S2", amplitude: 1, phase: 0)])
        XCTAssertEqual(st.height(at: utc(2026, 4, 1, 0)), 3, accuracy: 1e-6)
        XCTAssertEqual(st.height(at: utc(2026, 4, 1, 12)), 3, accuracy: 1e-6)
        XCTAssertEqual(st.height(at: utc(2026, 4, 1, 6)), 1, accuracy: 1e-6)
        XCTAssertEqual(st.rate(at: utc(2026, 4, 1, 0)), 0, accuracy: 1e-3)
    }

    func testM2PeriodIsTwelvePointFourTwoHours() {
        let st = TideStation(id: "t", name: "t", meanLevel: 0,
                             constituents: [.init(name: "M2", amplitude: 1.3, phase: 110)])
        let t = utc(2026, 4, 1, 3, 17)
        let period = 12.4206012 * 3600
        XCTAssertEqual(st.height(at: t), st.height(at: t.addingTimeInterval(period)), accuracy: 2e-3)
        XCTAssertNotEqual(st.height(at: t), st.height(at: t.addingTimeInterval(period / 2)), accuracy: 0.05)
    }

    func testTideCurveCoversBothEndsAndMatchesHeight() {
        let st = TideStation(id: "t", name: "t", meanLevel: 1,
                             constituents: [.init(name: "S2", amplitude: 0.5, phase: 0)])
        let from = utc(2026, 5, 1), to = utc(2026, 5, 2)
        let c = st.curve(from: from, to: to, step: 900)
        XCTAssertEqual(c.count, 97)
        XCTAssertEqual(c.first?.time, from)
        XCTAssertEqual(c.last?.time, to)
        for s in c { XCTAssertEqual(s.height, st.height(at: s.time), accuracy: 1e-12) }
        XCTAssertEqual(c.map(\.height).max() ?? 0, 1.5, accuracy: 1e-6)
        XCTAssertTrue(st.curve(from: to, to: from).isEmpty)
        // A span that is not a multiple of the step still ends exactly at `to`.
        XCTAssertEqual(st.curve(from: from, to: from.addingTimeInterval(1000), step: 900).map { $0.time.timeIntervalSince(from) },
                       [0, 900, 1000])
    }

    func testS2ExtremesAtSixHourIntervals() {
        let st = TideStation(id: "t", name: "t", meanLevel: 2,
                             constituents: [.init(name: "S2", amplitude: 1, phase: 0)])
        let ex = st.extremes(from: utc(2026, 4, 1, 1), to: utc(2026, 4, 2, 1))
        XCTAssertEqual(ex.map(\.isHigh), [false, true, false, true])
        for (e, h) in zip(ex, [6, 12, 18, 24]) {
            XCTAssertEqual(e.time.timeIntervalSince(utc(2026, 4, 1, h)), 0, accuracy: 60)
            XCTAssertEqual(e.height, e.isHigh ? 3 : 1, accuracy: 1e-4)
        }
        XCTAssertTrue(st.extremes(from: utc(2026, 4, 1, 1), to: utc(2026, 4, 1, 1)).isEmpty)
    }

    func testTideTermRange() {
        XCTAssertEqual(Terms.tide(rate: 0, maxRateOfDay: 0.5), -1)
        XCTAssertEqual(Terms.tide(rate: -0.5, maxRateOfDay: 0.5), 1)
        XCTAssertEqual(Terms.tide(rate: 0.2, maxRateOfDay: 0), 0)
    }

    // MARK: Support

    func testGammaPoissonShrinkage() {
        var m = CatchRateMultiplier()
        XCTAssertEqual(m.mean, 1)
        m.update(catches: 0, expected: 2)       // blank trip pulls the rate down
        XCTAssertEqual(m.mean, 5.0 / 7.0, accuracy: 1e-9)
        m.update(catches: 9, expected: 2)
        XCTAssertEqual(m.mean, 14.0 / 9.0, accuracy: 1e-9)
        m.update(catches: 3, expected: 0)       // ignored: no exposure
        XCTAssertEqual(m.mean, 14.0 / 9.0, accuracy: 1e-9)
    }

    func testExpectedCatchIntegratesRelativeRate() {
        let t0 = utc(2026, 6, 21, 6)
        func flat(_ index: Double) -> [ScorePoint] {
            (0...8).map { ScorePoint(time: t0.addingTimeInterval(Double($0) * 900), index: index, contributions: Contributions()) }
        }
        let end = t0.addingTimeInterval(7200)
        XCTAssertEqual(CatchModel.expectedCatch(points: flat(50), from: t0, to: end), 1.0, accuracy: 1e-9)
        XCTAssertEqual(CatchModel.expectedCatch(points: flat(75), from: t0, to: end), 1.5, accuracy: 1e-9)
        XCTAssertEqual(CatchModel.expectedCatch(points: flat(75), from: t0, to: end, baseline: 2), 6.0, accuracy: 1e-9)
        // No weather -> neutral; half-covered trip -> half neutral.
        XCTAssertEqual(CatchModel.expectedCatch(points: [], from: t0, to: end), 1.0, accuracy: 1e-9)
        XCTAssertEqual(CatchModel.expectedCatch(points: flat(100), from: t0.addingTimeInterval(3600),
                                                to: end.addingTimeInterval(3600)), 0.5 * (2 + 1), accuracy: 1e-9)
        // Linear ramp 0 -> 100 over two hours averages to neutral.
        let ramp = [ScorePoint(time: t0, index: 0, contributions: Contributions()),
                    ScorePoint(time: end, index: 100, contributions: Contributions())]
        XCTAssertEqual(CatchModel.expectedCatch(points: ramp, from: t0, to: end), 1.0, accuracy: 1e-9)
        XCTAssertEqual(CatchModel.expectedCatch(points: flat(50), from: end, to: t0), 0)
    }

    func testFittedMultiplier() {
        let trips: [CatchRateMultiplier.Observation] = [
            .init(catches: 0, expected: 2), .init(catches: 9, expected: 2), .init(catches: 3, expected: 0),
        ]
        let m = CatchRateMultiplier.fitted(to: trips)
        XCTAssertEqual(m.mean, 14.0 / 9.0, accuracy: 1e-9)
        XCTAssertEqual(CatchRateMultiplier.fitted(to: trips.reversed()), m)
        XCTAssertEqual(CatchRateMultiplier.fitted(to: []).mean, 1)
    }

    func testBarometerFusionKeepsForecastLevelAndDeviceTrend() {
        let t0 = utc(2026, 5, 1)
        let forecast: [Barometry.Sample] = (0...24).map { (t0.addingTimeInterval(Double($0) * 3600), 1015) }
        // Phone ~200 m above sea level: station pressure ~990, falling 0.5 hPa/h from 10:00 to 12:00.
        let session = t0.addingTimeInterval(10 * 3600)
        let device: [Barometry.Sample] = (0...12).map {
            (session.addingTimeInterval(Double($0) * 600), 990.5 - 0.5 * Double($0) / 6)
        }
        let fused = Terms.PressureSeries(Barometry.fuse(forecast: forecast, device: device))
        XCTAssertEqual(fused.value(at: session)!, 1015.5, accuracy: 1e-9)
        XCTAssertEqual(fused.value(at: session.addingTimeInterval(3600))!, 1015, accuracy: 1e-9)
        XCTAssertEqual(fused.value(at: session.addingTimeInterval(7200))!, 1014.5, accuracy: 1e-9)
        XCTAssertEqual(fused.value(at: t0.addingTimeInterval(5 * 3600))!, 1015, accuracy: 1e-9)
        // Hourly forecast points inside the session are replaced: 10 + 13 + 12.
        XCTAssertEqual(fused.samples.count, 35)

        // A reading from another elevation is dropped.
        let outlier: [Barometry.Sample] = device + [(session.addingTimeInterval(3900), 970)]
        XCTAssertEqual(Barometry.fuse(forecast: forecast, device: outlier).count, 35)

        // Too few readings, too short a session, or readings outside the forecast: unchanged.
        XCTAssertEqual(Barometry.fuse(forecast: forecast, device: Array(device.prefix(2))).count, 25)
        XCTAssertEqual(Barometry.fuse(forecast: forecast, device: Array(device.prefix(3))).count, 25)
        XCTAssertEqual(Barometry.fuse(forecast: forecast, device: []).count, 25)
        let stale: [Barometry.Sample] = device.map { ($0.time.addingTimeInterval(-86400 * 3), $0.hPa) }
        XCTAssertEqual(Barometry.fuse(forecast: forecast, device: stale).count, 25)
    }

    func testCurveFillsMissingWeatherFromAstronomyAlone() {
        let ctx = SpotContext(latitude: 52.52, longitude: 13.405, water: .warmFreshwater, species: .walleye)
        let from = utc(2026, 6, 21), to = utc(2026, 6, 22)
        XCTAssertTrue(Forecaster.curve(context: ctx, hours: [], from: from, to: to).isEmpty)

        let pts = Forecaster.curve(context: ctx, hours: [], from: from, to: to, fillMissingWeather: true)
        XCTAssertEqual(pts.count, 97)
        XCTAssertTrue(pts.allSatisfy { !$0.hasWeather })
        XCTAssertTrue(pts.allSatisfy { $0.contributions.wind == 0 && $0.contributions.pressure == 0 })
        // Twilight still drives the best window: sunrise is 02:43 UT, sunset 19:33 UT.
        let best = Forecaster.bestWindow(in: pts)!
        let mid = best.start.addingTimeInterval(best.end.timeIntervalSince(best.start) / 2)
        let nearDawn = abs(mid.timeIntervalSince(utc(2026, 6, 21, 2, 43))) < 5400
        let nearDusk = abs(mid.timeIntervalSince(utc(2026, 6, 21, 19, 33))) < 5400
        XCTAssertTrue(nearDawn || nearDusk, "window centred at \(mid)")

        // Later in the day, the window never starts before the cutoff.
        let noon = utc(2026, 6, 21, 12)
        let later = Forecaster.bestWindow(in: pts, notBefore: noon)!
        XCTAssertGreaterThanOrEqual(later.start, noon)
        // Too little day left: no window.
        XCTAssertNil(Forecaster.bestWindow(in: pts, notBefore: utc(2026, 6, 21, 23, 30)))

        // Weather that covers part of the range is used where it exists.
        let hours = (0...6).map { HourConditions(time: from.addingTimeInterval(Double($0) * 3600), pressureHPa: 1015,
                                                 cloudCover: 0.5, windSpeedKmh: 18, windFromDeg: nil, airTempC: 15) }
        let mixed = Forecaster.curve(context: ctx, hours: hours, from: from, to: to, fillMissingWeather: true)
        XCTAssertEqual(mixed.count, 97)
        XCTAssertEqual(mixed.filter(\.hasWeather).count, 25)
        XCTAssertGreaterThan(mixed[0].contributions.wind, 0)
        // Unknown cloud is neutral, known cloud is not.
        let dawn = utc(2026, 6, 21, 2, 43)
        XCTAssertEqual(Terms.light(at: dawn, sunrise: dawn, sunset: nil, cloudCover: nil), 0.7, accuracy: 1e-9)
        XCTAssertEqual(Terms.light(at: dawn, sunrise: dawn, sunset: nil, cloudCover: 1), 1.0, accuracy: 1e-9)
    }

    func testCurveUsesOverridePressure() {
        let start = utc(2026, 6, 21)
        let hours = makeHours(from: start.addingTimeInterval(-48 * 3600), count: 60)
        let ctx = SpotContext(latitude: 52.52, longitude: 13.405, water: .warmFreshwater, species: .walleye)
        let at = start.addingTimeInterval(6 * 3600)
        let falling = Terms.PressureSeries(hours.map { ($0.time, 1030 - $0.time.timeIntervalSince(start) / 3600) })
        let base = Forecaster.curve(context: ctx, hours: hours, from: at, to: at)
        let fused = Forecaster.curve(context: ctx, hours: hours, from: at, to: at, pressure: falling)
        XCTAssertEqual(base.count, 1)
        XCTAssertGreaterThan(fused[0].contributions.pressure, base[0].contributions.pressure)
        XCTAssertEqual(fused[0].contributions.light, base[0].contributions.light)
    }

    func testBarometry() {
        XCTAssertEqual(Barometry.hPa(fromKPa: 101.325), 1013.25, accuracy: 1e-9)
        XCTAssertEqual(Barometry.seaLevel(stationHPa: 1000, altitudeMeters: 0, tempC: 15), 1000, accuracy: 1e-9)
        // ~12 hPa per 100 m near sea level.
        XCTAssertEqual(Barometry.seaLevel(stationHPa: 1000, altitudeMeters: 100, tempC: 15), 1012, accuracy: 0.5)
        XCTAssertEqual(Barometry.bias(device: [1001, 1003, 1010], forecast: [1000, 1000, 1000]), 3)
        XCTAssertNil(Barometry.bias(device: [], forecast: []))
    }

    func testGeohash() {
        // Reference vector from the geohash specification.
        XCTAssertEqual(Geohash.encode(latitude: 57.64911, longitude: 10.40744, precision: 11), "u4pruydqqvj")
        XCTAssertEqual(Geohash.encode(latitude: 52.52, longitude: 13.405, precision: 5), "u33dc")
        let c = try! XCTUnwrap(Geohash.decode("u33dc"))
        XCTAssertEqual(c.latitude, 52.52, accuracy: 0.03)
        XCTAssertEqual(c.longitude, 13.405, accuracy: 0.03)
        XCTAssertNil(Geohash.decode("a!"))
        XCTAssertNil(Geohash.decode(""))
    }
}
