package com.dautovri.bitecurve.data

import android.content.Context
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.Json
import java.io.File

/**
 * Spots and trips, on the device only: one JSON file, written whole after every change
 * (a temporary file renamed over the old one, so a crash cannot leave half a file).
 */
class Store(private val file: File) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val state = MutableStateFlow(read())
    val data: StateFlow<StoreData> = state

    private fun read(): StoreData =
        runCatching { json.decodeFromString<StoreData>(file.readText()) }.getOrElse {
            // An unreadable store is kept aside rather than overwritten by an empty one.
            if (file.exists()) {
                Log.e("BiteCurve", "store unreadable, kept as store.bad.json", it)
                file.copyTo(File(file.parentFile, "store.bad.json"), overwrite = true)
            }
            StoreData()
        }

    @Synchronized
    fun update(change: (StoreData) -> StoreData) {
        val next = change(state.value)
        if (next == state.value) return
        val temp = File(file.parentFile, file.name + ".tmp")
        temp.writeText(json.encodeToString(StoreData.serializer(), next))
        if (!temp.renameTo(file)) {
            file.delete()
            temp.renameTo(file)
        }
        state.value = next
    }

    fun addSpot(spot: Spot) = update { it.copy(spots = it.spots + spot) }

    fun updateSpot(id: String, change: (Spot) -> Spot) =
        update { d -> d.copy(spots = d.spots.map { if (it.id == id) change(it) else it }) }

    /** Trips logged at a deleted spot stay in the log, without a spot. */
    fun deleteSpot(id: String) = update { d ->
        d.copy(spots = d.spots.filter { it.id != id }, trips = d.trips.map { if (it.spotId == id) it.copy(spotId = null) else it })
    }

    fun addTrip(trip: Trip) = update { it.copy(trips = it.trips + trip) }

    fun updateTrip(id: String, change: (Trip) -> Trip) =
        update { d -> d.copy(trips = d.trips.map { if (it.id == id) change(it) else it }) }

    fun deleteTrip(id: String) = update { d -> d.copy(trips = d.trips.filter { it.id != id }) }

    companion object {
        fun open(context: Context): Store = Store(File(context.filesDir, "store.json"))
    }
}
