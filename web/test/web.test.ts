// Pages, routes and the refresh cron against a fake backend and in-memory storage, including
// the failure drills: backend down, budget spent, no tide station, old data.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { budgetKey, MAX_COST } from "../src/budget.ts";
import { computePage, localDate, startOfLocalDay, topWindows, zoneOffset } from "../src/compute.ts";
import { handle, store, type Env } from "../src/index.ts";
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

/** An in-memory R2 bucket: the worker's binding shape. */
function memoryBucket() {
  const objects = new Map<string, string>();
  const writes: string[] = [];
  return {
    objects,
    writes,
    get: async (k: string) => (objects.has(k) ? { text: async () => objects.get(k)! } : null),
    put: async (k: string, v: string) => {
      writes.push(k);
      objects.set(k, v);
    },
  };
}

type Mode = "ok" | "down" | "throws";
interface FakeOptions {
  mode?: Mode;
  calls?: string[];
  cache?: "hit" | "miss";
  fetchedAt?: number;
}
function fakeBackend(o: FakeOptions = {}): Backend {
  const mode = o.mode ?? "ok";
  const calls = o.calls ?? [];
  const cache = o.cache ?? "miss";
  const ok = (data: unknown): WebAnswer => ({ status: 200, cache, data });
  const run = async (name: string, value: () => WebAnswer) => {
    calls.push(name);
    if (mode === "throws") throw new Error("binding down");
    return mode === "ok" ? value() : { status: 502, cache: null, data: { error: "upstream" } };
  };
  return {
    forecast: (gh) => run(`forecast:${gh}`, () => ok(forecast(NOW, o.fetchedAt ?? NOW))),
    water: (gh, kind) => run(`water:${gh}:${kind}`, () => ok({ gh, kind, tempC: 17.4, source: kind === "salt" ? "sst" : "air", asOf: "x" })),
    tide: (gh) => run(`tide:${gh}`, () => ok({ gh, station: BOSTON, km: 1, status: "ok" })),
  };
}

const env = (bucket = memoryBucket(), backend = fakeBackend()): Env => ({ BACKEND: backend, PAGES: bucket });
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

test("page data: three local days, up to three windows per species, tides only on the coast, no raw hours", () => {
  const p = computePage(coast, pathOf(coast), { forecast: forecast(), waterTemp: { c: 18, source: "sst" }, station: BOSTON }, NOW);
  assert.equal(p.days.length, 3);
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
  assert.ok(!JSON.stringify(p).includes('"hours"'));
  const l = computePage(lake, pathOf(lake), { forecast: forecast(), waterTemp: null, station: null }, NOW);
  assert.equal(l.days[0].tides, null);
  assert.equal(l.station, null);
});

