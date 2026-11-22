// Builds web/data/waters.json from web/data/sources.json. Run by hand when the list changes:
//   node tools/build-waters.ts
// Lakes: OpenStreetMap Nominatim (1 request a second, per its usage policy). Coasts: NOAA
// CO-OPS station metadata, and the harmonic constants are checked so every coastal page has
// a tide station the engine can use. Nothing here runs in the worker.

import { readFileSync, writeFileSync } from "node:fs";
import { geohashEncode } from "../src/engine/forecaster.ts";
import type { Water } from "../src/waters.ts";

const UA = { "user-agent": "bitecurve-forecast-pages-builder/1.0" };
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const STATES: Record<string, string> = {
  TX: "Texas", LA: "Louisiana", MS: "Mississippi", AL: "Alabama", GA: "Georgia", FL: "Florida",
  SC: "South Carolina", NC: "North Carolina", TN: "Tennessee", AR: "Arkansas", OK: "Oklahoma",
  AZ: "Arizona", CA: "California",
};

/** Lakes on the Eastern side of Tennessee's time-zone line; the rest of the state is Central. */
const EAST_TN = new Set(["Chickamauga Lake", "Watts Bar Lake", "Douglas Lake"]);

function lakeZone(state: string, name: string): string {
  if (state === "TN") return EAST_TN.has(name) ? "America/New_York" : "America/Chicago";
  if (["GA", "SC", "NC", "FL"].includes(state)) return "America/New_York";
  if (state === "AZ") return "America/Phoenix";
  if (state === "CA") return "America/Los_Angeles";
  return "America/Chicago";
}

const NOAA_ZONES: Record<string, string> = {
  EST: "America/New_York", CST: "America/Chicago", PST: "America/Los_Angeles",
};

export const slugify = (s: string) =>
  s.toLowerCase().replace(/['’.]/g, "").replace(/&/g, " and ").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");

/** Fishing species shown per page: the region's main target, then "Any fish". */
function lakeSpecies(): Water["species"] {
  return ["largemouthBass", "general"];
}
function coastSpecies(state: string): Water["species"] {
  return state === "CA" ? ["general"] : ["redDrum", "general"];
}

async function lake(name: string, query: string, state: string): Promise<Water | null> {
  const q = new URLSearchParams({ q: `${query}, ${STATES[state]}, USA`, format: "jsonv2", limit: "5", countrycodes: "us", addressdetails: "1" });
  const res = await fetch(`https://nominatim.openstreetmap.org/search?${q}`, { headers: UA });
  if (!res.ok) throw new Error(`nominatim ${res.status} for ${name}`);
  const hits = (await res.json()) as any[];
  const water = hits.find((h) => ["water", "reservoir", "lake", "oxbow"].includes(h.type) || h.category === "water" || h.category === "natural");
  if (!water) {
    console.warn(`!! no water body for ${name} (${state}); hits: ${hits.map((h) => `${h.category}/${h.type} ${h.display_name}`).join(" | ")}`);
    return null;
  }
  const lat = Number(Number(water.lat).toFixed(4));
  const lon = Number(Number(water.lon).toFixed(4));
  const st = water.address?.state;
  if (st && st !== STATES[state]) console.warn(`?? ${name}: OSM puts it in ${st}, listed under ${state}`);
  return {
    slug: slugify(name), state, name, kind: "lake", lat, lon, gh: geohashEncode(lat, lon, 5),
    tz: lakeZone(state, name), water: "warmFreshwater", species: lakeSpecies(),
    source: `OpenStreetMap: ${water.display_name}`,
  };
}

async function coast(name: string, id: string): Promise<Water | null> {
  const base = "https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations";
  const [meta, harcon] = await Promise.all([
    fetch(`${base}/${id}.json`, { headers: UA }).then((r) => r.json() as Promise<any>),
    fetch(`${base}/${id}/harcon.json?units=metric`, { headers: UA }).then((r) => r.json() as Promise<any>),
  ]);
  const st = meta?.stations?.[0];
  const names = new Set((harcon?.HarmonicConstituents ?? []).filter((c: any) => Number(c.amplitude) > 0).map((c: any) => String(c.name).toUpperCase()));
  if (!st || !names.has("M2")) {
    console.warn(`!! ${name} (${id}): no station metadata or no M2 constituent`);
    return null;
  }
  const tz = NOAA_ZONES[String(st.timezone).toUpperCase()];
  if (!tz) {
    console.warn(`!! ${name} (${id}): unknown NOAA time zone ${st.timezone}`);
    return null;
  }
  const lat = Number(Number(st.lat).toFixed(4));
  const lon = Number(Number(st.lng).toFixed(4));
  return {
    slug: slugify(name), state: st.state, name, kind: "coast", lat, lon, gh: geohashEncode(lat, lon, 5),
    tz, water: "inshoreSalt", species: coastSpecies(st.state), stationId: id, stationName: st.name,
    source: `NOAA CO-OPS station ${id} (${st.name})`,
  };
}

const sources = JSON.parse(readFileSync(new URL("../data/sources.json", import.meta.url), "utf8"));
const out: Water[] = [];
for (const [name, query, state] of sources.lakes as [string, string, string][]) {
  const w = await lake(name, query, state);
  if (w) out.push(w);
  await sleep(1100);
}
for (const [name, id] of sources.coasts as [string, string][]) {
  const w = await coast(name, id);
  if (w) out.push(w);
  await sleep(300);
}

const seen = new Map<string, string>();
for (const w of out) {
  const path = `${w.state.toLowerCase()}/${w.slug}`;
  if (seen.has(path)) throw new Error(`duplicate page ${path}`);
  seen.set(path, w.name);
}
const cells = new Map<string, string[]>();
for (const w of out) cells.set(w.gh, [...(cells.get(w.gh) ?? []), w.name]);
for (const [gh, names] of cells) if (names.length > 1) console.warn(`== same weather cell ${gh}: ${names.join(", ")}`);

out.sort((a, b) => a.state.localeCompare(b.state) || a.name.localeCompare(b.name));
writeFileSync(new URL("../data/waters.json", import.meta.url), JSON.stringify(out, null, 1) + "\n");
console.log(`wrote ${out.length} waters (${out.filter((w) => w.kind === "lake").length} lakes, ${out.filter((w) => w.kind === "coast").length} coasts)`);
