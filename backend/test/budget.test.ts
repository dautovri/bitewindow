import assert from "node:assert/strict";
import { test } from "node:test";
import { budgetKey, DEFAULT_DAILY_BUDGET, dailyBudget, secondsToReset, spend } from "../src/budget.ts";
import worker, { weather, water, webPolicy } from "../src/index.ts";

type Put = { key: string; value: string; ttl?: number };

const STALE_OK = { "x-accept-stale": "1" };

function memoryKV(seed: [string, string][] = []) {
  const store = new Map<string, string>(seed);
  const puts: Put[] = [];
  return {
    store,
    puts,
    kv: {
      get: async (k: string) => store.get(k) ?? null,
      put: async (k: string, v: string, o?: { expirationTtl?: number }) => {
        puts.push({ key: k, value: v, ttl: o?.expirationTtl });
        store.set(k, v);
      },
    },
  };
}

async function envWith(kv: ReturnType<typeof memoryKV>["kv"], budget?: string) {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pkcs8 = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  return {
    WX_CACHE: kv,
    WEATHERKIT_TEAM_ID: "T",
    WEATHERKIT_SERVICE_ID: "S",
    WEATHERKIT_KEY_ID: "K",
    WEATHERKIT_PRIVATE_KEY: `-----BEGIN PRIVATE KEY-----\n${pkcs8}\n-----END PRIVATE KEY-----`,
    ...(budget === undefined ? {} : { DAILY_WEATHERKIT_BUDGET: budget }),
  };
}

/** Fake upstreams: WeatherKit answers one hour (or 30 days of hours), counted; NOAA SST is down. */
function fakeFetch() {
  const calls = { weatherkit: 0, other: 0 };
  const fn = (async (input: any) => {
    const u = String(input);
    if (u.startsWith("https://weatherkit.apple.com/")) {
      calls.weatherkit++;
      const q = new URL(u).searchParams;
      const start = Date.parse(q.get("hourlyStart")!);
      const end = Date.parse(q.get("hourlyEnd")!);
      const hours = [];
      for (let t = start; t < end; t += 3_600_000) {
        hours.push({ forecastStart: new Date(t).toISOString(), pressure: 1012, temperature: 12 });
      }
      return new Response(JSON.stringify({ forecastHourly: { hours } }));
    }
    calls.other++;
    return new Response("", { status: 503 });
  }) as typeof fetch;
  return { calls, fn };
}

test("budget: parsing, key per UTC day, reset time", () => {
  assert.equal(dailyBudget(undefined), DEFAULT_DAILY_BUDGET);
  assert.equal(DEFAULT_DAILY_BUDGET, 5000);
  assert.equal(dailyBudget(""), 5000);
  assert.equal(dailyBudget("abc"), 5000);
  assert.equal(dailyBudget("-3"), 5000);
  assert.equal(dailyBudget("1.5"), 5000);
  assert.equal(dailyBudget("0"), 0);
  assert.equal(dailyBudget("12000"), 12000);
  assert.equal(budgetKey(new Date("2026-11-21T23:59:59Z")), "wkbudget:2026-11-21");
  assert.equal(secondsToReset(new Date("2026-11-21T23:59:00Z")), 60);
  assert.equal(secondsToReset(new Date("2026-11-21T00:00:00Z")), 86_400);
});

test("budget: spend counts by cost and refuses what does not fit", async () => {
  const { kv, store } = memoryKV();
  const now = new Date("2026-11-21T10:00:00Z");
  assert.equal(await spend(kv, 4, 3, now), true);
  assert.equal(store.get("wkbudget:2026-11-21"), "3");
  assert.equal(await spend(kv, 4, 3, now), false); // 6 > 4
  assert.equal(await spend(kv, 4, 1, now), true);
  assert.equal(await spend(kv, 4, 1, now), false);
  assert.equal(store.get("wkbudget:2026-11-21"), "4");
  // A new UTC day starts from zero.
  assert.equal(await spend(kv, 4, 1, new Date("2026-11-22T00:00:01Z")), true);
});

