package com.dautovri.bitecurve.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneOffset
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.sqrt

/** Tests/BiteCoreTests/BiteCoreTests.swift, test for test, with the same names and numbers. */
class BiteCoreTest {
    private fun utc(y: Int, mo: Int, d: Int, h: Int = 0, mi: Int = 0): Double =
        LocalDateTime.of(y, mo, d, h, mi).toEpochSecond(ZoneOffset.UTC).toDouble()

    private val sun = Astro.Body.SUN
    private val moon = Astro.Body.MOON

    // Astro

    @Test fun testJulianDayAtJ2000() {
        assertEquals(2451545.0, Astro.julianDay(utc(2000, 1, 1, 12)), 1e-6)
    }

    @Test fun testBerlinSolsticeSunriseSunset() {
        // Berlin, 21 June 2026: sunrise 04:43 CEST, sunset 21:33 CEST.
        val e = Astro.events(sun, utc(2026, 6, 21), utc(2026, 6, 22), 52.52, 13.405)
        assertEquals(1, e.rises.size)
        assertEquals(1, e.sets.size)
        assertEquals(0.0, e.rises[0] - utc(2026, 6, 21, 2, 43), 240.0)
        assertEquals(0.0, e.sets[0] - utc(2026, 6, 21, 19, 33), 240.0)
    }

    @Test fun testSolarNoonAtGreenwichNearTwelve() {
        val e = Astro.events(sun, utc(2026, 3, 20), utc(2026, 3, 21), 51.48, 0.0)
        assertEquals(1, e.upperTransits.size)
        // Equation of time on 20 March is about -7.5 min, so transit is ~12:07 UT.
        assertEquals(0.0, e.upperTransits[0] - utc(2026, 3, 20, 12, 7), 180.0)
    }

    @Test fun testMoonPhaseAtKnownNewAndFullMoon() {
        // New moon 2000-01-06 18:14 UT; full moon 2000-01-21 04:40 UT.
        val new = Astro.moonPhaseAngle(utc(2000, 1, 6, 18, 14))
        assertTrue(min(new, 360 - new) < 1.5)
        assertEquals(180.0, Astro.moonPhaseAngle(utc(2000, 1, 21, 4, 40)), 1.5)
        assertTrue(Astro.moonIllumination(utc(2000, 1, 21, 4, 40)) > 0.99)
    }

    @Test fun testMoonEventsAreConsistent() {
        val from = utc(2026, 11, 10)
        val to = utc(2026, 11, 13)
        val e = Astro.events(moon, from, to, 38.72, -9.14)
        // Lunar day is ~24h50m: expect 2–3 of each event in 72 h.
        for (list in listOf(e.rises, e.sets, e.upperTransits, e.lowerTransits)) {
            assertTrue("got ${list.size}", list.size in 2..4)
        }
        // Hour angle is ~0 at upper transit and altitude peaks there.
        for (t in e.upperTransits) {
            assertEquals(0.0, Astro.hourAngle(moon, t, -9.14), 0.05)
            val a = Astro.altitude(moon, t, 38.72, -9.14)
            assertTrue(a > Astro.altitude(moon, t + 3600, 38.72, -9.14))
            assertTrue(a > Astro.altitude(moon, t - 3600, 38.72, -9.14))
        }
        // Successive upper transits are a lunar day apart.
        if (e.upperTransits.size >= 2) {
            val gap = (e.upperTransits[1] - e.upperTransits[0]) / 3600
            assertEquals(24.84, gap, 0.5)
        }
    }

    @Test fun testFullMoonRisesNearSunset() {
        // Full moon 2000-01-21: moonrise within ~75 min of sunset at mid latitudes.
        val day = utc(2000, 1, 20, 12)
        val end = utc(2000, 1, 21, 12)
        val s = Astro.events(sun, day, end, 40.0, 0.0)
        val m = Astro.events(moon, day, end, 40.0, 0.0)
        assertEquals(1, m.rises.size)
        assertEquals(0.0, m.rises[0] - s.sets[0], 75.0 * 60)
    }

    // Terms

