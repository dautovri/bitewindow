// Port of Sources/BiteCore/Profiles.swift (species, water types, prior weights).

export type WaterType = "warmFreshwater" | "coldFreshwater" | "inshoreSalt" | "offshore";

export const isSalt = (w: WaterType) => w === "inshoreSalt" || w === "offshore";

/** In Swift's `Species.allCases` order, which breaks ties in `speciesNow`. */
export const SPECIES = [
  "largemouthBass", "walleye", "northernPike", "rainbowTrout",
  "crucianCarp", "commonCarp", "europeanPerch", "commonBream",
  "general",
  "europeanSeaBass", "atlanticCod", "atlanticMackerel", "seaTrout", "flounder", "stripedBass", "redDrum",
] as const;

export type Species = (typeof SPECIES)[number];

const SALT: ReadonlySet<Species> = new Set<Species>([
  "europeanSeaBass", "atlanticCod", "atlanticMackerel", "seaTrout", "flounder", "stripedBass", "redDrum",
]);

export function lives(species: Species, water: WaterType): boolean {
  if (species === "general") return true;
  return SALT.has(species) ? isSalt(water) : !isSalt(water);
}

export const isCyprinid = (s: Species) => s === "crucianCarp" || s === "commonCarp" || s === "commonBream";

export const DISPLAY_NAME: Record<Species, string> = {
  largemouthBass: "Largemouth bass",
  walleye: "Walleye",
  northernPike: "Northern pike",
  rainbowTrout: "Rainbow trout",
  crucianCarp: "Crucian carp",
  commonCarp: "Common carp",
  europeanPerch: "Perch",
  commonBream: "Bream",
  general: "Any fish",
  europeanSeaBass: "Sea bass",
  atlanticCod: "Cod",
  atlanticMackerel: "Mackerel",
  seaTrout: "Sea trout",
  flounder: "Flounder",
  stripedBass: "Striped bass",
  redDrum: "Red drum",
};

export interface ThermalParameters {
  optimum: number;
  sigmaLow: number;
  criticalMax: number;
}

/** Heuristic placeholders, as in the app (Profiles.swift). */
export const THERMAL: Record<Species, ThermalParameters> = {
  largemouthBass: { optimum: 27, sigmaLow: 8, criticalMax: 36 },
  walleye: { optimum: 22, sigmaLow: 7, criticalMax: 31 },
  northernPike: { optimum: 20, sigmaLow: 7, criticalMax: 29 },
  rainbowTrout: { optimum: 16, sigmaLow: 6, criticalMax: 25 },
  crucianCarp: { optimum: 24, sigmaLow: 6, criticalMax: 34 },
  commonCarp: { optimum: 26, sigmaLow: 6, criticalMax: 35 },
  europeanPerch: { optimum: 19, sigmaLow: 7, criticalMax: 28 },
  commonBream: { optimum: 21, sigmaLow: 6, criticalMax: 30 },
  general: { optimum: 20, sigmaLow: 10, criticalMax: 32 },
  europeanSeaBass: { optimum: 18, sigmaLow: 6, criticalMax: 28 },
  atlanticCod: { optimum: 10, sigmaLow: 5, criticalMax: 18 },
  atlanticMackerel: { optimum: 14, sigmaLow: 5, criticalMax: 22 },
  seaTrout: { optimum: 13, sigmaLow: 6, criticalMax: 22 },
  flounder: { optimum: 15, sigmaLow: 6, criticalMax: 25 },
  stripedBass: { optimum: 18, sigmaLow: 6, criticalMax: 27 },
  redDrum: { optimum: 24, sigmaLow: 7, criticalMax: 33 },
};

export interface Weights {
  light: number;
  thermal: number;
  wind: number;
  pressure: number;
  solunar: number;
  tide: number;
}

export function priorWeights(water: WaterType, species?: Species): Weights {
  switch (water) {
    case "warmFreshwater": {
      // Lunar evidence exists for walleye/muskie, not for bass or carp.
      const solunar = species === "largemouthBass" || (species !== undefined && isCyprinid(species)) ? 0.05 : 0.10;
      return { light: 0.25, thermal: 0.20, wind: 0.20, pressure: 0.15, solunar, tide: 0 };
    }
    case "coldFreshwater":
      return { light: 0.25, thermal: 0.25, wind: 0.15, pressure: 0.10, solunar: 0.02, tide: 0 };
    case "inshoreSalt":
      return { light: 0.20, thermal: 0.15, wind: 0.10, pressure: 0.10, solunar: 0.05, tide: 0.35 };
    case "offshore":
      return { light: 0.20, thermal: 0.25, wind: 0.10, pressure: 0.05, solunar: 0.05, tide: 0.10 };
  }
}
