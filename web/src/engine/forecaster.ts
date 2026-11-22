// Port of Sources/BiteCore/Forecaster.swift (curve, best window, species ranking) and the
// geohash encoder from Support.swift. Times are seconds since 1970.

import { events, moonPhaseAngle, type Events } from "./astro.ts";
import { isSalt, lives, priorWeights, SPECIES, type Species, type WaterType, type Weights } from "./species.ts";
import * as Terms from "./terms.ts";
import { rate, type TideStation } from "./tide.ts";

/** The scoring model the pages show; matches `Forecaster.modelID` in the app. */
export const MODEL_ID = "prior-1";
export const GAIN = 3.0;

/** One hour of weather, in WeatherKit REST units. */
export interface HourConditions {
  time: number;
  pressureHPa: number;
  cloudCover: number;
  windSpeedKmh: number;
  windFromDeg: number | null;
  airTempC: number;
}

export interface SpotContext {
  latitude: number;
  longitude: number;
  water: WaterType;
  species: Species;
  bankBearingDeg?: number | null;
  waterTempC?: number | null;
  tide?: TideStation | null;
}

export interface Contributions {
  light: number;
  thermal: number;
  wind: number;
  pressure: number;
  solunar: number;
  tide: number;
}

export interface ScorePoint {
  time: number;
  /** Bite index, 0...100. 50 = neutral. */
  index: number;
  contributions: Contributions;
  hasWeather: boolean;
}

export interface BiteWindow {
  start: number;
  end: number;
  meanIndex: number;
}

const total = (c: Contributions) => c.light + c.thermal + c.wind + c.pressure + c.solunar + c.tide;

export const indexFor = (c: Contributions): number => 100 / (1 + Math.exp(-GAIN * total(c)));

function interpolate(hours: HourConditions[], t: number): HourConditions | null {
  if (hours.length === 0 || t < hours[0].time || t > hours[hours.length - 1].time) return null;
  const hi = hours.findIndex((h) => h.time >= t);
  if (hi < 0) return null;
  if (hi === 0) return hours[0];
  const a = hours[hi - 1], b = hours[hi];
  const span = b.time - a.time;
  const f = span > 0 ? (t - a.time) / span : 0;
  const mix = (x: number, y: number) => x + (y - x) * f;
  return {
    time: t,
    pressureHPa: mix(a.pressureHPa, b.pressureHPa),
    cloudCover: mix(a.cloudCover, b.cloudCover),
    windSpeedKmh: mix(a.windSpeedKmh, b.windSpeedKmh),
    windFromDeg: f < 0.5 ? a.windFromDeg : b.windFromDeg,
    airTempC: mix(a.airTempC, b.airTempC),
  };
}

function nearest(list: number[], t: number): number | null {
  let best: number | null = null;
  for (const e of list) if (best === null || Math.abs(e - t) < Math.abs(best - t)) best = e;
  return best;
}

export interface CurveOptions {
  step?: number;
  weights?: Weights;
  pressure?: Terms.PressureSeries;
  fillMissingWeather?: boolean;
  /** Sun and moon events for [from - 1 day, to + 1 day], to share between species (not in Swift). */
  astro?: { sun: Events; moon: Events };
}