    @Test fun testPressureTermSigns() {
        val t0 = utc(2026, 5, 1)
        fun series(f: (Double) -> Double) =
            Terms.PressureSeries((0..72).map { PressureSample(t0 + it * 3600.0, f(it.toDouble())) })
        val at = t0 + 60 * 3600
        val stable = Terms.pressure(series { 1015.0 }, at, 0.5)
        val falling = Terms.pressure(series { 1030 - it * 1.0 }, at, 0.8)
        val bluebird = Terms.pressure(series { 990 + it * 0.5 }, at, 0.0)
        assertEquals(0.075, stable, 1e-9)   // only the stability bonus
        assertTrue(falling > 0.3)
        assertTrue(bluebird < -0.5)
        // No history -> neutral.
        assertEquals(0.0, Terms.pressure(series { 1015.0 }, t0, 0.5), 0.0)
    }

    @Test fun testSolunarPeaksAtMajor() {
        val major = utc(2026, 5, 1, 6)
        val peak = Terms.solunar(major, listOf(major), emptyList(), 0.0)
        val off = Terms.solunar(major + 4 * 3600, listOf(major), emptyList(), 0.0)
        assertEquals(1.0, peak, 1e-9)
        assertTrue(off < -0.99)
        val minor = Terms.solunar(major, emptyList(), listOf(major), 90.0)
        assertEquals(2 * 0.6 * 0.75 - 1, minor, 1e-9)
    }

    @Test fun testLightTerm() {
        val sunrise = utc(2026, 5, 1, 5)
        val dawn = Terms.light(sunrise, sunrise, null, 1.0)
        val noonClear = Terms.light(sunrise + 6 * 3600, sunrise, null, 0.0)
        assertEquals(1.0, dawn, 1e-9)
        assertEquals(-1.0, noonClear, 1e-6)
    }

    @Test fun testThermalCurve() {
        assertEquals(1.0, Terms.thermal(22.0, Species.WALLEYE), 1e-9)
        assertEquals(-1.0, Terms.thermal(31.0, Species.WALLEYE), 1e-9)
        assertEquals(-1.0, Terms.thermal(40.0, Species.WALLEYE), 1e-9)
        assertTrue(Terms.thermal(4.0, Species.WALLEYE) < -0.9)
        assertEquals(11.0, Terms.waterTempStep(10.0, 18.0, 8.0), 1e-9)
    }

    @Test fun testWindTerm() {
        assertEquals(1.0, Terms.wind(18.0, 90.0, 90.0), 1e-9)
        assertEquals(0.6, Terms.wind(18.0, null, null), 1e-9)
        assertEquals(-1.0, Terms.wind(40.0, 90.0, 90.0), 0.0)
        assertEquals(1.6e-3 * 10 * sqrt(1000.0), Terms.waveHeight(10.0, 9810.0), 1e-9)
    }

    @Test fun testPriorWeightsStayBelowOne() {
        for (water in WaterType.entries) {
            val w = Weights.prior(water)
            val sum = w.light + w.thermal + w.wind + w.pressure + w.solunar + w.tide
            assertTrue(sum <= 1.0 + 1e-9)
            assertTrue(sum > 0.7)
        }
        assertEquals(0.05, Weights.prior(WaterType.WARM_FRESHWATER, Species.LARGEMOUTH_BASS).solunar, 0.0)
    }

    @Test fun testDefaultSpeciesByRegion() {
        assertEquals(Species.WALLEYE, Species.defaultSpecies("US"))
        assertEquals(Species.WALLEYE, Species.defaultSpecies("ca"))
        assertEquals(Species.WALLEYE, Species.defaultSpecies("MX"))
        assertEquals(Species.NORTHERN_PIKE, Species.defaultSpecies("DE"))
        assertEquals(Species.NORTHERN_PIKE, Species.defaultSpecies("FI"))
        assertEquals(Species.NORTHERN_PIKE, Species.defaultSpecies("JP"))
        assertEquals(Species.NORTHERN_PIKE, Species.defaultSpecies(null))
        assertEquals(Species.NORTHERN_PIKE, Species.defaultSpecies(""))
    }

    // Forecaster

    private fun makeHours(start: Double, count: Int): List<HourConditions> =
        (0 until count).map { HourConditions(start + it * 3600.0, 1015.0, 0.5, 15.0, 270.0, 18.0) }

