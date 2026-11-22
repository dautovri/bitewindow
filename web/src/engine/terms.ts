// Port of Sources/BiteCore/Terms.swift: sub-scores of the bite model, each z in [-1, 1].

import { THERMAL, type Species } from "./species.ts";

/** A time-ordered sea-level pressure series in hPa. */
export class PressureSeries {
  readonly samples: Array<{ time: number; hPa: number }>;

  constructor(samples: Array<{ time: number; hPa: number }>) {
    this.samples = [...samples].sort((a, b) => a.time - b.time);
  }

  /** Linear interpolation; null outside the covered range. */
  value(t: number): number | null {
    const s = this.samples;
    if (s.length === 0 || t < s[0].time || t > s[s.length - 1].time) return null;
    let lo = 0, hi = s.length - 1;
    while (hi - lo > 1) {
      const mid = Math.floor((lo + hi) / 2);
      if (s[mid].time <= t) lo = mid;
      else hi = mid;
    }
    const a = s[lo], b = s[hi];
    const span = b.time - a.time;
    if (!(span > 0)) return a.hPa;
    const f = (t - a.time) / span;
    return a.hPa + (b.hPa - a.hPa) * f;
  }

  /** P(t) - P(t - hours); null when either end is missing. */
  delta(t: number, hours: number): number | null {
    const now = this.value(t);
    const then = this.value(t - hours * 3600);
    return now === null || then === null ? null : now - then;
  }
}

/** Frontal-passage detector; missing history makes the affected component neutral. */
export function pressure(series: PressureSeries, t: number, cloudCover: number): number {
  const d6 = series.delta(t, 6);
  const fall = d6 === null ? 0 : Math.tanh(-d6 / 3);
  const d24 = series.delta(t, 24);
  const post = d24 === null ? 0 : cloudCover < 0.3 ? -Math.tanh(Math.max(0, d24 - 4) / 4) : 0;
  const d48 = series.delta(t, 48);
  const stab = d48 === null ? 0 : Math.exp(-Math.pow(d48 / 3, 2)) - 0.5;
  return 0.5 * fall + 0.35 * post + 0.15 * stab;
}

/** `majors` are lunar upper/lower transits, `minors` are moonrise/moonset. */
export function solunar(t: number, majors: number[], minors: number[], phaseAngle: number): number {
  const kernel = (events: number[], sigmaMinutes: number) => {
    let best: number | null = null;
    for (const e of events) {
      const dm = (t - e) / 60;
      const k = Math.exp(-(dm * dm) / (2 * sigmaMinutes * sigmaMinutes));
      if (best === null || k > best) best = k;
    }
    return best ?? 0;
  };
  const s = Math.max(kernel(majors, 45), 0.6 * kernel(minors, 30));
  const m = 0.75 + 0.25 * Math.abs(Math.cos((phaseAngle * Math.PI) / 180));
  return 2 * s * m - 1;
}

/** Unknown cloud cover (null) makes the cloud component neutral. */
export function light(t: number, sunrise: number | null, sunset: number | null, cloudCover: number | null): number {
  const bump = (e: number | null) => {
    if (e === null) return 0;
    const dm = (t - e) / 60;
    return Math.exp(-Math.pow(dm / 60, 2));
  };
  // Polar day or night: neutral, not the bright-noon penalty for all 24 hours.
  const twilight = sunrise === null && sunset === null ? 0 : 2 * Math.max(bump(sunrise), bump(sunset)) - 1;
  const cloud = cloudCover === null ? 0 : 2 * (1 - Math.pow(1 - Math.max(0, Math.min(1, cloudCover)), 2)) - 1;
  return 0.7 * twilight + 0.3 * cloud;
}

/** Asymmetric thermal performance curve on water temperature (°C). */
export function thermal(waterTempC: number, species: Species): number {
  if (species === "general") return 0;
  const p = THERMAL[species];
  const f = waterTempC <= p.optimum
    ? Math.exp(-Math.pow((waterTempC - p.optimum) / p.sigmaLow, 2))
    : Math.max(0, 1 - Math.pow((waterTempC - p.optimum) / (p.criticalMax - p.optimum), 2));
  return 2 * f - 1;
}

export function wind(speedKmh: number, towardDeg: number | null, bankBearingDeg: number | null): number {
  if (speedKmh > 35) return -1;
  const zU = 2 * Math.exp(-Math.pow((speedKmh - 18) / 12, 2)) - 1;
  let zDir = 0;
  if (towardDeg !== null && bankBearingDeg !== null) zDir = Math.cos(((towardDeg - bankBearingDeg) * Math.PI) / 180);
  return 0.6 * zU + 0.4 * zDir;
}

export function tide(rate: number, maxRateOfDay: number, maxRateOfCycle: number | null = null): number {
  if (!(maxRateOfDay > 0)) return 0;
  const withinDay = 2 * Math.min(1, Math.abs(rate) / maxRateOfDay) - 1;
  if (maxRateOfCycle === null || !(maxRateOfCycle > 0)) return withinDay;
  const dayStrength = 2 * Math.min(1, maxRateOfDay / maxRateOfCycle) - 1;
  return 0.7 * withinDay + 0.3 * dayStrength;
}

/** Spring-neap proxy from the moon phase for salt water without a station. */
export const springTide = (phaseAngle: number): number => Math.cos((2 * phaseAngle * Math.PI) / 180);