/** Scores [from, to] every `step` seconds; `hours` should start 48 h before `from`. */
export function curve(context: SpotContext, hoursIn: HourConditions[], from: number, to: number, opts: CurveOptions = {}): ScorePoint[] {
  const step = opts.step ?? 900;
  const fill = opts.fillMissingWeather ?? false;
  const hours = [...hoursIn].sort((a, b) => a.time - b.time);
  const w = opts.weights ?? priorWeights(context.water, context.species);
  const series = opts.pressure ?? new Terms.PressureSeries(hours.map((h) => ({ time: h.time, hPa: h.pressureHPa })));

  const pad = 86400;
  const sunEv = opts.astro?.sun ?? events("sun", from - pad, to + pad, context.latitude, context.longitude);
  const moonEv = opts.astro?.moon ?? events("moon", from - pad, to + pad, context.latitude, context.longitude);
  const majors = [...moonEv.upperTransits, ...moonEv.lowerTransits];
  const minors = [...moonEv.rises, ...moonEv.sets];

  const times: number[] = [];
  for (let t = from; t <= to; t += step) times.push(t);

  const station = context.tide ?? null;
  const tideRates = station ? times.map((t) => rate(station, t)) : null;
  const halfDaySteps = Math.max(1, Math.trunc((12.5 * 3600) / step));
  let cyclePeak: number | null = null;
  if (station) {
    const half = 7.4 * 86400;
    let peak = 0;
    for (let u = from - half; u <= to + half; u += 3600) peak = Math.max(peak, Math.abs(rate(station, u)));
    cyclePeak = peak;
  }
  const salt = isSalt(context.water);
  const waterTemp = context.waterTempC ?? null;
  const bank = context.bankBearingDeg ?? null;

  const out: ScorePoint[] = [];
  times.forEach((time, i) => {
    const weather = interpolate(hours, time);
    if (weather === null && !fill) return;
    const c: Contributions = { light: 0, thermal: 0, wind: 0, pressure: 0, solunar: 0, tide: 0 };
    c.light = w.light * Terms.light(time, nearest(sunEv.rises, time), nearest(sunEv.sets, time), weather ? weather.cloudCover : null);
    if (waterTemp !== null) c.thermal = w.thermal * Terms.thermal(waterTemp, context.species);
    if (weather) {
      c.wind = w.wind * Terms.wind(weather.windSpeedKmh, weather.windFromDeg === null ? null : weather.windFromDeg + 180, bank);
      c.pressure = w.pressure * Terms.pressure(series, time, weather.cloudCover);
    }
    c.solunar = w.solunar * Terms.solunar(time, majors, minors, moonPhaseAngle(time));
    if (tideRates && w.tide > 0) {
      const lo = Math.max(0, i - halfDaySteps), hi = Math.min(tideRates.length - 1, i + halfDaySteps);
      let peak = 0;
      for (let k = lo; k <= hi; k++) peak = Math.max(peak, Math.abs(tideRates[k]));
      c.tide = w.tide * Terms.tide(tideRates[i], peak, cyclePeak);
    } else if (salt && w.tide > 0) {
      c.tide = w.tide * 0.5 * Terms.springTide(moonPhaseAngle(time));
    }
    out.push({ time, index: indexFor(c), contributions: c, hasWeather: weather !== null });
  });
  return out;
}

/** Highest-mean contiguous window of the given length, starting at or after `notBefore`. */
export function bestWindow(pointsIn: ScorePoint[], length = 7200, notBefore: number | null = null): BiteWindow | null {
  const points = notBefore === null ? pointsIn : pointsIn.filter((p) => p.time >= notBefore);
  if (points.length < 2) return null;
  let best: BiteWindow | null = null;
  let j = 0;
  let sum = 0;
  for (let i = 0; i < points.length; i++) {
    sum += points[i].index;
    while (points[i].time - points[j].time > length) {
      sum -= points[j].index;
      j += 1;
    }
    const covered = points[i].time - points[j].time;
    if (covered < length * 0.9) continue;
    const mean = sum / (i - j + 1);
    if (best === null || mean > best.meanIndex) best = { start: points[j].time, end: points[i].time, meanIndex: mean };
  }
  return best;
}

export interface SpeciesOutlook {
  species: Species;
  index: number;
}

/** Species living in the spot's water scored at `now`, best thermal fit first. */
export function speciesNow(context: SpotContext, hours: HourConditions[], now: number, waterTempC: number | null): SpeciesOutlook[] {
  if (waterTempC === null) return [];
  const base: SpotContext = { ...context, waterTempC: null };
  const point = curve(base, hours, now, now, { fillMissingWeather: true })[0];
  if (!point) return [];
  const c = point.contributions;
  const baseSolunarWeight = priorWeights(context.water, context.species).solunar;
  const solunarZ = baseSolunarWeight > 0 ? c.solunar / baseSolunarWeight : 0;
  const scored: Array<{ outlook: SpeciesOutlook; fit: number }> = [];
  for (const species of SPECIES) {
    if (species === "general" || !lives(species, context.water)) continue;
    const w = priorWeights(context.water, species);
    const fit = Terms.thermal(waterTempC, species);
    const sc: Contributions = { ...c, thermal: w.thermal * fit, solunar: w.solunar * solunarZ };
    scored.push({ outlook: { species, index: indexFor(sc) }, fit });
  }
  scored.sort((a, b) => (a.fit !== b.fit ? b.fit - a.fit : b.outlook.index - a.outlook.index));
  return scored.map((s) => s.outlook);
}

const ALPHABET = "0123456789bcdefghjkmnpqrstuvwxyz";

export function geohashEncode(latitude: number, longitude: number, precision = 5): string {
  let lat: [number, number] = [-90, 90];
  let lon: [number, number] = [-180, 180];
  let hash = "", bit = 0, ch = 0, even = true;
  while (hash.length < precision) {
    const r = even ? lon : lat;
    const v = even ? longitude : latitude;
    const mid = (r[0] + r[1]) / 2;
    if (v >= mid) {
      ch = (ch << 1) | 1;
      r[0] = mid;
    } else {
      ch = ch << 1;
      r[1] = mid;
    }
    even = !even;
    bit += 1;
    if (bit === 5) {
      hash += ALPHABET[ch];
      bit = 0;
      ch = 0;
    }
  }
  return hash;
}
