// The TypeScript engine against the Swift engine's own outputs (golden.json, written by
// tools/parity from the real BiteCore package). Regenerate with:
//   cd tools/parity && xcrun --toolchain default swift run -c release parity ../../web/test/golden.json
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as Astro from "../src/engine/astro.ts";
import { bestWindow, curve, geohashEncode, speciesNow, type HourConditions, type SpotContext } from "../src/engine/forecaster.ts";
import { extremes, height, rate, type TideStation } from "../src/engine/tide.ts";
import type { Species, WaterType } from "../src/engine/species.ts";

const golden = JSON.parse(readFileSync(new URL("./golden.json", import.meta.url), "utf8"));

/** Absolute tolerance for values, and for event times in seconds. */
const EPS = 1e-6;
const close = (actual: number, expected: number, eps: number, what: string) =>
  assert.ok(Math.abs(actual - expected) <= eps, `${what}: ${actual} vs ${expected}`);
const closeList = (a: number[], e: number[], eps: number, what: string) => {
  assert.equal(a.length, e.length, `${what}: count`);
  a.forEach((x, i) => close(x, e[i], eps, `${what}[${i}]`));
};

test("sun and moon positions, hour angles and altitudes", () => {
  for (const r of golden.astro) {
    const jd = Astro.julianDay(r.t);
    close(jd, r.jd, 1e-9, "jd");
    const s = Astro.sun(jd), m = Astro.moon(jd);
    closeList([s.ra, s.dec, s.lon, s.parallax], r.sun, EPS, "sun");
    closeList([m.ra, m.dec, m.lon, m.parallax], r.moon, EPS, "moon");
    close(Astro.moonPhaseAngle(r.t), r.phase, EPS, "phase");
    close(Astro.moonIllumination(r.t), r.illum, EPS, "illum");
    close(Astro.hourAngle("sun", r.t, r.lon), r.haSun, EPS, "haSun");
    close(Astro.hourAngle("moon", r.t, r.lon), r.haMoon, EPS, "haMoon");
    close(Astro.altitude("sun", r.t, r.lat, r.lon), r.altSun, EPS, "altSun");
    close(Astro.altitude("moon", r.t, r.lat, r.lon), r.altMoon, EPS, "altMoon");
  }
});

test("rise, set and transit times", () => {
  for (const r of golden.events) {
    const e = Astro.events(r.body, r.from, r.to, r.lat, r.lon);
    const what = `${r.body} ${r.lat},${r.lon} ${r.from}`;
    closeList(e.rises, r.rises, 1e-3, `${what} rises`);
    closeList(e.sets, r.sets, 1e-3, `${what} sets`);
    closeList(e.upperTransits, r.upper, 1e-3, `${what} upper`);
    closeList(e.lowerTransits, r.lower, 1e-3, `${what} lower`);
  }
});

test("tide heights, rates, extremes and curve", () => {
  for (const r of golden.tides) {
    const st: TideStation = r.station;
    closeList(r.times.map((t: number) => height(st, t)), r.heights, EPS, `${st.name} heights`);
    closeList(r.times.map((t: number) => rate(st, t)), r.rates, EPS, `${st.name} rates`);
    const ex = extremes(st, r.from, r.to);
    assert.equal(ex.length, r.extremes.length, `${st.name} extremes count`);
    ex.forEach((x, i) => {
      close(x.time, r.extremes[i][0], 1e-3, `${st.name} extreme time`);
      close(x.height, r.extremes[i][1], EPS, `${st.name} extreme height`);
      assert.equal(x.isHigh ? 1 : 0, r.extremes[i][2]);
    });
  }
});

test("geohash", () => {
  for (const [lat, lon, precision, hash] of golden.geohash) assert.equal(geohashEncode(lat, lon, precision), hash);
});

function caseInputs(c: any): { ctx: SpotContext; hours: HourConditions[] } {
  const ctx: SpotContext = {
    latitude: c.ctx.lat,
    longitude: c.ctx.lon,
    water: c.ctx.water as WaterType,
    species: c.ctx.species as Species,
    bankBearingDeg: c.ctx.bank,
    waterTempC: c.ctx.waterTemp,
    tide: c.ctx.station ?? null,
  };
  const hours: HourConditions[] = c.hours.map((h: any[]) => ({
    time: h[0], pressureHPa: h[1], cloudCover: h[2], windSpeedKmh: h[3], windFromDeg: h[4], airTempC: h[5],
  }));
  return { ctx, hours };
}

const sameWindow = (a: { start: number; end: number; meanIndex: number } | null, e: number[] | null, what: string) => {
  if (e === null) return assert.equal(a, null, what);
  assert.ok(a, what);
  close(a.start, e[0], 1e-6, `${what} start`);
  close(a.end, e[1], 1e-6, `${what} end`);
  close(a.meanIndex, e[2], EPS, `${what} mean`);
};

test("bite curves, best windows and species ranking", () => {
  for (const c of golden.curves) {
    const { ctx, hours } = caseInputs(c);
    const points = curve(ctx, hours, c.from, c.to, { fillMissingWeather: c.fill });
    assert.equal(points.length, c.points.length, `${c.name} point count`);
    points.forEach((p, i) => {
      const e = c.points[i];
      const what = `${c.name}[${i}]`;
      close(p.time, e[0], 1e-6, `${what} time`);
      close(p.index, e[1], EPS, `${what} index`);
      const k = p.contributions;
      closeList([k.light, k.thermal, k.wind, k.pressure, k.solunar, k.tide], e.slice(2, 8), EPS, `${what} terms`);
      assert.equal(p.hasWeather ? 1 : 0, e[8], `${what} hasWeather`);
    });
    sameWindow(bestWindow(points), c.best, `${c.name} best`);
    const firstDay = points.filter((p) => p.time < c.from + 86400);
    sameWindow(bestWindow(firstDay), c.bestFirstDay, `${c.name} bestFirstDay`);
    sameWindow(bestWindow(firstDay, 7200, c.notBefore), c.bestAfter, `${c.name} bestAfter`);
    sameWindow(bestWindow(points, 3 * 3600), c.best3h, `${c.name} best3h`);

    const ranked = speciesNow(ctx, hours, c.speciesNow.now, c.speciesNow.waterTemp);
    assert.equal(ranked.length, c.speciesNow.ranked.length, `${c.name} ranked count`);
    ranked.forEach((r, i) => {
      assert.equal(r.species, c.speciesNow.ranked[i][0], `${c.name} ranked[${i}]`);
      close(r.index, c.speciesNow.ranked[i][1], EPS, `${c.name} ranked[${i}] index`);
    });
  }
});
