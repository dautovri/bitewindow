// Pages, routes and the refresh cron against a fake backend and an in-memory KV, including
// the failure drills: backend down, budget spent, no tide station, old data.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { computePage, localDate, startOfLocalDay, zoneOffset } from "../src/compute.ts";
import { handle, type Env } from "../src/index.ts";
import { pageKey, pick, refresh, refreshOne, type Backend, type WebAnswer } from "../src/refresh.ts";
import { biteLabel, moonPhaseName, renderWater } from "../src/render.ts";
import { pathOf, WATERS } from "../src/waters.ts";

const golden = JSON.parse(readFileSync(new URL("./golden.json", import.meta.url), "utf8"));
const BOSTON = golden.tides[0].station;

const NOW = Date.parse("2026-11-22T15:00:00Z") / 1000;
const lake = WATERS.find((w) => w.name === "Lake Fork")!;
const coast = WATERS.find((w) => w.name === "Galveston Jetties")!;

function forecast(now = NOW, fetchedAt = now) {
  const hours = [];
  const h0 = Math.floor(now / 3600) * 3600;
  for (let i = -48; i < 240; i++) {
    const t = h0 + i * 3600;
    hours.push({ t: new Date(t * 1000).toISOString(), p: 1013 + 6 * Math.sin(i / 11), c: 0.5 + 0.4 * Math.sin(i / 7), ws: 10 + 8 * Math.sin(i / 5), wd: 200, ta: 14 + 6 * Math.sin((i - 9) / 4) });
  }
  return { gh: "x", fetchedAt: new Date(fetchedAt * 1000).toISOString(), hours };
}

function memoryKV() {
  const store = new Map<string, string>();
  const ttl = new Map<string, number | undefined>();
  return {
    store,
    ttl,
    get: async (k: string) => store.get(k) ?? null,
    put: async (k: string, v: string, o?: { expirationTtl?: number }) => {
      store.set(k, v);
      ttl.set(k, o?.expirationTtl);
    },
  };
}

type Mode = "ok" | "down" | "budget" | "throws";
function fakeBackend(mode: Mode = "ok", calls: string[] = []): Backend {
  const ok = (data: unknown): WebAnswer => ({ status: 200, cache: "hit", data });
  const fail = (): WebAnswer =>
    mode === "budget" ? { status: 503, cache: null, data: { error: "budget" } } : { status: 502, cache: null, data: { error: "upstream" } };
  const run = async (name: string, value: () => WebAnswer) => {
    calls.push(name);
    if (mode === "throws") throw new Error("binding down");
    return mode === "ok" ? value() : fail();
  };
  return {
    forecast: (gh) => run(`forecast:${gh}`, () => ok(forecast())),
    water: (gh, kind) => run(`water:${gh}:${kind}`, () => ok({ gh, kind, tempC: 17.4, source: kind === "salt" ? "sst" : "air", asOf: "x" })),
    tide: (gh) => run(`tide:${gh}`, () => ok({ gh, station: BOSTON, km: 1, status: "ok" })),
  };
}

const env = (kv: ReturnType<typeof memoryKV>, backend = fakeBackend()): Env => ({ BACKEND: backend, PAGES: kv });
const get = (path: string, e: Env, now = NOW) => handle(new Request(`https://apps.dautov.dev${path}`), e, now);

test("time zones: local midnight, DST and dates", () => {
  // Chicago in November is UTC-6; the day starts at 06:00 UTC.
  assert.equal(zoneOffset("America/Chicago", NOW), -6 * 3600);
  assert.equal(new Date(startOfLocalDay("America/Chicago", NOW) * 1000).toISOString(), "2026-11-22T06:00:00.000Z");
  assert.equal(localDate("America/Phoenix", Date.parse("2026-11-23T06:30:00Z") / 1000), "2026-11-22");
  // The DST change day (2026-03-08) is 23 hours long in New York.
  const d = startOfLocalDay("America/New_York", Date.parse("2026-03-08T15:00:00Z") / 1000);
  const next = startOfLocalDay("America/New_York", d + 30 * 3600);
  assert.equal(new Date(d * 1000).toISOString(), "2026-03-08T05:00:00.000Z");
  assert.equal(next - d, 23 * 3600);
});

