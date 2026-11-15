package com.dautovri.bitecurve.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.max

/**
 * The Kotlin engine against the Swift engine. `golden.json` is written by `android/parity`
 * (the real BiteCore package run on fixed inputs); every number in it must come out of this
 * port again. Scores and angles agree to 1e-9 (the platforms' sin/exp differ in the last
 * digit, so not bit for bit); times found by bisection agree to within a second.
 */
class GoldenTest {
    private val golden: JsonObject = Json.parseToJsonElement(
        javaClass.getResourceAsStream("/golden.json")!!.readBytes().decodeToString(),
    ).jsonObject

    private val eps = 1e-9
    private var worst = 0.0
    private var worstTime = 0.0

    private fun JsonElement.d(): Double = jsonPrimitive.double
    private fun JsonElement.dOrNull(): Double? = if (this is JsonNull) null else jsonPrimitive.double
    private fun JsonElement.doubles(): List<Double> = jsonArray.map { it.d() }
    private fun JsonObject.arr(key: String): JsonArray = getValue(key).jsonArray
    private fun JsonObject.num(key: String): Double = getValue(key).d()

    private fun close(expected: Double, actual: Double, what: String, tolerance: Double = eps) {
        worst = max(worst, abs(expected - actual))
        assertEquals(what, expected, actual, tolerance)
    }

    private fun closeTime(expected: Double, actual: Double, what: String, tolerance: Double = 1.0) {
        worstTime = max(worstTime, abs(expected - actual))
        assertEquals(what, expected, actual, tolerance)
    }

    private fun station(o: JsonObject) = TideStation(
        o.getValue("id").jsonPrimitive.content, o.getValue("name").jsonPrimitive.content, o.num("meanLevel"),
        o.arr("constituents").map {
            val c = it.jsonObject
            TideStation.Constituent(c.getValue("name").jsonPrimitive.content, c.num("amplitude"), c.num("phase"))
        },
    )

    @Test fun astroMatchesSwift() {
        val rows = golden.arr("astro")
        assertEquals(42, rows.size)
        for (row in rows) {
            val r = row.jsonObject
            val t = r.num("t")
            val lat = r.num("lat")
            val lon = r.num("lon")
            val jd = Astro.julianDay(t)
            close(r.num("jd"), jd, "jd")
            val sun = Astro.sun(jd)
            val moon = Astro.moon(jd)
            r.arr("sun").doubles().zip(listOf(sun.ra, sun.dec, sun.lon, sun.parallax)).forEach { (e, a) -> close(e, a, "sun") }
            r.arr("moon").doubles().zip(listOf(moon.ra, moon.dec, moon.lon, moon.parallax)).forEach { (e, a) -> close(e, a, "moon") }
            close(r.num("phase"), Astro.moonPhaseAngle(t), "phase")
            close(r.num("illum"), Astro.moonIllumination(t), "illum")
            close(r.num("haSun"), Astro.hourAngle(Astro.Body.SUN, t, lon), "haSun")
            close(r.num("haMoon"), Astro.hourAngle(Astro.Body.MOON, t, lon), "haMoon")
            close(r.num("altSun"), Astro.altitude(Astro.Body.SUN, t, lat, lon), "altSun")
            close(r.num("altMoon"), Astro.altitude(Astro.Body.MOON, t, lat, lon), "altMoon")
        }
        println("PARITY astro: worst difference $worst")
    }

    @Test fun sunAndMoonEventsMatchSwift() {
        var count = 0
        for (row in golden.arr("events")) {
            val r = row.jsonObject
            val body = if (r.getValue("body").jsonPrimitive.content == "sun") Astro.Body.SUN else Astro.Body.MOON
            val e = Astro.events(body, r.num("from"), r.num("to"), r.num("lat"), r.num("lon"))
            for ((key, actual) in listOf("rises" to e.rises, "sets" to e.sets, "upper" to e.upperTransits, "lower" to e.lowerTransits)) {
                val expected = r.arr(key).doubles()
                assertEquals("$key count at ${r.num("lat")}", expected.size, actual.size)
                expected.zip(actual).forEach { (x, a) -> closeTime(x, a, key); count += 1 }
            }
        }
        assertTrue(count > 300)
        println("PARITY events: $count rise/set/transit times, worst difference $worstTime s")
    }