    @Test fun testCurveAndBestWindowFavourTwilight() {
        val dayStart = utc(2026, 6, 21)
        val dayEnd = utc(2026, 6, 22)
        val hours = makeHours(dayStart - 48 * 3600, 97)
        val ctx = SpotContext(52.52, 13.405, WaterType.WARM_FRESHWATER, Species.WALLEYE, waterTempC = 21.0)
        val points = Forecaster.curve(ctx, hours, dayStart, dayEnd)
        assertEquals(97, points.size)
        assertTrue(points.all { it.index in 0.0..100.0 })

        val window = Forecaster.bestWindow(points)!!
        assertEquals(7200.0, window.end - window.start, 1.0)
        val s = Astro.events(sun, dayStart, dayEnd, 52.52, 13.405)
        val mid = window.start + 3600
        val toTwilight = min(abs(mid - s.rises[0]), abs(mid - s.sets[0]))
        assertTrue(toTwilight < 2.5 * 3600)

        // Midday must score below the best window.
        val noon = points.first { it.time == utc(2026, 6, 21, 11) }
        assertTrue(noon.index < window.meanIndex)
    }

    @Test fun testCurveSkipsInstantsWithoutWeather() {
        val start = utc(2026, 6, 21)
        val hours = makeHours(start, 6)
        val ctx = SpotContext(0.0, 0.0, WaterType.WARM_FRESHWATER, Species.WALLEYE)
        val points = Forecaster.curve(ctx, hours, start, start + 12 * 3600, step = 3600.0)
        assertEquals(6, points.size)
        assertTrue(points.all { it.contributions.thermal == 0.0 })
    }

    @Test fun testIndexIsNeutralAtZero() {
        assertEquals(50.0, Forecaster.index(Contributions()), 1e-9)
    }

    @Test fun testDepthAdvice() {
        assertNotNull(Forecaster.depthAdvice(15.0, 26.0, Species.WALLEYE))
        assertNull(Forecaster.depthAdvice(4.0, 26.0, Species.WALLEYE))
        assertNull(Forecaster.depthAdvice(15.0, 15.0, Species.WALLEYE))
    }

    // Tide

    private fun station(mean: Double, vararg c: TideStation.Constituent) = TideStation("t", "t", mean, c.toList())
    private fun con(name: String, amplitude: Double, phase: Double) = TideStation.Constituent(name, amplitude, phase)

    @Test fun testS2OnlyTideHasHighWaterAtMidnightAndNoonUT() {
        val st = station(2.0, con("S2", 1.0, 0.0))
        assertEquals(3.0, st.height(utc(2026, 4, 1, 0)), 1e-6)
        assertEquals(3.0, st.height(utc(2026, 4, 1, 12)), 1e-6)
        assertEquals(1.0, st.height(utc(2026, 4, 1, 6)), 1e-6)
        assertEquals(0.0, st.rate(utc(2026, 4, 1, 0)), 1e-3)
    }

    @Test fun testM2PeriodIsTwelvePointFourTwoHours() {
        val st = station(0.0, con("M2", 1.3, 110.0))
        val t = utc(2026, 4, 1, 3, 17)
        val period = 12.4206012 * 3600
        assertEquals(st.height(t), st.height(t + period), 2e-3)
        assertTrue(abs(st.height(t) - st.height(t + period / 2)) > 0.05)
    }

    @Test fun testTideCurveCoversBothEndsAndMatchesHeight() {
        val st = station(1.0, con("S2", 0.5, 0.0))
        val from = utc(2026, 5, 1)
        val to = utc(2026, 5, 2)
        val c = st.curve(from, to, 900.0)
        assertEquals(97, c.size)
        assertEquals(from, c.first().time, 0.0)
        assertEquals(to, c.last().time, 0.0)
        for (s in c) assertEquals(st.height(s.time), s.height, 1e-12)
        assertEquals(1.5, c.maxOf { it.height }, 1e-6)
        assertTrue(st.curve(to, from).isEmpty())
        // A span that is not a multiple of the step still ends exactly at `to`.
        assertEquals(listOf(0.0, 900.0, 1000.0), st.curve(from, from + 1000, 900.0).map { it.time - from })
    }

