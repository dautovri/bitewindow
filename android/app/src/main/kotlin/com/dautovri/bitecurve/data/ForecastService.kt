package com.dautovri.bitecurve.data

import android.util.Log
import com.dautovri.bitecurve.core.Forecaster
import com.dautovri.bitecurve.core.Geohash
import com.dautovri.bitecurve.core.HourConditions
import com.dautovri.bitecurve.core.ScorePoint
import com.dautovri.bitecurve.core.SpotContext
import com.dautovri.bitecurve.core.TideStation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.time.Instant
import java.util.concurrent.TimeUnit

class Forecast(
    val hours: List<HourConditions>,
    val source: Source,
    /** When the data was downloaded, seconds since 1970. Null when nothing is saved. */
    val fetchedAt: Double? = null,
) {
    enum class Source { LIVE, CACHED }
}

/** Estimated water temperature from the worker (`/water`): "sst" at sea, "air" inland. */
@Serializable
data class WaterEstimate(val tempC: Double, val source: String)

/**
 * Port of App/BiteWindow/Services/ForecastService.swift: hourly weather from the cache worker
 * (backend/), keyed by geohash-5, with the last answer kept on disk for use without signal.
 * With no network and nothing saved the forecast is empty and the score rests on sun, moon
 * and tide alone; nothing here ever invents weather.
 */
class ForecastService(private val dir: File, private val baseUrl: () -> String) {
    private val json = Json { ignoreUnknownKeys = true }

    /** Short timeouts: with one bar of signal the saved forecast should show within seconds. */
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .callTimeout(20, TimeUnit.SECONDS)
        .build()

    @Serializable
    private class Payload(val gh: String = "", val hours: List<Hour> = emptyList()) {
        @Serializable
        class Hour(val t: String, val p: Double, val c: Double, val ws: Double, val wd: Double? = null, val ta: Double)
    }

    @Serializable
    private class TidePayload(val gh: String = "", val station: TideStation? = null)

    @Serializable
    private class WaterPayload(val tempC: Double? = null, val source: String? = null)

    /** Time of the last successful `prefetch`; screens reload when it changes. */
    private val prefetched = MutableStateFlow(0.0)
    val lastPrefetch: StateFlow<Double> = prefetched

    init {
        dir.mkdirs()
        prefetched.value = File(dir, "last-prefetch").takeIf { it.exists() }?.readText()?.toDoubleOrNull() ?: 0.0
    }

    private fun forecastFile(gh: String) = File(dir, "forecast-$gh.json")
    private fun tideFile(gh: String) = File(dir, "tide-$gh.json")
    private fun waterFile(gh: String, isSalt: Boolean) = File(dir, "water-${if (isSalt) "salt" else "fresh"}-$gh.json")

    private fun write(file: File, text: String) {
        val temp = File(dir, file.name + ".tmp")
        temp.writeText(text)
        if (!temp.renameTo(file)) { file.delete(); temp.renameTo(file) }
    }

    /** One GET; the status and body, or null when the worker could not be reached. */
    private suspend fun get(path: String, query: Map<String, String>): Pair<Int, String>? = withContext(Dispatchers.IO) {
        val url = "${baseUrl().trimEnd('/')}/$path".toHttpUrlOrNull()?.newBuilder()
            ?.apply { query.forEach { (k, v) -> addQueryParameter(k, v) } }?.build() ?: return@withContext null
        try {
            client.newCall(Request.Builder().url(url).build()).execute().use { it.code to it.body.string() }
        } catch (e: Exception) {
            Log.i("BiteCurve", "GET /$path failed: ${e.message}")
            null
        }
    }

    private fun decode(text: String): List<HourConditions>? {
        val payload = runCatching { json.decodeFromString<Payload>(text) }.getOrNull() ?: return null
        return payload.hours.mapNotNull { h ->
            val time = runCatching { Instant.parse(h.t) }.getOrNull() ?: return@mapNotNull null
            HourConditions(time.toEpochMilli() / 1000.0, h.p, h.c, h.ws, h.wd, h.ta)
        }
    }

    suspend fun forecast(latitude: Double, longitude: Double): Forecast {
        val gh = Geohash.encode(latitude, longitude, 5)
        val answer = get("wx", mapOf("gh" to gh))
        if (answer != null && answer.first == 200) {
            val hours = decode(answer.second)
            if (!hours.isNullOrEmpty()) {
                withContext(Dispatchers.IO) { write(forecastFile(gh), answer.second) }
                return Forecast(hours, Forecast.Source.LIVE, nowSeconds())
            }
        }
        return cached(latitude, longitude) ?: Forecast(emptyList(), Forecast.Source.CACHED)
    }

    /** `cached`, read off the calling thread (screens call this from the main thread). */
    suspend fun saved(latitude: Double, longitude: Double): Forecast? = withContext(Dispatchers.IO) { cached(latitude, longitude) }