test("top windows: a flat run gives non-overlapping windows; a short run gives none", () => {
  const pts = Array.from({ length: 40 }, (_, i) => ({ time: i * 900, index: 50 + (i === 20 ? 30 : 0), contributions: { light: 0, thermal: 0, wind: 0, pressure: 0, solunar: 0, tide: 0 }, hasWeather: true }));
  const ws = topWindows(pts);
  assert.equal(ws.length, 3);
  assert.ok(ws[0].start <= 20 * 900 && ws[0].end >= 20 * 900);
  assert.deepEqual(topWindows(pts.slice(0, 3)), []);
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
  assert.match(html, /modified, not Apple(&#39;|')s own forecast/);
  assert.match(html, /NOAA station 8443970/);
  assert.match(html, /apps\.apple\.com\/app\/id6834430484\?pt=127464313&amp;ct=web-bitecurve&amp;mt=8/);
  assert.match(html, /<meta name="apple-itunes-app" content="app-id=6834430484/);
  assert.match(html, /\/consent\.js/);
  assert.match(html, /Impressum/);
  assert.doesNotMatch(html, /noindex/);
  // Two days only: the third day is stored but not shown.
  assert.doesNotMatch(html, /Tuesday, Nov 24/);
});

test("render: today shows the best window still ahead, and says when the day's best is over", () => {
  const p = computePage(lake, pathOf(lake), { forecast: forecast(), waterTemp: { c: 12, source: "air" }, station: null }, NOW);
  const today = p.days[0];
  const s = today.species[0];
  const [best, second] = s.windows;
  assert.ok(best && second);
  const before = renderWater(lake, p, Math.min(best.start, second.start) - 3600);
  assert.match(before, /best window /);
  const after = renderWater(lake, { ...p, days: [{ ...today, species: [{ species: s.species, windows: [best, { ...second, start: best.end + 3600, end: best.end + 3 * 3600 }] }] }] }, best.end + 60);
  assert.match(after, /best window left/);
  assert.match(after, /the day(&#39;|')s best/);
  const late = renderWater(lake, { ...p, days: [{ ...today, species: [{ species: s.species, windows: [best] }] }] }, best.end + 60);
  assert.match(late, /over for the day/);
});

test("render: a page made in the evening still shows Today and Tomorrow the next morning", () => {
  // Made at 23:00 Chicago time; read at 07:00 the next morning.
  const madeAt = Date.parse("2026-11-23T05:00:00Z") / 1000;
  const p = computePage(lake, pathOf(lake), { forecast: forecast(madeAt), waterTemp: { c: 12, source: "air" }, station: null }, madeAt);
  const html = renderWater(lake, p, madeAt + 8 * 3600);
  assert.match(html, /Today, Monday, Nov 23/);
  assert.match(html, /Tomorrow, Tuesday, Nov 24/);
  assert.doesNotMatch(html, /Sunday, Nov 22/);
});

test("render: an old forecast says so; past days drop out", () => {
  const p = computePage(lake, pathOf(lake), { forecast: forecast(), waterTemp: { c: 12, source: "air" }, station: null }, NOW);
  const html = renderWater(lake, p, NOW + 20 * 3600);
  assert.doesNotMatch(html, /Sunday, Nov 22/);
  assert.match(html, /older than usual/);
  const later = renderWater(lake, p, NOW + 4 * 86400);
  assert.match(later, /being updated/);
  assert.match(later, /noindex/);
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

test("refresh: never-refreshed pages first, then the oldest; the queue moves before the work", async () => {
  const bucket = memoryBucket();
  const s = store(bucket);
  const calls: string[] = [];
  await refresh(fakeBackend({ calls }), s, NOW, 2);
  const status = JSON.parse(bucket.objects.get("status.json")!);
  assert.deepEqual(Object.keys(status), [pathOf(WATERS[0]), pathOf(WATERS[1])]);
  assert.ok(bucket.objects.has(pageKey(pathOf(WATERS[0]))));
  // The queue is written before the pages, then once more with the successes.
  assert.equal(bucket.writes[0], "status.json");
  assert.equal(bucket.writes.at(-1), "status.json");
  assert.deepEqual(pick(status, 2).map(pathOf), [pathOf(WATERS[2]), pathOf(WATERS[3])]);
  // Coast pages ask for the tide, lakes do not; the forecast comes first.
  assert.equal(calls.filter((c) => c.startsWith("tide:")).length, [WATERS[0], WATERS[1]].filter((w) => w.kind === "coast").length);
  assert.ok(calls[0].startsWith("forecast:"));
});

test("refresh: a run that dies mid-way does not block the queue", async () => {
  const bucket = memoryBucket();
  const s = store(bucket);
  const crashing: Store_ = { get: s.get, put: async (k, v) => (k.startsWith("pages/") ? Promise.reject(new Error("write failed")) : s.put(k, v)) };
  const out = await refresh(fakeBackend(), crashing, NOW, 1);
  assert.equal(out[pathOf(WATERS[0])], "failed");
  const status = JSON.parse(bucket.objects.get("status.json")!);
  assert.equal(status[pathOf(WATERS[0])].at, NOW);
  assert.equal(pick(status, 1)[0], WATERS[1]);
});
type Store_ = { get(k: string): Promise<string | null>; put(k: string, v: string): Promise<void> };

test("budget: counts what the answers cost, stops before it would pass the cap", async () => {
  const bucket = memoryBucket();
  const s = store(bucket);
  // A lake: forecast miss (1) + water model miss (3).
  assert.equal(await refreshOne(lake, fakeBackend(), s, NOW, 100), "ok");
  assert.equal(bucket.objects.get(budgetKey(NOW)), "4");
  // A coast: forecast miss (1) + sea temperature from NOAA (0) + tide (0).
  assert.equal(await refreshOne(coast, fakeBackend(), s, NOW, 100), "ok");
  assert.equal(bucket.objects.get(budgetKey(NOW)), "5");
  // Cache hits cost nothing.
  assert.equal(await refreshOne(lake, fakeBackend({ cache: "hit" }), s, NOW, 100), "ok");
  assert.equal(bucket.objects.get(budgetKey(NOW)), "5");
  // Not enough left for the worst case: no call is made at all.
  const calls: string[] = [];
  assert.equal(await refreshOne(lake, fakeBackend({ calls }), s, NOW, 5 + MAX_COST - 1), "budget");
  assert.deepEqual(calls, []);
  // A new UTC day starts from zero.
  assert.equal(await refreshOne(lake, fakeBackend(), s, NOW + 86400, 5), "ok");
});

test("failure drills: backend down or broken keeps the last good page, and asks nothing more", async () => {
  const bucket = memoryBucket();
  const s = store(bucket);
  assert.equal(await refreshOne(lake, fakeBackend(), s, NOW), "ok");
  const good = bucket.objects.get(pageKey(pathOf(lake)));
  const calls: string[] = [];
  assert.equal(await refreshOne(lake, fakeBackend({ mode: "down", calls }), s, NOW + 3600), "no-weather");
  assert.deepEqual(calls.map((c) => c.split(":")[0]), ["forecast"], "no water call without a forecast");
  assert.equal(await refreshOne(lake, fakeBackend({ mode: "throws" }), s, NOW + 7200), "failed");
  // A forecast more than 24 hours old is not scored into a page.
  assert.equal(await refreshOne(lake, fakeBackend({ fetchedAt: NOW - 25 * 3600 }), s, NOW), "no-weather");
  assert.equal(bucket.objects.get(pageKey(pathOf(lake))), good, "the last good page stays");
});

test("failure drill: no water temperature and no tide station still give a page", async () => {
  const bucket = memoryBucket();
  const b = fakeBackend();
  const partial: Backend = {
    ...b,
    water: async () => ({ status: 502, cache: null, data: { error: "upstream" } }),
    tide: async () => ({ status: 200, cache: "hit", data: { gh: "x", station: null, km: null, status: "none_in_range" } }),
  };
  assert.equal(await refreshOne(coast, partial, store(bucket), NOW), "ok");
  const page = JSON.parse(bucket.objects.get(pageKey(pathOf(coast)))!);
  assert.equal(page.waterTemp, null);
  assert.equal(page.station, null);
  const html = renderWater(coast, page, NOW);
  assert.doesNotMatch(html, /Water temperature<\/th>/);
  assert.doesNotMatch(html, /Tides<\/th>/);
});

test("routes: pages, hubs, redirects, 404s, sitemap and the 503 before the first refresh or after 36 h", async () => {
  const bucket = memoryBucket();
  const e = env(bucket);
  const path = pathOf(lake);

  const pending = await get(path, e);
  assert.equal(pending.status, 503);
  assert.equal(pending.headers.get("retry-after"), "3600");
  assert.equal(pending.headers.get("cache-control"), "no-store");
  assert.match(await pending.text(), /noindex/);

  await refreshOne(lake, fakeBackend(), store(bucket), NOW);
  bucket.objects.set("status.json", JSON.stringify({ [path]: { at: NOW, ok: NOW } }));
  const res = await get(path, e);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("content-type"), "text/html; charset=utf-8");
  assert.match(res.headers.get("content-security-policy")!, /img-src 'self' https:\/\/weatherkit\.apple\.com/);
  assert.equal(res.headers.get("x-content-type-options"), "nosniff");
  // Older than 36 hours: not shown, and out of the sitemap.
  assert.equal((await get(path, e, NOW + 37 * 3600)).status, 503);
  assert.doesNotMatch(await (await get("/bitecurve/fishing/sitemap.xml", e, NOW + 37 * 3600)).text(), new RegExp(path));

  assert.equal((await get("/bitecurve/fishing/", e)).status, 200);
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
  assert.equal((await get("/bitecurve/fishing/forecast.css", e)).headers.get("content-type"), "text/css; charset=utf-8");

  const map = await (await get("/bitecurve/fishing/sitemap.xml", e)).text();
  assert.match(map, new RegExp(`<loc>https://apps\\.dautov\\.dev${path}</loc>`));
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

test("quota: about two refreshes a day for every page stays under the web's 1,500 calls", () => {
  // 288 cron runs a day, one page each. A lake costs 1 (forecast) + 3 (water model) on its first
  // refresh of the day and 1 on the second (the water answer is cached 24 h); a coast costs 1.
  const lakes = WATERS.filter((w) => w.kind === "lake").length;
  const coasts = WATERS.length - lakes;
  const perRefreshDay = 288 / WATERS.length;
  const perDay = lakes * (perRefreshDay * 1 + 3) + coasts * perRefreshDay;
  assert.ok(perDay <= 1500, `${Math.round(perDay)} calls a day`);
});
