// Port of Sources/BiteCore/Tide.swift: harmonic tide prediction from NOAA station constituents.

import { julianDay } from "./astro.ts";

export interface Constituent {
  name: string;
  /** Amplitude H, metres. */
  amplitude: number;
  /** Greenwich phase lag κ, degrees. */
  phase: number;
}

export interface TideStation {
  id: string;
  name: string;
  /** Mean level above chart datum, metres. */
  meanLevel: number;
  constituents: Constituent[];
}

/** Predicted height in metres above chart datum. */
export function height(station: TideStation, t: number): number {
  const jd = julianDay(t);
  const T = (jd - 2451545.0) / 36525;
  const s = 218.3165 + 481267.8813 * T;
  const h = 280.4661 + 36000.7698 * T;
  const p = 83.3535 + 4069.0137 * T;
  const N = ((125.0445 - 1934.1363 * T) * Math.PI) / 180;
  const dayFraction = (jd + 0.5) - Math.floor(jd + 0.5);
  const t15 = 360 * dayFraction;

  let sum = station.meanLevel;
  for (const c of station.constituents) {
    let v: number, f: number, u: number;
    switch (c.name.toUpperCase()) {
      case "M2":
        v = 2 * t15 + 2 * h - 2 * s;
        f = 1.0004 - 0.0373 * Math.cos(N) + 0.0002 * Math.cos(2 * N);
        u = -2.14 * Math.sin(N);
        break;
      case "N2":
        v = 2 * t15 + 2 * h - 3 * s + p;
        f = 1.0004 - 0.0373 * Math.cos(N) + 0.0002 * Math.cos(2 * N);
        u = -2.14 * Math.sin(N);
        break;
      case "S2":
        v = 2 * t15; f = 1; u = 0;
        break;
      case "SA":
        v = h; f = 1; u = 0;
        break;
      case "SSA":
        v = 2 * h; f = 1; u = 0;
        break;
      case "K2":
        v = 2 * t15 + 2 * h;
        f = 1.0241 + 0.2863 * Math.cos(N) + 0.0083 * Math.cos(2 * N) - 0.0015 * Math.cos(3 * N);
        u = -17.74 * Math.sin(N) + 0.68 * Math.sin(2 * N) - 0.04 * Math.sin(3 * N);
        break;
      case "K1":
        v = t15 + h + 90;
        f = 1.0060 + 0.1150 * Math.cos(N) - 0.0088 * Math.cos(2 * N) + 0.0006 * Math.cos(3 * N);
        u = -8.86 * Math.sin(N) + 0.68 * Math.sin(2 * N) - 0.07 * Math.sin(3 * N);
        break;
      case "O1":
        v = t15 + h - 2 * s - 90;
        f = 1.0089 + 0.1871 * Math.cos(N) - 0.0147 * Math.cos(2 * N) + 0.0014 * Math.cos(3 * N);
        u = 10.80 * Math.sin(N) - 1.34 * Math.sin(2 * N) + 0.19 * Math.sin(3 * N);
        break;
      case "Q1":
        v = t15 + h - 3 * s + p - 90;
        f = 1.0089 + 0.1871 * Math.cos(N) - 0.0147 * Math.cos(2 * N) + 0.0014 * Math.cos(3 * N);
        u = 10.80 * Math.sin(N) - 1.34 * Math.sin(2 * N) + 0.19 * Math.sin(3 * N);
        break;
      case "P1":
        v = t15 - h - 90; f = 1; u = 0;
        break;
      default:
        continue;
    }
    sum += f * c.amplitude * Math.cos(((v + u - c.phase) * Math.PI) / 180);
  }
  return sum;
}

/** Rate of change in metres per hour (central difference over 10 minutes). */
export function rate(station: TideStation, t: number): number {
  const dt = 300;
  return (height(station, t + dt) - height(station, t - dt)) / ((2 * dt) / 3600);
}

export interface Extreme {
  time: number;
  height: number;
  isHigh: boolean;
}

/** High and low waters in [from, to]: sign changes of the rate, bisected to under a minute. */
export function extremes(station: TideStation, from: number, to: number, step = 600): Extreme[] {
  if (!(to > from) || !(step > 0)) return [];
  const out: Extreme[] = [];
  let t0 = from, r0 = rate(station, from);
  while (t0 < to) {
    const t1 = Math.min(to, t0 + step);
    const r1 = rate(station, t1);
    if ((r0 > 0 && r1 <= 0) || (r0 < 0 && r1 >= 0)) {
      let lo = t0, hi = t1;
      const rising = r0 > 0;
      while (hi - lo > 30) {
        const mid = lo + (hi - lo) / 2;
        if ((rate(station, mid) > 0) === rising) lo = mid;
        else hi = mid;
      }
      const t = lo + (hi - lo) / 2;
      out.push({ time: t, height: height(station, t), isHigh: rising });
    }
    t0 = t1; r0 = r1;
  }
  return out;
}