test("page data: two local days, windows per species, tides only on the coast, no raw hours", () => {
  const p = computePage(coast, pathOf(coast), { forecast: forecast(), waterTemp: { c: 18, source: "sst" }, station: BOSTON }, NOW);
  assert.equal(p.days.length, 2);
  assert.equal(p.days[0].date, "2026-11-22");
  for (const d of p.days) {
    assert.equal(d.species.length, coast.species.length);
    for (const s of d.species) {
      assert.ok(s.windows.length >= 1 && s.windows.length <= 3);
      for (const w of s.windows) {
        assert.ok(w.start >= d.start && w.end < d.end);
        assert.ok(w.index > 0 && w.index < 100);
      }
      // Best first, and no two windows overlap.
      for (let i = 1; i < s.windows.length; i++) assert.ok(s.windows[i].index <= s.windows[i - 1].index);
      const sorted = [...s.windows].sort((a, b) => a.start - b.start);
      for (let i = 1; i < sorted.length; i++) assert.ok(sorted[i].start > sorted[i - 1].end);
    }
    assert.ok(d.tides && d.tides.length >= 2);
    assert.ok(d.weather);
  }
  assert.ok(!("hours" in p));
  assert.ok(!JSON.stringify(p).includes('"hours"'));
  const l = computePage(lake, pathOf(lake), { forecast: forecast(), waterTemp: null, station: null }, NOW);
  assert.equal(l.days[0].tides, null);
  assert.equal(l.station, null);
});

