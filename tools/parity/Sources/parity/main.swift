import BiteCore
import Foundation

// Inputs and the Swift engine's outputs, side by side, so the Kotlin test reads the same
// numbers the Swift engine was given. Times are seconds since 1970.

func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

func s(_ d: Date) -> Double { d.timeIntervalSince1970 }
func opt(_ x: Double?) -> Any { x.map { $0 as Any } ?? NSNull() }

let boston = TideStation(id: "8443970", name: "Boston", meanLevel: 1.586, constituents: [
    .init(name: "M2", amplitude: 1.371, phase: 109.2), .init(name: "S2", amplitude: 0.208, phase: 146.2),
    .init(name: "N2", amplitude: 0.305, phase: 76.7), .init(name: "K1", amplitude: 0.143, phase: 205.6),
    .init(name: "O1", amplitude: 0.116, phase: 187.1), .init(name: "SSA", amplitude: 0.022, phase: 97.5),
    .init(name: "SA", amplitude: 0.049, phase: 136.3), .init(name: "Q1", amplitude: 0.019, phase: 172.1),
    .init(name: "P1", amplitude: 0.047, phase: 204.8), .init(name: "K2", amplitude: 0.059, phase: 146.1),
])
let sanFrancisco = TideStation(id: "9414290", name: "San Francisco", meanLevel: 0.951, constituents: [
    .init(name: "M2", amplitude: 0.576, phase: 208.2), .init(name: "S2", amplitude: 0.137, phase: 216.2),
    .init(name: "N2", amplitude: 0.122, phase: 183.2), .init(name: "K1", amplitude: 0.37, phase: 225.4),
    .init(name: "O1", amplitude: 0.23, phase: 208.4), .init(name: "SSA", amplitude: 0.03, phase: 272.3),
    .init(name: "SA", amplitude: 0.044, phase: 200.2), .init(name: "Q1", amplitude: 0.041, phase: 202.4),
    .init(name: "P1", amplitude: 0.114, phase: 222.1), .init(name: "K2", amplitude: 0.04, phase: 206),
    .init(name: "M4", amplitude: 0.02, phase: 10),   // not supported: must be ignored
])

func stationJSON(_ st: TideStation) -> [String: Any] {
    ["id": st.id, "name": st.name, "meanLevel": st.meanLevel,
     "constituents": st.constituents.map { ["name": $0.name, "amplitude": $0.amplitude, "phase": $0.phase] }]
}

// MARK: Astro

var astro: [[String: Any]] = []
let places: [(Double, Double)] = [(52.52, 13.405), (38.72, -9.14), (-33.87, 151.21), (69.65, 18.96), (0, 0), (44.933, -93.563)]
let instants = [utc(2000, 1, 1, 12), utc(2000, 1, 6, 18, 14), utc(2026, 3, 20, 12, 7), utc(2026, 6, 21, 2, 43),
                utc(2026, 11, 15, 17, 30), utc(2027, 2, 28, 23, 59), utc(2031, 8, 9, 4, 5)]
for t in instants {
    for (lat, lon) in places {
        let jd = Astro.julianDay(t)
        let sun = Astro.sun(jd: jd), moon = Astro.moon(jd: jd)
        astro.append([
            "t": s(t), "lat": lat, "lon": lon, "jd": jd,
            "sun": [sun.ra, sun.dec, sun.lon, sun.parallax], "moon": [moon.ra, moon.dec, moon.lon, moon.parallax],
            "phase": Astro.moonPhaseAngle(t), "illum": Astro.moonIllumination(t),
            "haSun": Astro.hourAngle(.sun, date: t, longitude: lon), "haMoon": Astro.hourAngle(.moon, date: t, longitude: lon),
            "altSun": Astro.altitude(.sun, date: t, latitude: lat, longitude: lon),
            "altMoon": Astro.altitude(.moon, date: t, latitude: lat, longitude: lon),
        ])
    }
}

var events: [[String: Any]] = []
for (from, to) in [(utc(2026, 6, 20), utc(2026, 6, 24)), (utc(2026, 11, 14), utc(2026, 11, 18)), (utc(2000, 1, 20, 12), utc(2000, 1, 22))] {
    for (lat, lon) in places {
        for (name, body) in [("sun", Astro.Body.sun), ("moon", Astro.Body.moon)] {
            let e = Astro.events(body, from: from, to: to, latitude: lat, longitude: lon)
            events.append(["body": name, "from": s(from), "to": s(to), "lat": lat, "lon": lon,
                           "rises": e.rises.map(s), "sets": e.sets.map(s),
                           "upper": e.upperTransits.map(s), "lower": e.lowerTransits.map(s)])
        }
    }
}

// MARK: Tide

var tides: [[String: Any]] = []
for st in [boston, sanFrancisco] {
    let from = utc(2026, 11, 20)
    let times = (0..<72).map { from.addingTimeInterval(Double($0) * 3600 + 417) }
    let to = from.addingTimeInterval(72 * 3600)
    tides.append(["station": stationJSON(st), "from": s(from), "to": s(to), "times": times.map(s),
                  "heights": times.map { st.height(at: $0) }, "rates": times.map { st.rate(at: $0) },
                  "extremes": st.extremes(from: from, to: to).map { [s($0.time), $0.height, $0.isHigh ? 1.0 : 0.0] },
                  "curve": st.curve(from: from, to: from.addingTimeInterval(86_400)).map { [s($0.time), $0.height] }])
}

