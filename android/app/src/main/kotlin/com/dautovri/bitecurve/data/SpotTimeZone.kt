package com.dautovri.bitecurve.data

import android.content.Context
import com.dautovri.bitecurve.R

/**
 * A spot's own time zone from its coordinates, so a lake two zones away is planned on that
 * lake's clock. iOS asks Apple's geocoder; Android has no such service, so the zone comes from
 * a table inside the app: no network and no permission.
 *
 * The table and the lookup are tz-lookup 6.1.25 by Dark Sky (public domain, CC0): a quadtree
 * of the world's zones packed into 65 KB of text. It is right away from zone borders and can
 * name the neighbouring zone within a few kilometres of one.
 */
class TzLookup(private val data: String, private val zones: List<String>) {
    /** The IANA zone id at a point; null for coordinates off the globe. */
    fun zoneAt(latitude: Double, longitude: Double): String? {
        if (!(latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180)) return null
        if (latitude >= 90) return "Etc/GMT"
        // A line-by-line port of tzlookup() in tz.js; the variable names follow tz_template.js.
        var n = -1
        var x = 48 * (180 + longitude) / 360.00000000000006
        var y = 24 * (90 - latitude) / 180.00000000000003
        var u = x.toInt()
        var v = y.toInt()
        var i = 96 * v + 2 * u
        i = 56 * data[i].code + data[i + 1].code - 1995
        while (i + zones.size < 3136) {
            n += i + 1
            y = 2 * (y - v) % 2
            v = y.toInt()
            x = 2 * (x - u) % 2
            u = x.toInt()
            i = 8 * n + 4 * v + 2 * u + 2304
            i = 56 * data[i].code + data[i + 1].code - 1995
        }
        return zones[i + zones.size - 3136]
    }

    companion object {
        /** `text` is res/raw/tzlookup.txt: the packed tree on the first line, the zone ids on the second. */
        fun parse(text: String): TzLookup {
            val lines = text.lines()
            return TzLookup(lines[0], lines[1].split(','))
        }
    }
}

object SpotTimeZone {
    @Volatile private var table: TzLookup? = null

    fun zoneAt(context: Context, latitude: Double, longitude: Double): String? {
        val lookup = table ?: synchronized(this) {
            table ?: TzLookup.parse(context.resources.openRawResource(R.raw.tzlookup).bufferedReader().use { it.readText() }).also { table = it }
        }
        return lookup.zoneAt(latitude, longitude)
    }

    /** Gives a spot saved without a zone (or with an unknown one) its zone. */
    fun resolveIfNeeded(context: Context, store: Store, spot: Spot) {
        if (spot.timeZoneId != null) return
        val zone = zoneAt(context, spot.latitude, spot.longitude) ?: return
        store.updateSpot(spot.id) { it.copy(timeZoneId = zone) }
    }
}
