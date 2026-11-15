package com.dautovri.bitecurve.core

// Port of Sources/BiteCore/Profiles.swift.

data class ThermalParameters(val optimum: Double, val sigmaLow: Double, val criticalMax: Double)

enum class WaterType(val raw: String) {
    WARM_FRESHWATER("warmFreshwater"), COLD_FRESHWATER("coldFreshwater"),
    INSHORE_SALT("inshoreSalt"), OFFSHORE("offshore");

    val isSalt: Boolean get() = this == INSHORE_SALT || this == OFFSHORE

    companion object {
        fun fromRaw(raw: String?): WaterType? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * Species thermal parameters are the same heuristic placeholders as in the Swift engine.
 * `raw` is the value stored on each spot and sent in shared trips, identical to the Swift raw
 * values: never rename one, only add. The order is the Swift declaration order.
 */
enum class Species(val raw: String, val displayName: String, val thermal: ThermalParameters, val habitat: Habitat) {
    LARGEMOUTH_BASS("largemouthBass", "Largemouth bass", ThermalParameters(27.0, 8.0, 36.0), Habitat.FRESH),
    WALLEYE("walleye", "Walleye", ThermalParameters(22.0, 7.0, 31.0), Habitat.FRESH),
    NORTHERN_PIKE("northernPike", "Northern pike", ThermalParameters(20.0, 7.0, 29.0), Habitat.FRESH),
    RAINBOW_TROUT("rainbowTrout", "Rainbow trout", ThermalParameters(16.0, 6.0, 25.0), Habitat.FRESH),
    CRUCIAN_CARP("crucianCarp", "Crucian carp", ThermalParameters(24.0, 6.0, 34.0), Habitat.FRESH),
    COMMON_CARP("commonCarp", "Common carp", ThermalParameters(26.0, 6.0, 35.0), Habitat.FRESH),
    EUROPEAN_PERCH("europeanPerch", "Perch", ThermalParameters(19.0, 7.0, 28.0), Habitat.FRESH),
    COMMON_BREAM("commonBream", "Bream", ThermalParameters(21.0, 6.0, 30.0), Habitat.FRESH),

    /** No particular fish: the thermal term stays neutral. The default at sea. */
    GENERAL("general", "Any fish", ThermalParameters(20.0, 10.0, 32.0), Habitat.ANY),
    EUROPEAN_SEA_BASS("europeanSeaBass", "Sea bass", ThermalParameters(18.0, 6.0, 28.0), Habitat.SALT),
    ATLANTIC_COD("atlanticCod", "Cod", ThermalParameters(10.0, 5.0, 18.0), Habitat.SALT),
    ATLANTIC_MACKEREL("atlanticMackerel", "Mackerel", ThermalParameters(14.0, 5.0, 22.0), Habitat.SALT),
    SEA_TROUT("seaTrout", "Sea trout", ThermalParameters(13.0, 6.0, 22.0), Habitat.SALT),
    FLOUNDER("flounder", "Flounder", ThermalParameters(15.0, 6.0, 25.0), Habitat.SALT),
    STRIPED_BASS("stripedBass", "Striped bass", ThermalParameters(18.0, 6.0, 27.0), Habitat.SALT),
    RED_DRUM("redDrum", "Red drum", ThermalParameters(24.0, 7.0, 33.0), Habitat.SALT);

    enum class Habitat { FRESH, SALT, ANY }

    /** Whether the species belongs on a spot with this water. */
    fun livesIn(water: WaterType): Boolean = when (habitat) {
        Habitat.ANY -> true
        Habitat.SALT -> water.isSalt
        Habitat.FRESH -> !water.isSalt
    }

    /** Carp and their kin, for which no lunar effect is documented. */
    val isCyprinid: Boolean get() = this == CRUCIAN_CARP || this == COMMON_CARP || this == COMMON_BREAM

    val defaultWater: WaterType
        get() = when {
            habitat == Habitat.SALT -> WaterType.INSHORE_SALT
            this == RAINBOW_TROUT -> WaterType.COLD_FRESHWATER
            else -> WaterType.WARM_FRESHWATER
        }

    companion object {
        fun fromRaw(raw: String?): Species? = entries.firstOrNull { it.raw == raw }

        /** The fish a spot offers for its water, the general profile first. */
        fun choices(water: WaterType): List<Species> =
            listOf(GENERAL) + entries.filter { it != GENERAL && it.livesIn(water) }

        private val northAmericanRegions = setOf(
            "AG", "AI", "AW", "BB", "BL", "BM", "BQ", "BS", "BZ", "CA", "CR", "CU",
            "CW", "DM", "DO", "GD", "GL", "GP", "GT", "HN", "HT", "JM", "KN", "KY",
            "LC", "MF", "MQ", "MS", "MX", "NI", "PA", "PM", "PR", "SV", "SX", "TC",
            "TT", "US", "VC", "VG", "VI",
        )

        /** The fish a new spot starts with: the general profile at sea, else by region. */
        fun defaultSpecies(regionCode: String?, water: WaterType): Species =
            if (water.isSalt) GENERAL else defaultSpecies(regionCode)

        /** North America defaults to walleye; everywhere else to northern pike. */
        fun defaultSpecies(regionCode: String?): Species {
            val code = regionCode?.uppercase()
            return if (code != null && code in northAmericanRegions) WALLEYE else NORTHERN_PIKE
        }
    }
}

/** Prior factor weights. The ordering is evidence-informed; the numbers are heuristic. */
data class Weights(
    val light: Double, val thermal: Double, val wind: Double,
    val pressure: Double, val solunar: Double, val tide: Double,
) {
    companion object {
        fun prior(water: WaterType, species: Species? = null): Weights = when (water) {
            WaterType.WARM_FRESHWATER -> {
                // Lunar evidence exists for walleye/muskie, not for bass or carp.
                val solunar = if (species == Species.LARGEMOUTH_BASS || species?.isCyprinid == true) 0.05 else 0.10
                Weights(0.25, 0.20, 0.20, 0.15, solunar, 0.0)
            }
            // Trout: solunar tables did not predict catch rate; keep near zero.
            WaterType.COLD_FRESHWATER -> Weights(0.25, 0.25, 0.15, 0.10, 0.02, 0.0)
            WaterType.INSHORE_SALT -> Weights(0.20, 0.15, 0.10, 0.10, 0.05, 0.35)
            WaterType.OFFSHORE -> Weights(0.20, 0.25, 0.10, 0.05, 0.05, 0.10)
        }
    }
}
