// One page's forecast, worked out by the cron (refresh.ts) and stored in KV. Only results are
// kept: bite windows, sun and moon times, tide highs and lows, and a day summary of the
// forecast. The raw hourly weather is not stored here (WeatherKit terms §1.5, §1.6).
//
// Shows what the app gives for free (today's and tomorrow's best window and index). The hourly
// curve, the 10-day outlook and the tide curve are BiteCurve Pro and stay in the app.

import { events, moonIllumination, moonPhaseAngle } from "./engine/astro.ts";
import { bestWindow, curve, MODEL_ID, type HourConditions, type ScorePoint } from "./engine/forecaster.ts";
import type { Species } from "./engine/species.ts";
import { PressureSeries } from "./engine/terms.ts";
import { extremes, type TideStation } from "./engine/tide.ts";
import type { Water } from "./waters.ts";

export interface WindowOut {
  start: number;
  end: number;
  /** Mean bite index over the window, 0...100. */
  index: number;
}

export interface WeatherDay {
  minC: number;
  maxC: number;
  maxWindKmh: number;
  /** Change of sea-level pressure over the day, hPa. */
  pressureChange: number;
}

export interface DayOut {
  /** Local calendar date, YYYY-MM-DD. */
  date: string;
  start: number;
  end: number;
  /** Up to three non-overlapping two-hour windows, best first. Today's page shows the best one
   *  that has not ended yet. Three windows a day, not the hourly curve (which is Pro). */
  species: Array<{ species: Species; windows: WindowOut[] }>;
  sunrise: number | null;
  sunset: number | null;
  moonrise: number | null;
  moonset: number | null;
  /** Solunar major periods (moon overhead and underfoot) and minor periods (moonrise, moonset). */
  majors: number[];
  minors: number[];
  /** Phase angle at local noon: 0 new, 180 full. */
  moonPhase: number;
  moonIllumination: number;
  weather: WeatherDay | null;
  tides: Array<{ time: number; heightM: number; isHigh: boolean }> | null;
}

export interface PageData {
  v: 1;
  path: string;
  model: string;
  generatedAt: number;
  /** When WeatherKit produced the forecast the windows were scored with; null without weather. */
  weatherFetchedAt: number | null;
  waterTemp: { c: number; source: "air" | "sst" } | null;
  station: { id: string; name: string } | null;
  days: DayOut[];
}

/** The backend's slim forecast (backend/src/lib.ts `SlimForecast`). */
export interface SlimForecast {
  gh: string;
  fetchedAt: string;
  hours: Array<{ t: string; p: number; c: number; ws: number; wd: number | null; ta: number }>;
}

// MARK: Time zones

const partsFormat = new Map<string, Intl.DateTimeFormat>();
function zoneParts(tz: string, t: number) {
  let f = partsFormat.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit",
    });
    partsFormat.set(tz, f);
  }
  const out: Record<string, number> = {};
  for (const p of f.formatToParts(new Date(t * 1000))) if (p.type !== "literal") out[p.type] = Number(p.value);
  return out as { year: number; month: number; day: number; hour: number; minute: number; second: number };
}

/** Seconds the zone is ahead of UTC at instant t. */
export function zoneOffset(tz: string, t: number): number {
  const p = zoneParts(tz, t);
  return Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) / 1000 - Math.floor(t);
}

export function localDate(tz: string, t: number): string {
  const p = zoneParts(tz, t);
  return `${p.year}-${String(p.month).padStart(2, "0")}-${String(p.day).padStart(2, "0")}`;
}

/** The instant the local day containing t began (DST days included). */
export function startOfLocalDay(tz: string, t: number): number {
  const [y, m, d] = localDate(tz, t).split("-").map(Number);
  const midnightUtc = Date.UTC(y, m - 1, d) / 1000;
  let guess = midnightUtc - zoneOffset(tz, midnightUtc);
  guess = midnightUtc - zoneOffset(tz, guess);
  return guess;
}

const nextDayStart = (tz: string, dayStart: number) => startOfLocalDay(tz, dayStart + 30 * 3600);

// MARK: Page

export function toHours(f: SlimForecast | null): HourConditions[] {
  if (!f) return [];
  return f.hours
    .map((h) => ({
      time: Date.parse(h.t) / 1000, pressureHPa: h.p, cloudCover: h.c, windSpeedKmh: h.ws, windFromDeg: h.wd, airTempC: h.ta,
    }))
    .filter((h) => Number.isFinite(h.time))
    .sort((a, b) => a.time - b.time);
}