    @Test fun testS2ExtremesAtSixHourIntervals() {
        val st = station(2.0, con("S2", 1.0, 0.0))
        val ex = st.extremes(utc(2026, 4, 1, 1), utc(2026, 4, 2, 1))
        assertEquals(listOf(false, true, false, true), ex.map { it.isHigh })
        for ((e, h) in ex.zip(listOf(6, 12, 18, 24))) {
            assertEquals(0.0, e.time - (utc(2026, 4, 1) + h * 3600), 60.0)
            assertEquals(if (e.isHigh) 3.0 else 1.0, e.height, 1e-4)
        }
        assertTrue(st.extremes(utc(2026, 4, 1, 1), utc(2026, 4, 1, 1)).isEmpty())
    }

    @Test fun testTideTermRange() {
        assertEquals(-1.0, Terms.tide(0.0, 0.5), 0.0)
        assertEquals(1.0, Terms.tide(-0.5, 0.5), 0.0)
        assertEquals(0.0, Terms.tide(0.2, 0.0), 0.0)
        // Peak flow of a neap day scores below peak flow of a spring day.
        assertEquals(1.0, Terms.tide(1.0, 1.0, 1.0), 1e-12)
        assertEquals(0.7, Terms.tide(0.5, 0.5, 1.0), 1e-12)
        assertEquals(1.0, Terms.springTide(0.0), 1e-12)
        assertEquals(1.0, Terms.springTide(180.0), 1e-12)
        assertEquals(-1.0, Terms.springTide(90.0), 1e-12)
    }

    @Test fun testSpringTideDayOutscoresNeapTideDay() {
        // M2 and S2 in phase at new moon (6 Jan 2000) and opposed at first quarter (14 Jan 2000).
        val st = station(2.0, con("M2", 1.0, 0.0), con("S2", 0.45, 0.0))
        fun bestTide(day: Double): Double {
            val c = SpotContext(50.0, -4.0, WaterType.INSHORE_SALT, Species.WALLEYE, tide = st)
            return Forecaster.curve(c, emptyList(), day, day + 86400, fillMissingWeather = true)
                .maxOfOrNull { it.contributions.tide } ?: 0.0
        }
        assertTrue(bestTide(utc(2000, 1, 6)) > bestTide(utc(2000, 1, 14)) + 0.05)
    }

    @Test fun testSaltSpotWithoutStationFollowsMoonPhase() {
        val c = SpotContext(50.0, -4.0, WaterType.INSHORE_SALT, Species.WALLEYE)
        fun tide(t: Double): Double =
            Forecaster.curve(c, emptyList(), t, t, fillMissingWeather = true).firstOrNull()?.contributions?.tide ?: 0.0
        assertTrue(tide(utc(2000, 1, 6, 18)) > 0.15)
        assertTrue(tide(utc(2000, 1, 14, 13)) < -0.15)
        val fresh = SpotContext(50.0, -4.0, WaterType.WARM_FRESHWATER, Species.WALLEYE)
        val t = utc(2000, 1, 6, 18)
        assertEquals(0.0, Forecaster.curve(fresh, emptyList(), t, t, fillMissingWeather = true).firstOrNull()?.contributions?.tide ?: 1.0, 0.0)
    }

    // Support

    @Test fun testGammaPoissonShrinkage() {
        var m = CatchRateMultiplier()
        assertEquals(1.0, m.mean, 0.0)
        m = m.updated(0, 2.0)       // blank trip pulls the rate down
        assertEquals(5.0 / 7.0, m.mean, 1e-9)
        m = m.updated(9, 2.0)
        assertEquals(14.0 / 9.0, m.mean, 1e-9)
        m = m.updated(3, 0.0)       // ignored: no exposure
        assertEquals(14.0 / 9.0, m.mean, 1e-9)
    }