// MARK: Curves

/// Deterministic weather with fronts, calm and gales in it. Emitted with the case, so the
/// Kotlin side reads these numbers rather than recomputing them.
func weather(from start: Date, count: Int, seed: Double, windNilEvery: Int = 0) -> [HourConditions] {
    (0..<count).map { i in
        let x = Double(i) + seed
        return HourConditions(time: start.addingTimeInterval(Double(i) * 3600),
                              pressureHPa: 1013 + 9 * sin(x / 19) - 4 * cos(x / 7),
                              cloudCover: max(0, min(1, 0.5 + 0.6 * sin(x / 13))),
                              windSpeedKmh: max(0, 16 + 14 * sin(x / 9) + 10 * sin(x / 31)),
                              windFromDeg: windNilEvery > 0 && i % windNilEvery == 0 ? nil : (x * 23).truncatingRemainder(dividingBy: 360),
                              airTempC: 12 + 9 * sin((x - 9) * .pi / 12) + 3 * sin(x / 50))
    }
}

struct Case {
    var name: String
    var context: SpotContext
    var hours: [HourConditions]
    var from: Date
    var to: Date
    var fill: Bool
    var speciesTemp: Double?
}

let cases: [Case] = [
    Case(name: "berlin-warm-walleye-bank",
         context: SpotContext(latitude: 52.52, longitude: 13.405, water: .warmFreshwater, species: .walleye, bankBearingDeg: 90, waterTempC: 21),
         hours: weather(from: utc(2026, 6, 19), count: 48 + 96, seed: 3), from: utc(2026, 6, 21), to: utc(2026, 6, 24), fill: true, speciesTemp: 21),
    Case(name: "taneycomo-cold-trout",
         context: SpotContext(latitude: 36.66, longitude: -93.23, water: .coldFreshwater, species: .rainbowTrout, waterTempC: 9.5),
         hours: weather(from: utc(2026, 11, 13, 6), count: 48 + 60, seed: 40, windNilEvery: 5), from: utc(2026, 11, 15, 6), to: utc(2026, 11, 17, 6), fill: false, speciesTemp: 9.5),
    Case(name: "boston-inshore-station-partial-weather",
         context: SpotContext(latitude: 42.355, longitude: -71.05, water: .inshoreSalt, species: .stripedBass, bankBearingDeg: 225, waterTempC: 11, tide: boston),
         hours: weather(from: utc(2026, 11, 18), count: 48 + 30, seed: 77), from: utc(2026, 11, 20), to: utc(2026, 11, 22), fill: true, speciesTemp: 11),
    Case(name: "keywest-offshore-no-station-no-weather",
         context: SpotContext(latitude: 24.55, longitude: -81.8, water: .offshore, species: .general),
         hours: [], from: utc(2026, 11, 20, 5), to: utc(2026, 11, 22, 5), fill: true, speciesTemp: 26),
    Case(name: "sanfrancisco-inshore-station-carp-weights",
         context: SpotContext(latitude: 37.8, longitude: -122.46, water: .inshoreSalt, species: .general, tide: sanFrancisco),
         hours: weather(from: utc(2026, 4, 1), count: 48 + 80, seed: 11), from: utc(2026, 4, 3, 7), to: utc(2026, 4, 5, 7), fill: false, speciesTemp: 13),
    Case(name: "tromso-polar-day-pike",
         context: SpotContext(latitude: 69.65, longitude: 18.96, water: .warmFreshwater, species: .northernPike, waterTempC: 12),
         hours: weather(from: utc(2026, 6, 18, 22), count: 48 + 50, seed: 5), from: utc(2026, 6, 20, 22), to: utc(2026, 6, 22, 22), fill: true, speciesTemp: 12),
    Case(name: "sydney-offshore-reddrum",
         context: SpotContext(latitude: -33.87, longitude: 151.21, water: .offshore, species: .redDrum, waterTempC: 22),
         hours: weather(from: utc(2026, 12, 29, 13), count: 48 + 240, seed: 123), from: utc(2026, 12, 31, 13), to: utc(2027, 1, 10, 13), fill: true, speciesTemp: 22),
    Case(name: "fork-warm-bass-no-watertemp",
         context: SpotContext(latitude: 32.84, longitude: -95.58, water: .warmFreshwater, species: .largemouthBass),
         hours: weather(from: utc(2026, 8, 1, 5), count: 48 + 48, seed: 64), from: utc(2026, 8, 3, 5), to: utc(2026, 8, 5, 5), fill: true, speciesTemp: nil),
]

func window(_ w: BiteWindow?) -> Any {
    w.map { [s($0.start), s($0.end), $0.meanIndex] as Any } ?? NSNull()
}

