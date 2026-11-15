package com.dautovri.bitecurve.core

// Tests/BiteCoreTests/TideFixtures.swift: NOAA CO-OPS harmonic constants and NOAA's own hourly
// predictions (MLLW, metres, GMT) for 2026-11-20 and 21, generated on 2026-11-14.
object TideFixtures {
    class Fixture(val station: TideStation, val noaa: List<Double>)

    val all: List<Fixture> = listOf(
        Fixture(TideStation("8443970", "Boston", 1.586, listOf(
            TideStation.Constituent("M2", 1.371, 109.2),
            TideStation.Constituent("S2", 0.208, 146.2),
            TideStation.Constituent("N2", 0.305, 76.7),
            TideStation.Constituent("K1", 0.143, 205.6),
            TideStation.Constituent("O1", 0.116, 187.1),
            TideStation.Constituent("SSA", 0.022, 97.5),
            TideStation.Constituent("SA", 0.049, 136.3),
            TideStation.Constituent("Q1", 0.019, 172.1),
            TideStation.Constituent("P1", 0.047, 204.8),
            TideStation.Constituent("K2", 0.059, 146.1),
        )), listOf(2.686, 2.422, 1.965, 1.419, 0.879, 0.467, 0.361, 0.615, 1.083, 1.628, 2.199, 2.661, 2.847, 2.711, 2.32, 1.775, 1.183, 0.653, 0.356, 0.431, 0.81, 1.325, 1.894, 2.424, 2.734, 2.72, 2.41, 1.901, 1.308, 0.744, 0.354, 0.316, 0.656, 1.207, 1.833, 2.449, 2.897, 3.02, 2.797, 2.305, 1.664, 0.996, 0.43, 0.151, 0.287, 0.74, 1.335, 1.975)),
        Fixture(TideStation("9414290", "San Francisco", 0.9510000000000001, listOf(
            TideStation.Constituent("M2", 0.576, 208.2),
            TideStation.Constituent("S2", 0.137, 216.2),
            TideStation.Constituent("N2", 0.122, 183.2),
            TideStation.Constituent("K1", 0.37, 225.4),
            TideStation.Constituent("O1", 0.23, 208.4),
            TideStation.Constituent("SSA", 0.03, 272.3),
            TideStation.Constituent("SA", 0.044, 200.2),
            TideStation.Constituent("Q1", 0.041, 202.4),
            TideStation.Constituent("P1", 0.114, 222.1),
            TideStation.Constituent("K2", 0.04, 206.0),
        )), listOf(0.807, 1.0, 1.16, 1.247, 1.227, 1.092, 0.877, 0.645, 0.471, 0.411, 0.483, 0.676, 0.951, 1.248, 1.505, 1.676, 1.714, 1.59, 1.324, 0.976, 0.637, 0.39, 0.283, 0.322, 0.482, 0.713, 0.953, 1.156, 1.278, 1.278, 1.152, 0.939, 0.713, 0.559, 0.534, 0.649, 0.882, 1.182, 1.479, 1.712, 1.831, 1.786, 1.559, 1.185, 0.751, 0.365, 0.119, 0.049)),
        Fixture(TideStation("8724580", "Key West", 0.272, listOf(
            TideStation.Constituent("M2", 0.179, 66.9),
            TideStation.Constituent("S2", 0.051, 89.4),
            TideStation.Constituent("N2", 0.036, 48.9),
            TideStation.Constituent("K1", 0.086, 354.8),
            TideStation.Constituent("O1", 0.089, 351.9),
            TideStation.Constituent("SSA", 0.051, 57.6),
            TideStation.Constituent("SA", 0.095, 183.1),
            TideStation.Constituent("Q1", 0.021, 342.0),
            TideStation.Constituent("P1", 0.028, 357.8),
            TideStation.Constituent("K2", 0.015, 92.0),
        )), listOf(0.489, 0.421, 0.337, 0.26, 0.209, 0.198, 0.226, 0.282, 0.347, 0.412, 0.465, 0.493, 0.484, 0.438, 0.367, 0.296, 0.248, 0.238, 0.271, 0.335, 0.411, 0.484, 0.542, 0.572, 0.56, 0.499, 0.4, 0.286, 0.186, 0.126, 0.118, 0.158, 0.227, 0.307, 0.384, 0.448, 0.482, 0.474, 0.424, 0.35, 0.28, 0.24, 0.247, 0.301, 0.383, 0.472, 0.549, 0.604)),
    )
}