    @Test fun testExpectedCatchIntegratesRelativeRate() {
        val t0 = utc(2026, 6, 21, 6)
        fun flat(index: Double) = (0..8).map { ScorePoint(t0 + it * 900.0, index, Contributions()) }
        val end = t0 + 7200
        assertEquals(1.0, CatchModel.expectedCatch(flat(50.0), t0, end), 1e-9)
        assertEquals(1.5, CatchModel.expectedCatch(flat(75.0), t0, end), 1e-9)
        assertEquals(6.0, CatchModel.expectedCatch(flat(75.0), t0, end, baseline = 2.0), 1e-9)
        // No weather -> neutral; half-covered trip -> half neutral.
        assertEquals(1.0, CatchModel.expectedCatch(emptyList(), t0, end), 1e-9)
        assertEquals(0.5 * (2 + 1), CatchModel.expectedCatch(flat(100.0), t0 + 3600, end + 3600), 1e-9)
        // Linear ramp 0 -> 100 over two hours averages to neutral.
        val ramp = listOf(ScorePoint(t0, 0.0, Contributions()), ScorePoint(end, 100.0, Contributions()))
        assertEquals(1.0, CatchModel.expectedCatch(ramp, t0, end), 1e-9)
        assertEquals(0.0, CatchModel.expectedCatch(flat(50.0), end, t0), 0.0)
    }

    @Test fun testFittedMultiplier() {
        val trips = listOf(
            CatchRateMultiplier.Observation(0, 2.0), CatchRateMultiplier.Observation(9, 2.0), CatchRateMultiplier.Observation(3, 0.0),
        )
        val m = CatchRateMultiplier.fitted(trips)
        assertEquals(14.0 / 9.0, m.mean, 1e-9)
        assertEquals(m, CatchRateMultiplier.fitted(trips.reversed()))
        assertEquals(1.0, CatchRateMultiplier.fitted(emptyList()).mean, 0.0)
    }

    @Test fun testScorecardFilesHoursAndFishByForecastBand() {
        val t0 = utc(2026, 6, 21, 6)
        // One hour at 70, then one hour at 30 (the step between them takes 15 minutes).
        val points = (0..8).map { ScorePoint(t0 + it * 900.0, if (it <= 4) 70.0 else 30.0, Contributions()) }
        val end = t0 + 7200
        val catches = listOf(t0 + 600, t0 + 1800, t0 + 6600)
        val record = Scorecard.record(points, t0, end, catches)
        assertEquals(listOf(1, 0, 0, 2), record?.catches)
        assertEquals(2.0, record?.hours?.sum() ?: 0.0, 1e-9)
        assertEquals(1.0, record?.hours?.get(3) ?: 0.0, 0.1)
        assertEquals(0.75, record?.hours?.get(0) ?: 0.0, 0.1)
        assertEquals(50.0, record?.meanIndex ?: 0.0, 3.0)
        // Nothing is guessed: no forecast for part of the trip, or a fish outside it, gives no record.
        assertNull(Scorecard.record(points.take(4), t0, end, emptyList()))
        assertNull(Scorecard.record(points, t0, end, listOf(end + 3600)))
        assertEquals(2, Scorecard.band(64.9))
        assertEquals(3, Scorecard.band(65.0))
    }

    @Test fun testFactorSlicesKeepUnweightedScoresPerHour() {
        val t0 = utc(2026, 6, 21, 6)
        val w = Weights(0.25, 0.2, 0.2, 0.15, 0.1, 0.0)
        // Light score 0.8 in the first hour, -0.4 after; wind constant 0.5; tide has no weight.
        val points = (0..10).map { k ->
            val c = Contributions(light = w.light * (if (k < 4) 0.8 else -0.4), wind = w.wind * 0.5, tide = 0.3)
            ScorePoint(t0 + k * 900.0, 50.0, c)
        }
        val end = t0 + 9000   // 2.5 h
        val catches = listOf(t0 + 120, t0 + 8900, end)
        val slices = Scorecard.slices(points, w, t0, end, catches)
        assertEquals(3, slices?.size)
        assertEquals(listOf(1, 0, 2), slices?.map { it.catches })
        assertEquals(listOf(1.0, 1.0, 0.5), slices?.map { it.hours })
        assertEquals(0.8, slices!![0].z[0], 0.2)
        assertEquals(-0.4, slices[2].z[0], 1e-9)
        assertEquals(0.5, slices[1].z[2], 1e-9)
        assertEquals(0.0, slices[1].z[5], 0.0)
        assertNull(Scorecard.slices(points.take(3), w, t0, end, emptyList()))
        assertNull(Scorecard.slices(points, w, t0, end, listOf(end + 600)))
    }