    @Test fun tidesMatchSwift() {
        for (row in golden.arr("tides")) {
            val r = row.jsonObject
            val st = station(r.getValue("station").jsonObject)
            val times = r.arr("times").doubles()
            times.zip(r.arr("heights").doubles()).forEach { (t, h) -> close(h, st.height(t), "height") }
            times.zip(r.arr("rates").doubles()).forEach { (t, x) -> close(x, st.rate(t), "rate") }
            val extremes = st.extremes(r.num("from"), r.num("to"))
            val expected = r.arr("extremes")
            assertEquals(expected.size, extremes.size)
            expected.zip(extremes).forEach { (x, a) ->
                val e = x.doubles()
                closeTime(e[0], a.time, "extreme time", 30.0)
                // The height is flat at a turning point, so a few seconds do not show in it.
                assertEquals(e[1], a.height, 1e-6)
                assertEquals(e[2] == 1.0, a.isHigh)
            }
            val curve = st.curve(r.num("from"), r.num("from") + 86_400)
            val expectedCurve = r.arr("curve")
            assertEquals(expectedCurve.size, curve.size)
            expectedCurve.zip(curve).forEach { (x, a) ->
                val e = x.doubles()
                assertEquals(e[0], a.time, 0.0)
                close(e[1], a.height, "curve")
            }
        }
        println("PARITY tides: worst difference $worst m, extremes $worstTime s")
    }

    private fun window(expected: JsonElement, actual: BiteWindow?, what: String) {
        if (expected is JsonNull) {
            assertNull(what, actual)
            return
        }
        assertNotNull(what, actual)
        val e = expected.doubles()
        assertEquals(what, e[0], actual!!.start, 0.0)
        assertEquals(what, e[1], actual.end, 0.0)
        close(e[2], actual.meanIndex, what)
    }