function weatherDay(hours: HourConditions[], start: number, end: number): WeatherDay | null {
  const inDay = hours.filter((h) => h.time >= start && h.time < end);
  // A day summary needs most of the day; otherwise none is shown.
  if (inDay.length < 18) return null;
  const series = new PressureSeries(hours.map((h) => ({ time: h.time, hPa: h.pressureHPa })));
  const p0 = series.value(start), p1 = series.value(end - 3600);
  return {
    minC: Math.min(...inDay.map((h) => h.airTempC)),
    maxC: Math.max(...inDay.map((h) => h.airTempC)),
    maxWindKmh: Math.max(...inDay.map((h) => h.windSpeedKmh)),
    pressureChange: p0 === null || p1 === null ? 0 : p1 - p0,
  };
}

/** The best `count` two-hour windows that do not overlap, best first. */
export function topWindows(points: ScorePoint[], count = 3, step = 900): WindowOut[] {
  let rest = points;
  const out: WindowOut[] = [];
  while (out.length < count) {
    // Search each unbroken run of points, so no window spans a gap left by an earlier pick.
    const runs: ScorePoint[][] = [];
    for (const p of rest) {
      const run = runs[runs.length - 1];
      if (run && p.time - run[run.length - 1].time <= step) run.push(p);
      else runs.push([p]);
    }
    let best: WindowOut | null = null;
    for (const run of runs) {
      const w = bestWindow(run);
      if (w && (best === null || w.meanIndex > best.index)) best = { start: w.start, end: w.end, index: w.meanIndex };
    }
    if (!best) break;
    out.push(best);
    const b = best;
    rest = rest.filter((p) => p.time < b.start || p.time > b.end);
  }
  return out;
}

const within = (list: number[], start: number, end: number) => list.filter((t) => t >= start && t < end).sort((a, b) => a - b);
const firstWithin = (list: number[], start: number, end: number) => within(list, start, end)[0] ?? null;

export interface Inputs {
  forecast: SlimForecast | null;
  waterTemp: { c: number; source: "air" | "sst" } | null;
  station: TideStation | null;
}

/** Today and tomorrow at the water, in its own time zone. */
export function computePage(water: Water, path: string, input: Inputs, now: number, days = 2): PageData {
  const hours = toHours(input.forecast);
  const starts: number[] = [startOfLocalDay(water.tz, now)];
  for (let i = 1; i <= days; i++) starts.push(nextDayStart(water.tz, starts[i - 1]));
  const from = starts[0], to = starts[days] - 900;
  const pad = 86400;
  const sun = events("sun", from - pad, to + pad, water.lat, water.lon);
  const moon = events("moon", from - pad, to + pad, water.lat, water.lon);
  const series = new PressureSeries(hours.map((h) => ({ time: h.time, hPa: h.pressureHPa })));

  const curves = water.species.map((species) => ({
    species,
    points: curve(
      { latitude: water.lat, longitude: water.lon, water: water.water, species, waterTempC: input.waterTemp?.c ?? null, tide: input.station },
      hours, from, to, { fillMissingWeather: true, astro: { sun, moon }, pressure: series },
    ),
  }));

  const out: DayOut[] = [];
  for (let i = 0; i < days; i++) {
    const start = starts[i], end = starts[i + 1];
    const noon = start + (end - start) / 2;
    out.push({
      date: localDate(water.tz, start + 3600),
      start,
      end,
      species: curves.map(({ species, points }) => ({
        species,
        windows: topWindows(points.filter((p) => p.time >= start && p.time < end)),
      })),
      sunrise: firstWithin(sun.rises, start, end),
      sunset: firstWithin(sun.sets, start, end),
      moonrise: firstWithin(moon.rises, start, end),
      moonset: firstWithin(moon.sets, start, end),
      majors: within([...moon.upperTransits, ...moon.lowerTransits], start, end),
      minors: within([...moon.rises, ...moon.sets], start, end),
      moonPhase: moonPhaseAngle(noon),
      moonIllumination: moonIllumination(noon),
      weather: weatherDay(hours, start, end),
      tides: input.station
        ? extremes(input.station, start, end).map((x) => ({ time: x.time, heightM: x.height, isHigh: x.isHigh }))
        : null,
    });
  }
  const fetched = input.forecast ? Date.parse(input.forecast.fetchedAt) / 1000 : NaN;
  return {
    v: 1,
    path,
    model: MODEL_ID,
    generatedAt: now,
    weatherFetchedAt: Number.isFinite(fetched) && hours.length > 0 ? fetched : null,
    waterTemp: input.waterTemp,
    station: input.station ? { id: input.station.id, name: input.station.name } : null,
    days: out,
  };
}
