// Port of Sources/BiteCore/Astro.swift. Times are seconds since 1970 (UTC), as in the golden
// file the Swift engine writes (tools/parity). Keep the arithmetic in the Swift order so the
// results match it to rounding: web/test/engine.test.ts checks every function against it.

const deg2rad = Math.PI / 180;
const rad2deg = 180 / Math.PI;

export type Body = "sun" | "moon";

export interface Position {
  /** Right ascension, degrees. */
  ra: number;
  /** Declination, degrees. */
  dec: number;
  /** Ecliptic longitude, degrees. */
  lon: number;
  /** Horizontal parallax, degrees (0 for the sun at this precision). */
  parallax: number;
}

export const julianDay = (t: number): number => t / 86400 + 2440587.5;

export function norm360(x: number): number {
  const r = x % 360;
  return r < 0 ? r + 360 : r;
}

/** Wraps to (-180, 180]. */
export function wrap180(x: number): number {
  const r = norm360(x);
  return r > 180 ? r - 360 : r;
}

const sinD = (d: number) => Math.sin(d * deg2rad);
const cosD = (d: number) => Math.cos(d * deg2rad);

const obliquity = (jd: number) => 23.439 - 0.0000004 * (jd - 2451545.0);

function equatorial(lon: number, lat: number, jd: number, parallax: number): Position {
  const eps = obliquity(jd);
  const l = cosD(lat) * cosD(lon);
  const m = cosD(eps) * cosD(lat) * sinD(lon) - sinD(eps) * sinD(lat);
  const n = sinD(eps) * cosD(lat) * sinD(lon) + cosD(eps) * sinD(lat);
  const ra = norm360(Math.atan2(m, l) * rad2deg);
  const dec = Math.asin(Math.max(-1, Math.min(1, n))) * rad2deg;
  return { ra, dec, lon: norm360(lon), parallax };
}

export function sun(jd: number): Position {
  const n = jd - 2451545.0;
  const L = norm360(280.460 + 0.9856474 * n);
  const g = norm360(357.528 + 0.9856003 * n);
  const lambda = L + 1.915 * sinD(g) + 0.020 * sinD(2 * g);
  return equatorial(lambda, 0, jd, 0);
}

export function moon(jd: number): Position {
  const t = (jd - 2451545.0) / 36525;
  const lambda = 218.32 + 481267.881 * t
    + 6.29 * sinD(135.0 + 477198.87 * t)
    - 1.27 * sinD(259.3 - 413335.36 * t)
    + 0.66 * sinD(235.7 + 890534.22 * t)
    + 0.21 * sinD(269.9 + 954397.74 * t)
    - 0.19 * sinD(357.5 + 35999.05 * t)
    - 0.11 * sinD(186.5 + 966404.03 * t);
  const beta = 5.13 * sinD(93.3 + 483202.02 * t)
    + 0.28 * sinD(228.2 + 960400.89 * t)
    - 0.28 * sinD(318.3 + 6003.15 * t)
    - 0.17 * sinD(217.6 - 407332.21 * t);
  const par = 0.9508
    + 0.0518 * cosD(135.0 + 477198.87 * t)
    + 0.0095 * cosD(259.3 - 413335.36 * t)
    + 0.0078 * cosD(235.7 + 890534.22 * t)
    + 0.0028 * cosD(269.9 + 954397.74 * t);
  return equatorial(lambda, beta, jd, par);
}

export const position = (body: Body, jd: number): Position => (body === "sun" ? sun(jd) : moon(jd));

/** Greenwich mean sidereal time, degrees. */
const gmst = (jd: number) => norm360(280.46061837 + 360.98564736629 * (jd - 2451545.0));

/** Local hour angle in (-180, 180]; 0 at upper transit. */
export function hourAngle(body: Body, t: number, longitude: number): number {
  const jd = julianDay(t);
  return wrap180(gmst(jd) + longitude - position(body, jd).ra);
}

/** Geocentric altitude above the horizon, degrees. */
export function altitude(body: Body, t: number, latitude: number, longitude: number): number {
  const jd = julianDay(t);
  const p = position(body, jd);
  const h = gmst(jd) + longitude - p.ra;
  const s = sinD(latitude) * sinD(p.dec) + cosD(latitude) * cosD(p.dec) * cosD(h);
  return Math.asin(Math.max(-1, Math.min(1, s))) * rad2deg;
}

/** Geocentric altitude at which the upper limb touches the horizon. */
const horizonAltitude = (body: Body, jd: number) => (body === "sun" ? -0.833 : 0.7275 * moon(jd).parallax - 0.5667);

/** Sun–moon elongation in degrees: 0 = new, 180 = full. */
export function moonPhaseAngle(t: number): number {
  const jd = julianDay(t);
  return norm360(moon(jd).lon - sun(jd).lon);
}

/** Illuminated fraction of the lunar disc, 0...1. */
export const moonIllumination = (t: number): number => (1 - cosD(moonPhaseAngle(t))) / 2;

export interface Events {
  rises: number[];
  sets: number[];
  upperTransits: number[];
  lowerTransits: number[];
}

/** Rise, set and transit times in [start, end]: 5-minute scan, each bracket bisected to ~1 s. */
export function events(body: Body, start: number, end: number, latitude: number, longitude: number): Events {
  const out: Events = { rises: [], sets: [], upperTransits: [], lowerTransits: [] };
  const step = 300;
  const horizon = (d: number) => altitude(body, d, latitude, longitude) - horizonAltitude(body, julianDay(d));
  const upper = (d: number) => hourAngle(body, d, longitude);
  const lower = (d: number) => wrap180(upper(d) + 180);

  function bisect(f: (d: number) => number, a: number, b: number): number {
    let lo = a, hi = b;
    let flo = f(lo);
    while (hi - lo > 1) {
      const mid = lo + (hi - lo) / 2;
      const fm = f(mid);
      if ((fm < 0) === (flo < 0)) {
        lo = mid;
        flo = fm;
      } else hi = mid;
    }
    return lo + (hi - lo) / 2;
  }

  let t0 = start;
  let h0 = horizon(t0), u0 = upper(t0), l0 = lower(t0);
  while (t0 < end) {
    const t1 = Math.min(t0 + step, end);
    const h1 = horizon(t1), u1 = upper(t1), l1 = lower(t1);
    if (h0 < 0 && h1 >= 0) out.rises.push(bisect(horizon, t0, t1));
    if (h0 >= 0 && h1 < 0) out.sets.push(bisect(horizon, t0, t1));
    // Hour angle increases through zero at transit; ignore the ±180 wrap.
    if (u0 < 0 && u1 >= 0 && u1 - u0 < 180) out.upperTransits.push(bisect(upper, t0, t1));
    if (l0 < 0 && l1 >= 0 && l1 - l0 < 180) out.lowerTransits.push(bisect(lower, t0, t1));
    t0 = t1; h0 = h1; u0 = u1; l0 = l1;
  }
  return out;
}