test("worker /wx: spent budget serves the saved copy, else a 503 that is not cached", async () => {
  const { kv, store } = memoryKV();
  const env = await envWith(kv, "1");
  const { calls, fn } = fakeFetch();
  const realFetch = globalThis.fetch;
  globalThis.fetch = fn;
  try {
    const first = await worker.fetch(new Request("https://x/wx?gh=u33dc"), env);
    assert.equal(first.status, 200);
    assert.equal(calls.weatherkit, 1);
    const saved = await first.json();

    // Next hour (cache key gone): budget of 1 is spent. App 1.2.0 (no opt-in) gets the 503 and
    // uses its own copy; a client that accepts saved answers gets the last good copy.
    for (const k of [...store.keys()]) if (k.startsWith("wx:u33dc:")) store.delete(k);
    assert.equal((await worker.fetch(new Request("https://x/wx?gh=u33dc"), env)).status, 503);
    const stale = await worker.fetch(new Request("https://x/wx?gh=u33dc", { headers: STALE_OK }), env);
    assert.equal(stale.status, 200);
    assert.equal(stale.headers.get("x-cache"), "stale");
    assert.equal(stale.headers.get("cache-control"), "no-store");
    assert.equal((await stale.json()).fetchedAt, saved.fetchedAt);
    assert.equal(calls.weatherkit, 1);

    // A cell never fetched: clear JSON error, no WeatherKit call, nothing cached for the cell.
    const none = await worker.fetch(new Request("https://x/wx?gh=u33dd", { headers: STALE_OK }), env);
    assert.equal(none.status, 503);
    assert.equal(none.headers.get("cache-control"), "no-store");
    assert.ok(Number(none.headers.get("retry-after")) > 0);
    assert.equal((await none.json()).error, "budget");
    assert.equal(calls.weatherkit, 1);
    assert.ok(![...store.keys()].some((k) => k.includes("u33dd")));

    // Cache hits never touch the budget.
    store.set("wx:u33dd:" + new Date().toISOString().slice(0, 13), JSON.stringify({ gh: "u33dd", fetchedAt: "x", hours: [] }));
    assert.equal((await worker.fetch(new Request("https://x/wx?gh=u33dd"), env)).status, 200);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("worker /water: the air model costs 3 calls and stops at the budget", async () => {
  const { kv, store } = memoryKV();
  const env = await envWith(kv, "5");
  const { calls, fn } = fakeFetch();
  const realFetch = globalThis.fetch;
  globalThis.fetch = fn;
  try {
    const first = await worker.fetch(new Request("https://x/water?gh=u33dc&kind=fresh"), env);
    assert.equal(first.status, 200);
    assert.equal((await first.json()).source, "air");
    assert.equal(calls.weatherkit, 3);
    assert.equal(store.get(budgetKey(new Date())), "3");

    // 3 + 3 > 5: no call, a saved estimate for this cell stands in once its daily key is gone.
    store.delete("water:fresh:u33dc");
    const stale = await worker.fetch(new Request("https://x/water?gh=u33dc&kind=fresh", { headers: STALE_OK }), env);
    assert.equal(stale.status, 200);
    assert.equal(stale.headers.get("x-cache"), "stale");
    assert.equal(calls.weatherkit, 3);

    // Salt cell, NOAA SST down, budget spent: 503 budget, and the null answer is not cached.
    const salt = await worker.fetch(new Request("https://x/water?gh=u33dd&kind=salt"), env);
    assert.equal(salt.status, 503);
    assert.equal((await salt.json()).error, "budget");
    assert.ok(!store.has("water:salt:u33dd"));
    assert.equal(calls.weatherkit, 3);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("worker: missing budget variable falls back to the default", async () => {
  const { kv, store } = memoryKV();
  const env = await envWith(kv);
  const { calls, fn } = fakeFetch();
  const realFetch = globalThis.fetch;
  globalThis.fetch = fn;
  try {
    store.set(budgetKey(new Date()), String(DEFAULT_DAILY_BUDGET - 1));
    assert.equal((await worker.fetch(new Request("https://x/wx?gh=u33dc"), env)).status, 200);
    assert.equal((await worker.fetch(new Request("https://x/wx?gh=u33dd"), env)).status, 503);
    assert.equal(calls.weatherkit, 1);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("budget: a refused counter write (KV per-key limit) does not fail the request", async () => {
  const kv = {
    get: async () => "7",
    put: async () => {
      throw new Error("KV PUT failed: 429 Too Many Requests");
    },
  };
  assert.equal(await spend(kv, 10, 1, new Date()), true);
  assert.equal(await spend(kv, 7, 1, new Date()), false);
});

test("web policy: no app budget or per-IP limit, only the 24-hour water answer is written", async () => {
  const { kv, store, puts } = memoryKV();
  // App budget 0 and a limiter that refuses everything: the web path must use neither.
  const env = { ...(await envWith(kv, "0")), UPSTREAM_LIMITER: { limit: async () => ({ success: false }) } };
  const { calls, fn } = fakeFetch();
  const realFetch = globalThis.fetch;
  globalThis.fetch = fn;
  try {
    const day = new Date().toISOString().slice(0, 10);
    const f = await weather("u33dc", env, webPolicy);
    assert.equal(f.status, 200);
    assert.equal(f.headers.get("x-cache"), "miss");
    assert.equal(calls.weatherkit, 1);
    assert.equal(store.get(`wkbudget:${day}`), undefined, "nothing counted against the apps");
    assert.ok(!puts.some((p) => p.key.startsWith("wx:") || p.key.startsWith("wxlast:")), "no hourly key, no saved copy");

    const w = await water("u33dc", "fresh", env, webPolicy);
    assert.equal(w.status, 200);
    assert.equal(calls.weatherkit, 4, "the air model costs three calls");
    assert.deepEqual(puts.map((p) => p.key), ["water:fresh:u33dc"]);
    // The next refresh gets the water answer from the cache for free.
    assert.equal((await water("u33dc", "fresh", env, webPolicy)).headers.get("x-cache"), "hit");
    assert.equal(calls.weatherkit, 4);

    // The app routes still apply the per-IP limit.
    assert.equal((await worker.fetch(new Request("https://x/wx?gh=u33dd"), env)).status, 429);
  } finally {
    globalThis.fetch = realFetch;
  }
});