var curves: [[String: Any]] = []
for c in cases {
    let points = Forecaster.curve(context: c.context, hours: c.hours, from: c.from, to: c.to, fillMissingWeather: c.fill)
    let notBefore = c.from.addingTimeInterval(13.3 * 3600)
    let firstDay = points.filter { $0.time < c.from.addingTimeInterval(86_400) }
    let now = c.from.addingTimeInterval(12 * 3600 + 1234)
    let ranked = Forecaster.speciesNow(context: c.context, hours: c.hours, now: now, waterTempC: c.speciesTemp)

    // A trip of nine and a half hours with fish at uneven times, one right at the end.
    let tripFrom = c.from.addingTimeInterval(6 * 3600 + 420), tripTo = tripFrom.addingTimeInterval(9.5 * 3600)
    let catchTimes = [300.0, 2000, 2100, 9000, 20000, 34200].map { tripFrom.addingTimeInterval($0) }
    let tripPoints = Forecaster.curve(context: c.context, hours: c.hours, from: tripFrom, to: tripTo.addingTimeInterval(900), fillMissingWeather: c.fill)
    let weights = Weights.prior(water: c.context.water, species: c.context.species)
    let record = Scorecard.record(points: tripPoints, from: tripFrom, to: tripTo, catchTimes: catchTimes)
    let slices = Scorecard.slices(points: tripPoints, weights: weights, from: tripFrom, to: tripTo, catchTimes: catchTimes)

    var ctx: [String: Any] = ["lat": c.context.latitude, "lon": c.context.longitude, "water": c.context.water.rawValue,
                              "species": c.context.species.rawValue, "bank": opt(c.context.bankBearingDeg),
                              "waterTemp": opt(c.context.waterTempC)]
    if let tide = c.context.tide { ctx["station"] = stationJSON(tide) }
    curves.append([
        "name": c.name, "ctx": ctx,
        "hours": c.hours.map { [s($0.time), $0.pressureHPa, $0.cloudCover, $0.windSpeedKmh, opt($0.windFromDeg), $0.airTempC] },
        "from": s(c.from), "to": s(c.to), "fill": c.fill,
        "points": points.map { p in
            [s(p.time), p.index, p.contributions.light, p.contributions.thermal, p.contributions.wind,
             p.contributions.pressure, p.contributions.solunar, p.contributions.tide, p.hasWeather ? 1.0 : 0.0]
        },
        "best": window(Forecaster.bestWindow(in: points)),
        "bestFirstDay": window(Forecaster.bestWindow(in: firstDay)),
        "notBefore": s(notBefore),
        "bestAfter": window(Forecaster.bestWindow(in: firstDay, notBefore: notBefore)),
        "best3h": window(Forecaster.bestWindow(in: points, length: 3 * 3600)),
        "speciesNow": ["now": s(now), "waterTemp": opt(c.speciesTemp), "ranked": ranked.map { [$0.species.rawValue, $0.index] as [Any] }],
        "trip": [
            "from": s(tripFrom), "to": s(tripTo), "catchTimes": catchTimes.map(s),
            "expected": CatchModel.expectedCatch(points: tripPoints, from: tripFrom, to: tripTo),
            "record": record.map { ["hours": $0.hours, "catches": $0.catches, "mean": $0.meanIndex] as Any } ?? NSNull(),
            "slices": slices.map { $0.map { [$0.hours, Double($0.catches)] + $0.z } as Any } ?? NSNull(),
        ] as [String: Any],
    ])
}

// MARK: Barometer fusion and geohash

let fuseStart = utc(2026, 5, 1)
var forecastTrace: [Barometry.Sample] = []
for k in 0...24 {
    let x = Double(k)
    forecastTrace.append((fuseStart.addingTimeInterval(x * 3600), 1015 + 3 * sin(x / 5)))
}
var deviceTrace: [Barometry.Sample] = []
for k in 0...14 {
    let x = Double(k)
    let time = fuseStart.addingTimeInterval(36_000 + x * 611)
    let outlier: Double = k == 7 ? -20 : 0
    let hPa: Double = 990.5 - 0.5 * x / 6 + outlier
    deviceTrace.append((time, hPa))
}
let fused = Barometry.fuse(forecast: forecastTrace, device: deviceTrace)
let fuse: [String: Any] = ["forecast": forecastTrace.map { [s($0.time), $0.hPa] }, "device": deviceTrace.map { [s($0.time), $0.hPa] },
                           "fused": fused.map { [s($0.time), $0.hPa] }]

let geohash: [[Any]] = [(57.64911, 10.40744, 11), (52.52, 13.405, 5), (-33.87, 151.21, 5), (24.55, -81.8, 5), (0, 0, 7), (89.9, -179.9, 6)]
    .map { [$0.0, $0.1, $0.2, Geohash.encode(latitude: $0.0, longitude: $0.1, precision: $0.2)] }

let root: [String: Any] = ["astro": astro, "events": events, "tides": tides, "curves": curves, "fuse": fuse, "geohash": geohash]
let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "golden.json"
try data.write(to: URL(fileURLWithPath: path))
print("wrote \(path): \(data.count) bytes, \(curves.count) curves, \(events.count) event sets, \(astro.count) astro rows")