    @Test fun testScorecardVerdictNeedsBothSides() {
        val good = Scorecard.TripRecord(listOf(0.0, 0.0, 2.0, 2.0), listOf(0, 0, 3, 5), 66.0)
        val slow = Scorecard.TripRecord(listOf(2.0, 2.0, 0.0, 0.0), listOf(1, 1, 0, 0), 34.0)
        assertEquals(Scorecard.Verdict.NOT_ENOUGH, Scorecard.summary(listOf(good)).verdict)
        val both = Scorecard.summary(listOf(good, slow))
        assertEquals(Scorecard.Verdict.TRACKS, both.verdict)
        assertEquals(2.0, both.goodRate ?: 0.0, 1e-9)
        assertEquals(0.5, both.slowRate ?: 0.0, 1e-9)
        assertEquals(2.5, both.rate(3) ?: 0.0, 1e-9)
        val reversed = Scorecard.TripRecord(listOf(2.0, 2.0, 0.0, 0.0), listOf(4, 5, 0, 0), 34.0)
        assertEquals(Scorecard.Verdict.FLAT, Scorecard.summary(listOf(good, reversed)).verdict)
        val blankGood = Scorecard.TripRecord(listOf(0.0, 0.0, 2.0, 2.0), listOf(0, 0, 1, 0), 66.0)
        assertEquals(Scorecard.Verdict.INVERSE, Scorecard.summary(listOf(blankGood, reversed)).verdict)
    }

    @Test fun testBarometerFusionKeepsForecastLevelAndDeviceTrend() {
        val t0 = utc(2026, 5, 1)
        val forecast = (0..24).map { PressureSample(t0 + it * 3600.0, 1015.0) }
        // Phone ~200 m above sea level: station pressure ~990, falling 0.5 hPa/h from 10:00 to 12:00.
        val session = t0 + 10 * 3600
        val device = (0..12).map { PressureSample(session + it * 600.0, 990.5 - 0.5 * it / 6) }
        val fused = Terms.PressureSeries(Barometry.fuse(forecast, device))
        assertEquals(1015.5, fused.value(session)!!, 1e-9)
        assertEquals(1015.0, fused.value(session + 3600)!!, 1e-9)
        assertEquals(1014.5, fused.value(session + 7200)!!, 1e-9)
        assertEquals(1015.0, fused.value(t0 + 5 * 3600)!!, 1e-9)
        // Hourly forecast points inside the session are replaced: 10 + 13 + 12.
        assertEquals(35, fused.samples.size)

        // A reading from another elevation is dropped.
        val outlier = device + PressureSample(session + 3900, 970.0)
        assertEquals(35, Barometry.fuse(forecast, outlier).size)

        // Too few readings, too short a session, or readings outside the forecast: unchanged.
        assertEquals(25, Barometry.fuse(forecast, device.take(2)).size)
        assertEquals(25, Barometry.fuse(forecast, device.take(3)).size)
        assertEquals(25, Barometry.fuse(forecast, emptyList()).size)
        val stale = device.map { PressureSample(it.time - 86400 * 3, it.hPa) }
        assertEquals(25, Barometry.fuse(forecast, stale).size)
    }

    @Test fun testCurveFillsMissingWeatherFromAstronomyAlone() {
        val ctx = SpotContext(52.52, 13.405, WaterType.WARM_FRESHWATER, Species.WALLEYE)
        val from = utc(2026, 6, 21)
        val to = utc(2026, 6, 22)
        assertTrue(Forecaster.curve(ctx, emptyList(), from, to).isEmpty())

        val pts = Forecaster.curve(ctx, emptyList(), from, to, fillMissingWeather = true)
        assertEquals(97, pts.size)
        assertTrue(pts.all { !it.hasWeather })
        assertTrue(pts.all { it.contributions.wind == 0.0 && it.contributions.pressure == 0.0 })
        // Twilight still drives the best window: sunrise is 02:43 UT, sunset 19:33 UT.
        val best = Forecaster.bestWindow(pts)!!
        val mid = best.start + (best.end - best.start) / 2
        val nearDawn = abs(mid - utc(2026, 6, 21, 2, 43)) < 5400
        val nearDusk = abs(mid - utc(2026, 6, 21, 19, 33)) < 5400
        assertTrue("window centred at $mid", nearDawn || nearDusk)

        // Later in the day, the window never starts before the cutoff.
        val noon = utc(2026, 6, 21, 12)
        val later = Forecaster.bestWindow(pts, notBefore = noon)!!
        assertTrue(later.start >= noon)
        // Too little day left: no window.
        assertNull(Forecaster.bestWindow(pts, notBefore = utc(2026, 6, 21, 23, 30)))

        // Weather that covers part of the range is used where it exists.
        val hours = (0..6).map { HourConditions(from + it * 3600.0, 1015.0, 0.5, 18.0, null, 15.0) }
        val mixed = Forecaster.curve(ctx, hours, from, to, fillMissingWeather = true)
        assertEquals(97, mixed.size)
        assertEquals(25, mixed.count { it.hasWeather })
        assertTrue(mixed[0].contributions.wind > 0)
        // Unknown cloud is neutral, known cloud is not.
        val dawn = utc(2026, 6, 21, 2, 43)
        assertEquals(0.7, Terms.light(dawn, dawn, null, null), 1e-9)
        assertEquals(1.0, Terms.light(dawn, dawn, null, 1.0), 1e-9)
    }

