// Generated from NOAA CO-OPS on 2026-11-14: harmonic constants (as the backend converts them) and NOAA's own
// hourly predictions (MLLW, metres, GMT) for 2026-11-20 and 21. Used to check the tide engine.
@testable import BiteCore

struct TideFixture {
    let station: TideStation
    /// Hourly predicted heights from 2026-11-20 00:00 GMT.
    let noaa: [Double]
}

let tideFixtures: [TideFixture] = [
    TideFixture(station: TideStation(id: "8443970", name: "Boston", meanLevel: 1.586, constituents: [
        .init(name: "M2", amplitude: 1.371, phase: 109.2),
        .init(name: "S2", amplitude: 0.208, phase: 146.2),
        .init(name: "N2", amplitude: 0.305, phase: 76.7),
        .init(name: "K1", amplitude: 0.143, phase: 205.6),
        .init(name: "O1", amplitude: 0.116, phase: 187.1),
        .init(name: "SSA", amplitude: 0.022, phase: 97.5),
        .init(name: "SA", amplitude: 0.049, phase: 136.3),
        .init(name: "Q1", amplitude: 0.019, phase: 172.1),
        .init(name: "P1", amplitude: 0.047, phase: 204.8),
        .init(name: "K2", amplitude: 0.059, phase: 146.1),
    ]), noaa: [2.686, 2.422, 1.965, 1.419, 0.879, 0.467, 0.361, 0.615, 1.083, 1.628, 2.199, 2.661, 2.847, 2.711, 2.32, 1.775, 1.183, 0.653, 0.356, 0.431, 0.81, 1.325, 1.894, 2.424, 2.734, 2.72, 2.41, 1.901, 1.308, 0.744, 0.354, 0.316, 0.656, 1.207, 1.833, 2.449, 2.897, 3.02, 2.797, 2.305, 1.664, 0.996, 0.43, 0.151, 0.287, 0.74, 1.335, 1.975]),
    TideFixture(station: TideStation(id: "9414290", name: "San Francisco", meanLevel: 0.9510000000000001, constituents: [
        .init(name: "M2", amplitude: 0.576, phase: 208.2),
        .init(name: "S2", amplitude: 0.137, phase: 216.2),
        .init(name: "N2", amplitude: 0.122, phase: 183.2),
        .init(name: "K1", amplitude: 0.37, phase: 225.4),
        .init(name: "O1", amplitude: 0.23, phase: 208.4),
        .init(name: "SSA", amplitude: 0.03, phase: 272.3),
        .init(name: "SA", amplitude: 0.044, phase: 200.2),
        .init(name: "Q1", amplitude: 0.041, phase: 202.4),
        .init(name: "P1", amplitude: 0.114, phase: 222.1),
        .init(name: "K2", amplitude: 0.04, phase: 206),
    ]), noaa: [0.807, 1, 1.16, 1.247, 1.227, 1.092, 0.877, 0.645, 0.471, 0.411, 0.483, 0.676, 0.951, 1.248, 1.505, 1.676, 1.714, 1.59, 1.324, 0.976, 0.637, 0.39, 0.283, 0.322, 0.482, 0.713, 0.953, 1.156, 1.278, 1.278, 1.152, 0.939, 0.713, 0.559, 0.534, 0.649, 0.882, 1.182, 1.479, 1.712, 1.831, 1.786, 1.559, 1.185, 0.751, 0.365, 0.119, 0.049]),
    TideFixture(station: TideStation(id: "8724580", name: "Key West", meanLevel: 0.272, constituents: [
        .init(name: "M2", amplitude: 0.179, phase: 66.9),
        .init(name: "S2", amplitude: 0.051, phase: 89.4),
        .init(name: "N2", amplitude: 0.036, phase: 48.9),
        .init(name: "K1", amplitude: 0.086, phase: 354.8),
        .init(name: "O1", amplitude: 0.089, phase: 351.9),
        .init(name: "SSA", amplitude: 0.051, phase: 57.6),
        .init(name: "SA", amplitude: 0.095, phase: 183.1),
        .init(name: "Q1", amplitude: 0.021, phase: 342),
        .init(name: "P1", amplitude: 0.028, phase: 357.8),
        .init(name: "K2", amplitude: 0.015, phase: 92),
    ]), noaa: [0.489, 0.421, 0.337, 0.26, 0.209, 0.198, 0.226, 0.282, 0.347, 0.412, 0.465, 0.493, 0.484, 0.438, 0.367, 0.296, 0.248, 0.238, 0.271, 0.335, 0.411, 0.484, 0.542, 0.572, 0.56, 0.499, 0.4, 0.286, 0.186, 0.126, 0.118, 0.158, 0.227, 0.307, 0.384, 0.448, 0.482, 0.474, 0.424, 0.35, 0.28, 0.24, 0.247, 0.301, 0.383, 0.472, 0.549, 0.604]),
]