test("render: fresh page has windows, conditions, attribution, notices and the app link; no Pro features", () => {
  const p = computePage(coast, pathOf(coast), { forecast: forecast(), waterTemp: { c: 18, source: "sst" }, station: BOSTON }, NOW);
  const html = renderWater(coast, p, NOW + 600);
  assert.match(html, /<h1>Galveston Jetties fishing forecast<\/h1>/);
  assert.match(html, /Today, Sunday, Nov 22/);
  assert.match(html, /Tomorrow, Monday, Nov 23/);
  assert.match(html, /Red drum<\/strong>: (best window|best window left|the good windows are over)/);
  assert.match(html, /Tides<\/th><td>(High|Low) /);
  assert.match(html, /Apple_Weather_blk_en_2X/);
  assert.match(html, /developer\.apple\.com\/weatherkit\/data-source-attribution/);
  assert.match(html, /WEATHER DATA MAY NOT BE ACCURATE/);
  assert.match(html, /modified, not Apple&#39;s own forecast|modified, not Apple's own forecast/);
  assert.match(html, /NOAA station 8443970/);
  assert.match(html, /apps\.apple\.com\/app\/id6834430484\?pt=127464313&amp;ct=web-bitecurve&amp;mt=8/);
  assert.match(html, /<meta name="apple-itunes-app" content="app-id=6834430484/);
  assert.match(html, /\/consent\.js/);
  assert.match(html, /Impressum/);
  assert.doesNotMatch(html, /noindex/);
  assert.doesNotMatch(html, /10-day forecast|hourly forecast table/i);
  // Two days only: the third day is not shown.
  assert.doesNotMatch(html, /Tuesday, Nov 24/);
});

test("render: yesterday's stored day is dropped, an old forecast says so", () => {
  const p = computePage(lake, pathOf(lake), { forecast: forecast(), waterTemp: { c: 12, source: "air" }, station: null }, NOW);
  const nextDay = NOW + 20 * 3600;
  const html = renderWater(lake, p, nextDay);
  assert.doesNotMatch(html, /Sunday, Nov 22/);
  assert.match(html, /Today, Monday, Nov 23/);
  assert.match(html, /older than usual/);
  // Both days gone: the honest "being updated" note, and not indexable.
  const later = renderWater(lake, p, NOW + 3 * 86400);
  assert.match(later, /being updated/);
  assert.match(later, /noindex/);
});

test("render: today shows the best window still ahead, and says when the day's best is over", () => {
  const p = computePage(lake, pathOf(lake), { forecast: forecast(), waterTemp: { c: 12, source: "air" }, station: null }, NOW);
  const today = p.days[0];
  const s = today.species[0];
  const [best, second] = s.windows;
  assert.ok(best && second);
  // Before the best window: it is shown as the best window.
  const before = renderWater(lake, p, Math.min(best.start, second.start) - 3600);
  assert.match(before, /best window /);
  // Just after the best window ended (and before the next one ends): the next one, and a note.
  const after = renderWater(lake, { ...p, days: [{ ...today, species: [{ species: s.species, windows: [best, { ...second, start: best.end + 3600, end: best.end + 3 * 3600 }] }] }] }, best.end + 60);
  assert.match(after, /best window left/);
  assert.match(after, /the day&#39;s best|the day's best/);
  // After every window: says so.
  const late = renderWater(lake, { ...p, days: [{ ...today, species: [{ species: s.species, windows: [best] }] }] }, best.end + 60);
  assert.match(late, /over for the day/);
});

test("labels follow the app's bite scale and moon phases", () => {
  assert.equal(biteLabel(64.6).label, "Strong bite");
  assert.equal(biteLabel(64.4).label, "Above average");
  assert.equal(biteLabel(49.6).label, "Above average");
  assert.equal(biteLabel(35).label, "Below average");
  assert.equal(biteLabel(20).label, "Slow");
  assert.equal(moonPhaseName(0), "New moon");
  assert.equal(moonPhaseName(180), "Full moon");
  assert.equal(moonPhaseName(95), "First quarter");
  assert.equal(moonPhaseName(350), "New moon");
});

test("refresh: one page per run, never-refreshed first, then the oldest; stores results with a TTL", async () => {
  const kv = memoryKV();
  const calls: string[] = [];
  await refresh(fakeBackend("ok", calls), kv, NOW, 2);
  const status = JSON.parse(kv.store.get("status")!);
  const done = Object.keys(status);
  assert.deepEqual(done, [pathOf(WATERS[0]), pathOf(WATERS[1])]);
  assert.ok(kv.store.has(pageKey(pathOf(WATERS[0]))));
  assert.equal(kv.ttl.get(pageKey(pathOf(WATERS[0]))), 3 * 86400);
  // Coast pages ask for the tide, lakes do not.
  const tideCalls = calls.filter((c) => c.startsWith("tide:")).length;
  assert.equal(tideCalls, [WATERS[0], WATERS[1]].filter((w) => w.kind === "coast").length);
  // Next run takes the next pages, not the same ones.
  const next = pick(status, 2);
  assert.deepEqual(next.map(pathOf), [pathOf(WATERS[2]), pathOf(WATERS[3])]);
});

test("failure drills: backend down, budget spent or binding broken keep the last good page", async () => {
  const kv = memoryKV();
  assert.equal(await refreshOne(lake, fakeBackend("ok"), kv, NOW), "ok");
  const good = kv.store.get(pageKey(pathOf(lake)));
  for (const mode of ["down", "budget"] as const) assert.equal(await refreshOne(lake, fakeBackend(mode), kv, NOW + 3600), "no-weather");
  assert.equal(await refreshOne(lake, fakeBackend("throws"), kv, NOW + 7200), "failed");
  assert.equal(kv.store.get(pageKey(pathOf(lake))), good, "the last good page stays");

  // A failed page goes to the back of the queue, so it cannot block the others.
  const kv2 = memoryKV();
  await refresh(fakeBackend("down"), kv2, NOW, 1);
  const status = JSON.parse(kv2.store.get("status")!);
  assert.equal(status[pathOf(WATERS[0])].ok, 0);
  assert.equal(pick(status, 1)[0], WATERS[1]);
  assert.ok(!kv2.store.has(pageKey(pathOf(WATERS[0]))));
});

test("failure drill: no water temperature and no tide station still give a page", async () => {
  const kv = memoryKV();
  const b = fakeBackend("ok");
  const partial: Backend = {
    ...b,
    water: async () => ({ status: 503, cache: null, data: { error: "budget" } }),
    tide: async () => ({ status: 200, cache: "hit", data: { gh: "x", station: null, km: null, status: "none_in_range" } }),
  };
  assert.equal(await refreshOne(coast, partial, kv, NOW), "ok");
  const page = JSON.parse(kv.store.get(pageKey(pathOf(coast)))!);
  assert.equal(page.waterTemp, null);
  assert.equal(page.station, null);
  const html = renderWater(coast, page, NOW);
  assert.doesNotMatch(html, /Water temperature<\/th>/);
  assert.doesNotMatch(html, /Tides<\/th>/);
});

test("routes: pages, hubs, redirects, 404s, sitemap and the 503 before the first refresh", async () => {
  const kv = memoryKV();
  const e = env(kv);
  const path = pathOf(lake);

  const pending = await get(path, e);
  assert.equal(pending.status, 503);
  assert.equal(pending.headers.get("retry-after"), "3600");
  assert.equal(pending.headers.get("cache-control"), "no-store");
  assert.match(await pending.text(), /noindex/);

  await refreshOne(lake, fakeBackend("ok"), kv, NOW);
  kv.store.set("status", JSON.stringify({ [path]: { at: NOW, ok: NOW } }));
  const res = await get(path, e);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("content-type"), "text/html; charset=utf-8");
  assert.match(res.headers.get("content-security-policy")!, /img-src 'self' https:\/\/weatherkit\.apple\.com/);
  assert.equal(res.headers.get("x-content-type-options"), "nosniff");

  assert.equal((await get("/bitecurve/fishing/", e)).status, 200);
  assert.equal((await get("/bitecurve/fishing/tx/", e)).status, 200);
  const hub = await (await get("/bitecurve/fishing/tx/", e)).text();
  assert.match(hub, /Lake Fork/);
  assert.match(hub, /Galveston Jetties/);

  const r1 = await get("/bitecurve/fishing", e);
  assert.equal(r1.status, 301);
  assert.equal(r1.headers.get("location"), "https://apps.dautov.dev/bitecurve/fishing/");
  const r2 = await get("/bitecurve/fishing/tx/lake-fork", e);
  assert.equal(r2.status, 301);
  assert.equal(r2.headers.get("location"), "https://apps.dautov.dev/bitecurve/fishing/tx/lake-fork/");
  assert.equal((await get("/bitecurve/fishing/zz/", e)).status, 404);
  assert.equal((await get("/bitecurve/fishing/tx/no-such-lake/", e)).status, 404);
  assert.equal((await get("/bitecurve/fishing/tx/no-such-lake", e)).status, 404);
  assert.equal((await get("/bitecurve/other/", e)).status, 404);
  assert.equal((await handle(new Request("https://apps.dautov.dev/bitecurve/fishing/", { method: "POST" }), e, NOW)).status, 405);

  const css = await get("/bitecurve/fishing/forecast.css", e);
  assert.equal(css.headers.get("content-type"), "text/css; charset=utf-8");

  const map = await (await get("/bitecurve/fishing/sitemap.xml", e)).text();
  assert.match(map, new RegExp(`<loc>https://apps\\.dautov\\.dev${path}</loc>`));
  // Pages without a stored forecast stay out of the sitemap.
  assert.doesNotMatch(map, new RegExp(pathOf(coast)));
});

test("page list: 152 pilot pages, unique paths and weather cells, valid zones", () => {
  assert.equal(WATERS.length, 152);
  assert.equal(new Set(WATERS.map(pathOf)).size, WATERS.length);
  assert.equal(new Set(WATERS.map((w) => w.gh)).size, WATERS.length);
  for (const w of WATERS) {
    assert.match(w.gh, /^[0-9b-hjkmnp-z]{5}$/);
    assert.doesNotThrow(() => new Intl.DateTimeFormat("en-US", { timeZone: w.tz }));
    assert.ok(w.species.length >= 1);
    if (w.kind === "coast") assert.ok(w.stationId);
  }
});

test("quota: one refresh costs at most 1 forecast call plus 3 for a lake's water model", async () => {
  // The backend charges 1 WeatherKit call per forecast miss and 3 per lake water-model miss;
  // the cron asks each once per refresh, so 152 pages twice a day stay under the web budget.
  const lakes = WATERS.filter((w) => w.kind === "lake").length;
  const coasts = WATERS.length - lakes;
  // Water answers are cached 24 h, forecasts 1 h: twice a day means 2 forecasts, 1 water model.
  const perDay = lakes * (2 + 3) + coasts * 2;
  assert.ok(perDay <= 1500, `${perDay} calls a day`);
});
