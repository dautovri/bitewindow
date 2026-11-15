package com.dautovri.bitecurve.data

import com.dautovri.bitecurve.core.CatchModel
import com.dautovri.bitecurve.core.CatchRateMultiplier
import com.dautovri.bitecurve.core.FactorSlice
import com.dautovri.bitecurve.core.Scorecard
import com.dautovri.bitecurve.core.Species
import com.dautovri.bitecurve.core.SpotContext
import com.dautovri.bitecurve.core.WaterType
import kotlinx.serialization.Serializable
import java.time.ZoneId
import java.util.Locale
import java.util.UUID

// The same records as the iOS app's SwiftData models (App/BiteWindow/Models/Models.swift),
// kept in one JSON file on the device. Times are seconds since 1970.

fun nowSeconds(): Double = System.currentTimeMillis() / 1000.0

@Serializable
data class Spot(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val latitude: Double,
    val longitude: Double,
    val waterRaw: String = WaterType.WARM_FRESHWATER.raw,
    val speciesRaw: String = Species.defaultSpecies(Locale.getDefault().country).raw,
    /** Bearing from open water to the fished bank. */
    val bankBearingDeg: Double? = null,
    /** The angler's own reading; null uses the estimate. */
    val waterTempC: Double? = null,
    /** The spot's own time zone (see `SpotTimeZone`); null until known, and the phone's zone is used. */
    val timeZoneId: String? = null,
    val createdAt: Double = nowSeconds(),
) {
    val water: WaterType get() = WaterType.fromRaw(waterRaw) ?: WaterType.WARM_FRESHWATER
    val species: Species get() = Species.fromRaw(speciesRaw) ?: Species.defaultSpecies(Locale.getDefault().country)
    val isSalt: Boolean get() = water.isSalt

    val zone: ZoneId
        get() = timeZoneId?.let { runCatching { ZoneId.of(it) }.getOrNull() } ?: ZoneId.systemDefault()

    /** A water changed to another habitat cannot keep its fish. */
    fun withWater(water: WaterType): Spot {
        val fish = if (species.livesIn(water)) species else Species.defaultSpecies(Locale.getDefault().country, water)
        return copy(waterRaw = water.raw, speciesRaw = fish.raw)
    }

    /**
     * The water temperature the score uses, and where it came from: the angler's own reading
     * when there is one, else the saved estimate (satellite at sea, modelled from air inland).
     */
    fun waterReading(service: ForecastService): WaterReading? {
        waterTempC?.let { return WaterReading(it, WaterReading.Source.MEASURED) }
        val estimate = service.cachedWaterEstimate(latitude, longitude, isSalt) ?: return null
        return WaterReading(estimate.tempC, if (estimate.source == "sst") WaterReading.Source.SATELLITE else WaterReading.Source.MODELLED)
    }

    fun context(service: ForecastService): SpotContext =
        SpotContext(latitude, longitude, water, species, bankBearingDeg, waterReading(service)?.tempC)
}

data class WaterReading(val tempC: Double, val source: Source) {
    enum class Source(val wireName: String) { MEASURED("measured"), SATELLITE("satellite"), MODELLED("modelled") }

    val isMeasured: Boolean get() = source == Source.MEASURED
}

/**
 * A trip records effort as well as fish: zero-catch trips are kept on purpose,
 * because a model trained only on successful trips learns survivorship.
 */
@Serializable
data class Trip(
    val id: String = UUID.randomUUID().toString(),
    val spotId: String? = null,
    val startedAt: Double = nowSeconds(),
    val endedAt: Double? = null,
    val catchCount: Int = 0,
    val notes: String = "",
    /** Catch the global model expected for this trip, fixed when the trip ends. */
    val expectedCatch: Double? = null,
    /** When each fish was caught, in order. */
    val catchTimes: List<Double>? = null,
    /** Hours fished and fish caught in each forecast band, and the mean index; fixed at the end. */
    val bandHours: List<Double>? = null,
    val bandCatches: List<Int>? = null,
    val forecastIndex: Double? = null,
    /** What a later refit of the factor weights needs from this trip. Stays on the device. */
    val fitRecord: TripFitRecord? = null,
    /** When this trip was sent under opt-in sharing (not built on Android yet). */
    val sharedAt: Double? = null,
) {
    val isActive: Boolean get() = endedAt == null
    val hours: Double get() = ((endedAt ?: nowSeconds()) - startedAt) / 3600

    /** One more fish, stamped now. */
    fun withCatch(time: Double = nowSeconds()): Trip {
        // A trip that already has untimed fish stays untimed: half a record would mislead.
        val times = if (catchCount == (catchTimes?.size ?: 0)) (catchTimes ?: emptyList()) + time else catchTimes
        return copy(catchCount = catchCount + 1, catchTimes = times)
    }

    /** Takes back the last fish. */
    fun withoutLastCatch(): Trip {
        if (catchCount <= 0) return this
        val times = catchTimes?.let { if (it.size == catchCount) it.dropLast(1) else it }
        return copy(catchCount = catchCount - 1, catchTimes = times)
    }

    /** The catch times, when every fish of the trip has one. */
    val completeCatchTimes: List<Double>?
        get() = (catchTimes ?: emptyList()).takeIf { it.size == catchCount }

    /** This trip filed under the forecast bands, if it was stored when the trip ended. */
    val scoreRecord: Scorecard.TripRecord?
        get() {
            val h = bandHours ?: return null
            val c = bandCatches ?: return null
            val index = forecastIndex ?: return null
            if (h.size != Scorecard.bandFloors.size || c.size != Scorecard.bandFloors.size) return null
            return Scorecard.TripRecord(h, c, index)
        }
}

/**
 * A finished trip as a model fit needs it: hourly slices with each factor's own score and the
 * fish caught, plus what the scores rested on. No place, name, date or notes.
 */
@Serializable
data class TripFitRecord(
    val v: Int = 1,
    val water: String,
    val species: String,
    val waterTempC: Double? = null,
    val waterSource: String? = null,
    val hasBank: Boolean,
    val hasTideStation: Boolean,
    val slices: List<FactorSlice>,
)

@Serializable
data class StoreData(val spots: List<Spot> = emptyList(), val trips: List<Trip> = emptyList()) {
    fun tripsAt(spot: Spot): List<Trip> = trips.filter { it.spotId == spot.id }

    fun activeTripAt(spot: Spot): Trip? = tripsAt(spot).firstOrNull { it.isActive }

    /** Finished trips that count toward the personal fit. */
    fun fittedTrips(spot: Spot): List<Trip> =
        tripsAt(spot).filter { !it.isActive && it.hours > 0 && it.hours <= CatchModel.maxTripHours }

    /**
     * Your catch rate at this spot relative to the global model. Trips ended
     * before expectations were stored count as neutral-weather trips.
     */
    fun catchMultiplier(spot: Spot): CatchRateMultiplier =
        CatchRateMultiplier.fitted(fittedTrips(spot).map {
            CatchRateMultiplier.Observation(it.catchCount, it.expectedCatch ?: (CatchModel.baselineFishPerHour * it.hours))
        })
}