    /** The forecast saved on disk for this location, without touching the network. */
    fun cached(latitude: Double, longitude: Double): Forecast? {
        val file = forecastFile(Geohash.encode(latitude, longitude, 5))
        val hours = runCatching { decode(file.readText()) }.getOrNull()
        if (hours.isNullOrEmpty()) return null
        return Forecast(hours, Forecast.Source.CACHED, file.lastModified() / 1000.0)
    }

    class Place(val latitude: Double, val longitude: Double, val isSalt: Boolean)

    /**
     * Downloads and saves the forecast (and tide constants and the water estimate) for every
     * place, so they are there when the signal is gone. Returns how many forecasts were saved.
     */
    suspend fun prefetch(places: List<Place>): Int {
        var saved = 0
        for (place in places) {
            if (forecast(place.latitude, place.longitude).source == Forecast.Source.LIVE) saved += 1
            if (place.isSalt) tideStation(place.latitude, place.longitude)
            waterEstimate(place.latitude, place.longitude, place.isSalt)
        }
        if (saved > 0) {
            val now = nowSeconds()
            withContext(Dispatchers.IO) { write(File(dir, "last-prefetch"), now.toString()) }
            prefetched.value = now
        }
        return saved
    }

    /** The bite curve over a finished trip from the real forecast. Empty without a spot. */
    suspend fun tripPoints(context: SpotContext?, from: Double, to: Double): List<ScorePoint> {
        if (context == null) return emptyList()
        val forecast = forecast(context.latitude, context.longitude)
        // One step past the end, so the curve brackets the whole trip however short it was.
        return withContext(Dispatchers.Default) { Forecaster.curve(context, forecast.hours, from, to + 900) }
    }

    // Water temperature

    private val waterMemo = HashMap<String, Pair<WaterEstimate?, Long>>()

    /**
     * The estimate saved on disk, without touching the network. Water changes by tenths of a
     * degree a day, so a copy up to ten days old is still better than none (offline trips).
     */
    fun cachedWaterEstimate(latitude: Double, longitude: Double, isSalt: Boolean): WaterEstimate? {
        val file = waterFile(Geohash.encode(latitude, longitude, 5), isSalt)
        val now = System.currentTimeMillis()
        // Asked on every redraw of a spot: the disk is read at most once a minute per spot.
        synchronized(waterMemo) {
            waterMemo[file.name]?.let { (estimate, at) -> if (now - at < 60_000) return estimate }
        }
        val estimate = if (file.exists() && now - file.lastModified() < 10 * 86_400_000L) {
            runCatching { json.decodeFromString<WaterEstimate>(file.readText()) }.getOrNull()
        } else null
        synchronized(waterMemo) { waterMemo[file.name] = estimate to now }
        return estimate
    }

    /**
     * Downloads the estimate when the saved one is older than 12 hours. Returns the best
     * available answer; null with no network and nothing saved, or no estimate.
     */
    suspend fun waterEstimate(latitude: Double, longitude: Double, isSalt: Boolean): WaterEstimate? {
        val gh = Geohash.encode(latitude, longitude, 5)
        val file = waterFile(gh, isSalt)
        val cached = cachedWaterEstimate(latitude, longitude, isSalt)
        if (cached != null && System.currentTimeMillis() - file.lastModified() < 12 * 3_600_000L) return cached
        val answer = get("water", mapOf("gh" to gh, "kind" to if (isSalt) "salt" else "fresh")) ?: return cached
        if (answer.first != 200) return cached
        val payload = runCatching { json.decodeFromString<WaterPayload>(answer.second) }.getOrNull() ?: return cached
        val temp = payload.tempC ?: return cached
        val source = payload.source?.takeIf { it == "sst" || it == "air" } ?: return cached
        if (temp < -3 || temp > 40) return cached
        val estimate = WaterEstimate(temp, source)
        withContext(Dispatchers.IO) { write(file, json.encodeToString(WaterEstimate.serializer(), estimate)) }
        synchronized(waterMemo) { waterMemo[file.name] = estimate to System.currentTimeMillis() }
        return estimate
    }

    /**
     * Harmonic constants for the nearest NOAA station, or null when there is none in range, or
     * no network and nothing cached. A saved answer is re-checked after 30 days (1 day for
     * "no station"); a stale copy is still used when the refresh fails.
     */
    suspend fun tideStation(latitude: Double, longitude: Double): TideStation? {
        val gh = Geohash.encode(latitude, longitude, 5)
        val file = tideFile(gh)
        val cached = withContext(Dispatchers.IO) {
            runCatching { json.decodeFromString<TidePayload>(file.readText()) }.getOrNull()
        }
        if (cached != null) {
            val maxAge = if (cached.station == null) 86_400_000L else 30 * 86_400_000L
            if (System.currentTimeMillis() - file.lastModified() < maxAge) return cached.station
        }
        val answer = get("tide", mapOf("gh" to gh)) ?: return cached?.station
        if (answer.first != 200) return cached?.station
        val payload = runCatching { json.decodeFromString<TidePayload>(answer.second) }.getOrNull() ?: return cached?.station
        withContext(Dispatchers.IO) { write(file, answer.second) }
        return payload.station
    }
}
