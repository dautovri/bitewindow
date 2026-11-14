// Water temperature for a spot when the angler has not measured it. Pure helpers, no
// Cloudflare bindings, so they run under `node --test`.
//
// Sea: NOAA OISST (daily satellite + buoy analysis, 0.25°, US government data), near-real-time
// product, read through NOAA CoastWatch ERDDAP.
// Lakes and rivers: no global measurement exists, so the surface temperature is modelled from
// the last 30 days of air temperature (first-order lag, the same form as `Terms.waterTempStep`
// in the engine). Both are estimates and the app labels them so.

import { decodeGeohash } from "./lib.ts";

export type WaterKind = "salt" | "fresh";

export function isWaterKind(s: string | null): s is WaterKind {
  return s === "salt" || s === "fresh";
}

const ERDDAP = "https://coastwatch.pfeg.noaa.gov/erddap/griddap/ncdcOisst21NrtAgg_LonPM180.json";

/** Half-width of the box searched for the nearest sea cell, degrees. */
const SST_REACH = 0.75;

const round = (x: number, step: number) => Math.round(x / step) * step;

/** Latest OISST field in a box around the cell, so a coastal cell finds its nearest sea value. */
export function sstUrl(gh: string): string {
  const { lat, lon } = decodeGeohash(gh);
  // The grid sits on x.125, x.375, ...; keep the box inside the dataset's bounds.
  const clampLat = (v: number) => Math.max(-89.875, Math.min(89.875, v));
  const clampLon = (v: number) => Math.max(-179.875, Math.min(179.875, v));
  const f = (v: number) => (round(v - 0.125, 0.25) + 0.125).toFixed(3);
  const lat0 = f(clampLat(lat - SST_REACH));
  const lat1 = f(clampLat(lat + SST_REACH));
  const lon0 = f(clampLon(lon - SST_REACH));
  const lon1 = f(clampLon(lon + SST_REACH));
  return `${ERDDAP}?sst%5B(last)%5D%5B(0.0)%5D%5B(${lat0}):(${lat1})%5D%5B(${lon0}):(${lon1})%5D`;
}

function km(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const r = Math.PI / 180;
  const a =
    Math.sin(((lat2 - lat1) * r) / 2) ** 2 +
    Math.cos(lat1 * r) * Math.cos(lat2 * r) * Math.sin(((lon2 - lon1) * r) / 2) ** 2;
  return 12742 * Math.asin(Math.sqrt(a));
}

export interface Sst {
  tempC: number;
  /** Distance from the cell centre to the sea cell used. */
  km: number;
  /** Day the analysis is for, ISO. */
  asOf: string;
}

/** Nearest sea cell with a value in an ERDDAP `.json` table; land cells are null. */
export function nearestSst(raw: any, lat: number, lon: number): Sst | null {
  const cols: string[] = raw?.table?.columnNames ?? [];
  const [it, ila, ilo, is] = ["time", "latitude", "longitude", "sst"].map((c) => cols.indexOf(c));
  if (it < 0 || ila < 0 || ilo < 0 || is < 0) return null;
  let best: Sst | null = null;
  for (const row of raw.table.rows ?? []) {
    const t = row[is];
    // Sea water does not get colder than about -2 °C or warmer than about 36 °C.
    if (!Number.isFinite(t) || t < -2.5 || t > 40) continue;
    const d = km(lat, lon, row[ila], row[ilo]);
    if (!best || d < best.km) best = { tempC: Math.round(t * 10) / 10, km: Math.round(d), asOf: String(row[it]) };
  }
  return best;
}

/**
 * Hourly air temperature for the 30 days before `now`, for the lake model. WeatherKit answers
 * at most 240 hours per request (longer ranges are a 400), so the month is three requests.
 */
export function airHistoryUrls(gh: string, now: Date, days = 30): string[] {
  const { lat, lon } = decodeGeohash(gh);
  const hour = Math.floor(now.getTime() / 3_600_000) * 3_600_000;
  const urls: string[] = [];
  for (let back = days; back > 0; back -= 10) {
    const q = new URLSearchParams({
      dataSets: "forecastHourly",
      hourlyStart: new Date(hour - back * 86_400_000).toISOString(),
      hourlyEnd: new Date(hour - Math.max(0, back - 10) * 86_400_000).toISOString(),
    });
    urls.push(`https://weatherkit.apple.com/api/v1/weather/en/${lat.toFixed(4)}/${lon.toFixed(4)}?${q}`);
  }
  return urls;
}

/** The hours of several WeatherKit answers as one, for `dailyAirMeans`. */
export function mergeHours(raws: any[]): any {
  return { forecastHourly: { hours: raws.flatMap((r) => r?.forecastHourly?.hours ?? []) } };
}

/** Mean air temperature of each UTC day, oldest first; days with under 12 hours are left out. */
export function dailyAirMeans(raw: any): number[] {
  const days = new Map<string, { sum: number; n: number }>();
  for (const h of raw?.forecastHourly?.hours ?? []) {
    if (typeof h?.forecastStart !== "string" || !Number.isFinite(h?.temperature)) continue;
    const day = h.forecastStart.slice(0, 10);
    const d = days.get(day) ?? { sum: 0, n: 0 };
    d.sum += h.temperature;
    d.n += 1;
    days.set(day, d);
  }
  return [...days.entries()]
    .sort(([a], [b]) => (a < b ? -1 : 1))
    .filter(([, d]) => d.n >= 12)
    .map(([, d]) => d.sum / d.n);
}

/**
 * Lake surface temperature from daily mean air temperatures (oldest first): the water moves a
 * fraction 1/tau of the way to the air each day. With tau = 8 days the starting guess has
 * faded to 2 % after 30 days. Needs at least two weeks; kept to 1...32 °C (open water does
 * not go below freezing, and the model knows nothing about ice).
 */
export function lakeTemp(dailyAir: number[], tauDays = 8): number | null {
  if (dailyAir.length < 14) return null;
  const head = dailyAir.slice(0, 3);
  let tw = head.reduce((a, b) => a + b, 0) / head.length;
  for (const air of dailyAir) tw += (air - tw) / tauDays;
  return Math.round(Math.max(1, Math.min(32, tw)) * 10) / 10;
}

export interface WaterAnswer {
  gh: string;
  kind: WaterKind;
  /** null: no estimate possible for this cell right now. */
  tempC: number | null;
  /** "sst": satellite sea-surface analysis. "air": modelled from air temperature. */
  source: "sst" | "air" | null;
  asOf: string;
}
