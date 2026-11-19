package com.dautovri.bitecurve

import com.dautovri.bitecurve.alerts.BiteAlerts
import com.dautovri.bitecurve.core.BiteWindow
import com.dautovri.bitecurve.core.Species
import com.dautovri.bitecurve.core.SpotContext
import com.dautovri.bitecurve.core.WaterType
import com.dautovri.bitecurve.data.DayOutlook
import com.dautovri.bitecurve.data.DayOutlooks
import com.dautovri.bitecurve.data.SpotSummaryInput
import com.dautovri.bitecurve.data.startOfDay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset

class BiteAlertsTest {
    private val berlin = ZoneId.of("Europe/Berlin")
    private fun utc(y: Int, mo: Int, d: Int, h: Int = 0, mi: Int = 0) = LocalDateTime.of(y, mo, d, h, mi).toEpochSecond(ZoneOffset.UTC).toDouble()

    private val wording = object : BiteAlerts.Wording {
        override fun clock(time: Double, zone: ZoneId) = java.time.Instant.ofEpochSecond(time.toLong()).atZone(zone).toLocalTime().toString()
        override fun startsInAnHour(range: String, index: Int) = "soon $range $index"
        override fun tomorrowTitle() = "tomorrow"
        override fun tomorrowBody(spot: String, index: Int, range: String) = "$spot $index $range"
    }

    private fun input(id: String) = SpotSummaryInput(id, "Spot $id", SpotContext(52.5, 13.4, WaterType.WARM_FRESHWATER, Species.NORTHERN_PIKE), berlin, emptyList())

    @Test fun plansAnHourBeforeAndTheEveningBeforeOnlyAboveTheThreshold() {
        val now = utc(2026, 6, 20, 10)   // noon in Berlin
        val day1 = startOfDay(now, berlin, 1)
        val day2 = startOfDay(now, berlin, 2)
        val days = mapOf(
            "a" to listOf(
                DayOutlook(day1, BiteWindow(day1 + 5 * 3600, day1 + 7 * 3600, 70.0)),
                DayOutlook(day2, BiteWindow(day2 + 5 * 3600, day2 + 7 * 3600, 55.0)),   // below the threshold
            ),
            "b" to listOf(DayOutlook(day1, BiteWindow(day1 + 20 * 3600, day1 + 22 * 3600, 80.0))),
        )
        val plan = BiteAlerts.plan(listOf(input("a"), input("b")), days, 65.0, now, wording)
        // One "tomorrow" alert at 19:00 Berlin today for the better spot, then one per window an hour ahead.
        assertEquals(listOf("eve.${(day1 - 5 * 3600).toLong()}", "soon.a.${day1.toLong()}", "soon.b.${day1.toLong()}"), plan.map { it.id })
        assertEquals(utc(2026, 6, 20, 17), plan[0].fireDate, 0.0)
        assertEquals("Spot b 80 20:00 – 22:00", plan[0].body)
        assertEquals(day1 + 4 * 3600, plan[1].fireDate, 0.0)
        assertEquals("soon 05:00 – 07:00 70", plan[1].body)
        assertTrue(plan.zipWithNext().all { (x, y) -> x.fireDate <= y.fireDate })
        // A lower threshold lets the weaker day in too.
        assertEquals(5, BiteAlerts.plan(listOf(input("a"), input("b")), days, 50.0, now, wording).size)
        // Nothing in the past: a window that starts within the hour gets no "in an hour" alert.
        assertTrue(BiteAlerts.plan(listOf(input("a")), days, 65.0, day1 + 4 * 3600 + 1, wording).none { it.id.startsWith("soon.a.${day1.toLong()}") })
    }

    @Test fun dayOutlooksStartAtTheSpotsMidnightAndTodayNeverRecommendsThePast() {
        val now = utc(2026, 6, 20, 15)
        val context = SpotContext(52.52, 13.405, WaterType.WARM_FRESHWATER, Species.WALLEYE)
        // No weather at all: sun and moon still give every day a window.
        val days = DayOutlooks.compute(context, emptyList(), berlin, 3, now)
        assertEquals(3, days.size)
        assertEquals(utc(2026, 6, 19, 22), days[0].date, 0.0)   // midnight in Berlin (UTC+2)
        assertTrue(days[0].window!!.start >= now - 900)
        assertTrue(days.all { it.window != null && it.index!! in 0.0..100.0 })
        assertEquals(86_400.0, days[1].date - days[0].date, 0.0)
    }

    @Test fun spotZoneComesFromTheCoordinates() {
        val lookup = com.dautovri.bitecurve.data.TzLookup.parse(java.io.File("src/main/res/raw/tzlookup.txt").readText())
        assertEquals("America/Chicago", lookup.zoneAt(44.933, -93.563))     // Lake Minnetonka
        assertEquals("America/Chicago", lookup.zoneAt(32.84, -95.58))       // Lake Fork
        assertEquals("Europe/Lisbon", lookup.zoneAt(38.70, -9.40))          // Estoril
        assertEquals("Europe/Berlin", lookup.zoneAt(52.4653, 13.1901))
        assertEquals(null, lookup.zoneAt(91.0, 0.0))
        // The package's own test file, all of it.
        val vectors = javaClass.getResourceAsStream("/tzlookup-vectors.txt")!!.bufferedReader().readLines().filter { it.isNotBlank() }
        assertTrue(vectors.size > 1000)
        for (line in vectors) {
            val (lat, lon, zone) = line.split(' ')
            assertEquals(line, zone, lookup.zoneAt(lat.toDouble(), lon.toDouble()))
        }
        // Every zone the table can answer with is one this platform knows.
        assertTrue(java.io.File("src/main/res/raw/tzlookup.txt").readLines()[1].split(',').all { runCatching { ZoneId.of(it) }.isSuccess })
    }

    @Test
    fun freeAlertsStopAtTomorrow() {
        // Free alerts cover the days the free forecast shows; Pro gets the week.
        assertEquals(2, BiteAlerts.horizon(isPro = false))
        assertEquals(7, BiteAlerts.horizon(isPro = true))
    }
}