    @Test fun curvesWindowsSpeciesAndTripsMatchSwift() {
        var points = 0
        val cases = golden.arr("curves")
        assertEquals(8, cases.size)
        for (row in cases) {
            val r = row.jsonObject
            val name = r.getValue("name").jsonPrimitive.content
            val c = r.getValue("ctx").jsonObject
            val context = SpotContext(
                latitude = c.num("lat"), longitude = c.num("lon"),
                water = WaterType.fromRaw(c.getValue("water").jsonPrimitive.content)!!,
                species = Species.fromRaw(c.getValue("species").jsonPrimitive.content)!!,
                bankBearingDeg = c.getValue("bank").dOrNull(), waterTempC = c.getValue("waterTemp").dOrNull(),
                tide = c["station"]?.let { station(it.jsonObject) },
            )
            val hours = r.arr("hours").map {
                val h = it.jsonArray
                HourConditions(h[0].d(), h[1].d(), h[2].d(), h[3].d(), h[4].dOrNull(), h[5].d())
            }
            val from = r.num("from")
            val to = r.num("to")
            val fill = r.getValue("fill").jsonPrimitive.boolean

            val curve = Forecaster.curve(context, hours, from, to, fillMissingWeather = fill)
            val expected = r.arr("points")
            assertEquals(name, expected.size, curve.size)
            expected.zip(curve).forEach { (x, p) ->
                val e = x.doubles()
                assertEquals(name, e[0], p.time, 0.0)
                close(e[1], p.index, "$name index")
                val k = p.contributions
                listOf(k.light, k.thermal, k.wind, k.pressure, k.solunar, k.tide).forEachIndexed { i, a ->
                    close(e[2 + i], a, "$name factor $i")
                }
                assertEquals(name, e[8] == 1.0, p.hasWeather)
                points += 1
            }

            val firstDay = curve.filter { it.time < from + 86_400 }
            window(r.getValue("best"), Forecaster.bestWindow(curve), "$name best")
            window(r.getValue("bestFirstDay"), Forecaster.bestWindow(firstDay), "$name first day")
            window(r.getValue("bestAfter"), Forecaster.bestWindow(firstDay, notBefore = r.num("notBefore")), "$name not before")
            window(r.getValue("best3h"), Forecaster.bestWindow(curve, length = 3 * 3600.0), "$name 3 h")

            val sn = r.getValue("speciesNow").jsonObject
            val ranked = Forecaster.speciesNow(context, hours, sn.num("now"), sn.getValue("waterTemp").dOrNull())
            val expectedRanked = sn.arr("ranked")
            assertEquals(name, expectedRanked.size, ranked.size)
            expectedRanked.zip(ranked).forEach { (x, a) ->
                assertEquals(name, x.jsonArray[0].jsonPrimitive.content, a.species.raw)
                close(x.jsonArray[1].d(), a.index, "$name species index")
            }

            val trip = r.getValue("trip").jsonObject
            val tripFrom = trip.num("from")
            val tripTo = trip.num("to")
            val catchTimes = trip.arr("catchTimes").doubles()
            val tripPoints = Forecaster.curve(context, hours, tripFrom, tripTo + 900, fillMissingWeather = fill)
            close(trip.num("expected"), CatchModel.expectedCatch(tripPoints, tripFrom, tripTo), "$name expected catch")
            val record = Scorecard.record(tripPoints, tripFrom, tripTo, catchTimes)
            val expectedRecord = trip.getValue("record")
            if (expectedRecord is JsonNull) assertNull(name, record) else {
                val e = expectedRecord.jsonObject
                e.arr("hours").doubles().zip(record!!.hours).forEach { (x, a) -> close(x, a, "$name band hours") }
                assertEquals(name, e.arr("catches").doubles().map { it.toInt() }, record.catches)
                close(e.num("mean"), record.meanIndex, "$name mean index")
            }
            val weights = Weights.prior(context.water, context.species)
            val slices = Scorecard.slices(tripPoints, weights, tripFrom, tripTo, catchTimes)
            val expectedSlices = trip.getValue("slices")
            if (expectedSlices is JsonNull) assertNull(name, slices) else {
                assertEquals(name, expectedSlices.jsonArray.size, slices!!.size)
                expectedSlices.jsonArray.zip(slices).forEach { (x, a) ->
                    val e = x.doubles()
                    close(e[0], a.hours, "$name slice hours")
                    assertEquals(name, e[1].toInt(), a.catches)
                    a.z.forEachIndexed { i, z -> close(e[2 + i], z, "$name slice z$i") }
                }
            }
        }
        assertTrue(points > 2000)
        println("PARITY curves: $points scored points in ${cases.size} cases, worst difference $worst")
    }

    @Test fun barometerFusionAndGeohashMatchSwift() {
        val f = golden.getValue("fuse").jsonObject
        fun samples(key: String) = f.arr(key).map { PressureSample(it.jsonArray[0].d(), it.jsonArray[1].d()) }
        val fused = Barometry.fuse(samples("forecast"), samples("device"))
        val expected = samples("fused")
        assertEquals(expected.size, fused.size)
        expected.zip(fused).forEach { (e, a) ->
            assertEquals(e.time, a.time, 0.0)
            close(e.hPa, a.hPa, "fused")
        }
        for (row in golden.arr("geohash")) {
            val g = row.jsonArray
            assertEquals(g[3].jsonPrimitive.content, Geohash.encode(g[0].d(), g[1].d(), g[2].d().toInt()))
        }
    }
}
