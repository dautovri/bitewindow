import assert from "node:assert/strict";
import { test } from "node:test";
import { cacheKey, decodeGeohash, isGeohash5, slim, weatherKitJwt, weatherKitUrl } from "../src/lib.ts";
import worker from "../src/index.ts";

const now = new Date("2026-11-10T15:20:30Z");

test("geohash validation", () => {
  assert.equal(isGeohash5("u33dc"), true);
  assert.equal(isGeohash5("u33d"), false);
  assert.equal(isGeohash5("u33da"), false); // 'a' is not in the alphabet
  assert.equal(isGeohash5(null), false);
});

test("geohash decodes to cell centre", () => {
  const { lat, lon } = decodeGeohash("u33dc");
  assert.ok(Math.abs(lat - 52.52) < 0.03);
  assert.ok(Math.abs(lon - 13.405) < 0.03);
});

test("cache key buckets by UTC hour", () => {
  assert.equal(cacheKey("u33dc", now), "wx:u33dc:2026-11-10T15");
});

test("WeatherKit URL covers -48h..+240h", () => {
  const u = new URL(weatherKitUrl("u33dc", now));
  assert.equal(u.host, "weatherkit.apple.com");
  assert.equal(u.searchParams.get("dataSets"), "forecastHourly");
  assert.equal(u.searchParams.get("hourlyStart"), "2026-11-08T15:00:00.000Z");
  assert.equal(u.searchParams.get("hourlyEnd"), "2026-11-20T15:00:00.000Z");
});

test("slim keeps scoring fields and drops malformed hours", () => {
  const raw = {
    forecastHourly: {
      hours: [
        { forecastStart: "2026-11-10T15:00:00Z", pressure: 1012.4, cloudCover: 0.8, windSpeed: 14, windDirection: 220, temperature: 11 },
        { forecastStart: "2026-11-10T16:00:00Z", pressure: 1011.9 },
        { forecastStart: "2026-11-10T17:00:00Z" },
      ],
    },
  };
  const out = slim("u33dc", raw, now);
  assert.equal(out.hours.length, 2);
  assert.deepEqual(out.hours[0], { t: "2026-11-10T15:00:00Z", p: 1012.4, c: 0.8, ws: 14, wd: 220, ta: 11 });
  assert.equal(out.hours[1].wd, null);
  assert.deepEqual(slim("u33dc", {}, now).hours, []);
});

test("JWT is a verifiable ES256 token with WeatherKit claims", async () => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const jwt = await weatherKitJwt({ teamId: "TEAM123456", serviceId: "com.example.wx", keyId: "KEY1234567", privateKey: pair.privateKey }, now);
  const [h, c, s] = jwt.split(".");
  const dec = (x: string) => JSON.parse(Buffer.from(x, "base64url").toString());
  assert.deepEqual(dec(h), { alg: "ES256", kid: "KEY1234567", id: "TEAM123456.com.example.wx" });
  assert.equal(dec(c).iss, "TEAM123456");
  assert.equal(dec(c).sub, "com.example.wx");
  assert.equal(dec(c).exp - dec(c).iat, 1800);
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, Buffer.from(s, "base64url"), Buffer.from(`${h}.${c}`));
  assert.equal(ok, true);
});

test("worker: validates input, serves cache hits, caches misses", async () => {
  const store = new Map<string, string>();
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pkcs8 = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  const env = {
    WX_CACHE: { get: async (k: string) => store.get(k) ?? null, put: async (k: string, v: string) => void store.set(k, v) },
    WEATHERKIT_TEAM_ID: "T",
    WEATHERKIT_SERVICE_ID: "S",
    WEATHERKIT_KEY_ID: "K",
    WEATHERKIT_PRIVATE_KEY: `-----BEGIN PRIVATE KEY-----\n${pkcs8}\n-----END PRIVATE KEY-----`,
  };

  assert.equal((await worker.fetch(new Request("https://x/wx?gh=bad"), env)).status, 400);
  assert.equal((await worker.fetch(new Request("https://x/nope"), env)).status, 404);

  let upstreamCalls = 0;
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (input: any, init: any) => {
    upstreamCalls++;
    assert.match(String(input), /^https:\/\/weatherkit\.apple\.com\//);
    assert.match(init.headers.authorization, /^Bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    return new Response(JSON.stringify({ forecastHourly: { hours: [{ forecastStart: "2026-11-10T15:00:00Z", pressure: 1010 }] } }));
  }) as typeof fetch;
  try {
    const miss = await worker.fetch(new Request("https://x/wx?gh=u33dc"), env);
    assert.equal(miss.status, 200);
    assert.equal(miss.headers.get("x-cache"), "miss");
    assert.equal((await miss.json()).hours.length, 1);
    const hit = await worker.fetch(new Request("https://x/wx?gh=u33dc"), env);
    assert.equal(hit.headers.get("x-cache"), "hit");
    assert.equal((await hit.json()).gh, "u33dc");
    assert.equal(upstreamCalls, 1);
  } finally {
    globalThis.fetch = realFetch;
  }
});