    @Test fun testCurveUsesOverridePressure() {
        val start = utc(2026, 6, 21)
        val hours = makeHours(start - 48 * 3600, 60)
        val ctx = SpotContext(52.52, 13.405, WaterType.WARM_FRESHWATER, Species.WALLEYE)
        val at = start + 6 * 3600
        val falling = Terms.PressureSeries(hours.map { PressureSample(it.time, 1030 - (it.time - start) / 3600) })
        val base = Forecaster.curve(ctx, hours, at, at)
        val fused = Forecaster.curve(ctx, hours, at, at, pressure = falling)
        assertEquals(1, base.size)
        assertTrue(fused[0].contributions.pressure > base[0].contributions.pressure)
        assertEquals(base[0].contributions.light, fused[0].contributions.light, 0.0)
    }

    @Test fun testBarometry() {
        assertEquals(1013.25, Barometry.hPaFromKPa(101.325), 1e-9)
        assertEquals(1000.0, Barometry.seaLevel(1000.0, 0.0, 15.0), 1e-9)
        // ~12 hPa per 100 m near sea level.
        assertEquals(1012.0, Barometry.seaLevel(1000.0, 100.0, 15.0), 0.5)
        assertEquals(3.0, Barometry.bias(listOf(1001.0, 1003.0, 1010.0), listOf(1000.0, 1000.0, 1000.0))!!, 0.0)
        assertNull(Barometry.bias(emptyList(), emptyList()))
    }

    @Test fun testGeohash() {
        // Reference vector from the geohash specification.
        assertEquals("u4pruydqqvj", Geohash.encode(57.64911, 10.40744, 11))
        assertEquals("u33dc", Geohash.encode(52.52, 13.405, 5))
        val c = Geohash.decode("u33dc")!!
        assertEquals(52.52, c.first, 0.03)
        assertEquals(13.405, c.second, 0.03)
        assertNull(Geohash.decode("a!"))
        assertNull(Geohash.decode(""))
    }

    @Test fun testLightIsNeutralWithoutSunriseOrSunset() {
        // Polar day or night: no sun events. Not the bright-noon penalty all day.
        val noon = 1_750_000_000.0
        assertEquals(0.0, Terms.light(noon, null, null, null), 1e-9)
        // One event still counts.
        assertTrue(Terms.light(noon, noon, null, null) > 0.5)
    }

    // Species now

    private fun hoursAt(airTempC: Double, t: Double): List<HourConditions> =
        (-48..24).map { HourConditions(t + it * 3600.0, 1015.0, 0.5, 12.0, 270.0, airTempC) }

    @Test fun testEstimatedWaterTempNeedsADayOfHistory() {
        val now = utc(2026, 7, 1, 12)
        assertEquals(22.0, Terms.estimatedWaterTempC(hoursAt(22.0, now), now)!!, 1e-9)
        assertEquals(1.0, Terms.estimatedWaterTempC(hoursAt(-10.0, now), now)!!, 1e-9)
        assertNull(Terms.estimatedWaterTempC(hoursAt(22.0, now), now - 40 * 3600))
    }

