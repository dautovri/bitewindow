// The pilot's page list (data/waters.json, built by tools/build-waters.ts).

import type { Species, WaterType } from "./engine/species.ts";
import list from "../data/waters.json" with { type: "json" };

export interface Water {
  slug: string;
  /** Two-letter US state. */
  state: string;
  name: string;
  kind: "lake" | "coast";
  lat: number;
  lon: number;
  /** Geohash-5 weather cell the backend caches by. */
  gh: string;
  /** IANA time zone for the times on the page. */
  tz: string;
  water: WaterType;
  /** Species scored on the page, in order. */
  species: Species[];
  stationId?: string;
  stationName?: string;
  /** Where the coordinates came from. */
  source: string;
}

export const WATERS = list as Water[];

export const STATE_NAMES: Record<string, string> = {
  TX: "Texas", LA: "Louisiana", MS: "Mississippi", AL: "Alabama", GA: "Georgia", FL: "Florida",
  SC: "South Carolina", NC: "North Carolina", TN: "Tennessee", AR: "Arkansas", OK: "Oklahoma",
  AZ: "Arizona", CA: "California",
};

export const pathOf = (w: Water) => `/bitecurve/fishing/${w.state.toLowerCase()}/${w.slug}/`;

export function findWater(state: string, slug: string): Water | undefined {
  return WATERS.find((w) => w.state.toLowerCase() === state && w.slug === slug);
}

/** The page's position in the refresh schedule (refresh.ts). */
export const indexOf = (w: Water) => WATERS.indexOf(w);