    @Test fun testWarmWaterFavoursCrucianCarpOverTrout() {
        val now = utc(2026, 7, 1, 12)
        val context = SpotContext(52.5, 13.4, WaterType.WARM_FRESHWATER, Species.NORTHERN_PIKE)
        val ranked = Forecaster.speciesNow(context, hoursAt(24.0, now), now, 24.0)
        assertEquals(8, ranked.size)
        assertTrue(ranked.all { it.species.habitat == Species.Habitat.FRESH })
        assertEquals(Species.CRUCIAN_CARP, ranked.first().species)
        assertEquals(Species.RAINBOW_TROUT, ranked.last().species)
        // One-pass re-weighting gives the same index as scoring each species in full.
        for (item in ranked) {
            val c = context.copy(species = item.species, waterTempC = 24.0)
            val full = Forecaster.curve(c, hoursAt(24.0, now), now, now).first().index
            assertEquals(full, item.index, 1e-9)
        }
        val cold = Forecaster.speciesNow(context, hoursAt(12.0, now), now, 12.0)
        assertEquals(Species.RAINBOW_TROUT, cold.first().species)
    }

    @Test fun testNoSpeciesRankingWithoutWaterTemp() {
        val now = utc(2026, 7, 1, 12)
        val fresh = SpotContext(52.5, 13.4, WaterType.WARM_FRESHWATER, Species.WALLEYE)
        assertTrue(Forecaster.speciesNow(fresh, hoursAt(24.0, now), now, null).isEmpty())
    }

    @Test fun testSeaSpotsRankSaltwaterFishOnly() {
        val now = utc(2026, 7, 1, 12)
        val salt = SpotContext(54.4, 10.2, WaterType.INSHORE_SALT, Species.GENERAL)
        val cold = Forecaster.speciesNow(salt, hoursAt(10.0, now), now, 10.0)
        assertEquals(7, cold.size)
        assertTrue(cold.all { it.species.habitat == Species.Habitat.SALT })
        assertEquals(Species.ATLANTIC_COD, cold.first().species)
        val warm = Forecaster.speciesNow(salt, hoursAt(24.0, now), now, 24.0)
        assertEquals(Species.RED_DRUM, warm.first().species)
    }

    @Test fun testSpeciesChoicesFollowTheWater() {
        assertEquals(Species.GENERAL, Species.choices(WaterType.OFFSHORE).first())
        assertFalse(Species.choices(WaterType.OFFSHORE).contains(Species.WALLEYE))
        assertFalse(Species.choices(WaterType.WARM_FRESHWATER).contains(Species.ATLANTIC_COD))
        assertTrue(Species.choices(WaterType.COLD_FRESHWATER).contains(Species.RAINBOW_TROUT))
        assertEquals(Species.GENERAL, Species.defaultSpecies("DE", WaterType.INSHORE_SALT))
        assertEquals(Species.WALLEYE, Species.defaultSpecies("US", WaterType.WARM_FRESHWATER))
        // "Any fish" has no preferred temperature.
        assertEquals(0.0, Terms.thermal(2.0, Species.GENERAL), 0.0)
    }

    // Tide engine against NOAA's own predictions

    @Test fun testTideEngineTracksNOAAPredictions() {
        val start = utc(2026, 11, 20)
        for (fixture in TideFixtures.all) {
            val errors = fixture.noaa.mapIndexed { hour, noaa -> fixture.station.height(start + hour * 3600.0) - noaa }
            val rms = sqrt(errors.sumOf { it * it } / errors.size)
            val bias = errors.sum() / errors.size
            val range = fixture.noaa.max() - fixture.noaa.min()
            // Ten constituents against NOAA's 37: within 4 % of the tidal range (3 cm at least),
            // and no standing offset.
            assertTrue(fixture.station.name, rms < maxOf(0.03, 0.04 * range))
            assertTrue(fixture.station.name, abs(bias) < 0.02)
        }
    }

    @Test fun testNamesAndRawValuesMatchSwift() {
        // Not in the Swift suite: the raw values are stored on spots and sent in shared trips.
        assertEquals(16, Species.entries.size)
        assertEquals("largemouthBass", Species.entries.first().raw)
        assertEquals(Species.RED_DRUM, Species.fromRaw("redDrum"))
        assertEquals(WaterType.INSHORE_SALT, WaterType.fromRaw("inshoreSalt"))
        assertNotEquals(Species.GENERAL, Species.fromRaw("walleye"))
    }
}
