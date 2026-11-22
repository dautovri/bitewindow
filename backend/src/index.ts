import { cacheKey, decodeGeohash, importPrivateKey, isGeohash5, slim, weatherKitJwt, weatherKitUrl } from "./lib.ts";
import { airHistoryUrls, dailyAirMeans, mergeHours, isWaterKind, lakeTemp, nearestSst, sstUrl, type WaterAnswer, type WaterKind } from "./water.ts";
import {
  datumsUrl,
  harconUrl,
  nearestStation,
  parseStationList,
  stationListUrl,
  toTideStation,
  type StationRef,
} from "./tide.ts";
import { digest, isAngler, MAX_BODY, parseTrip, totals } from "./trip.ts";
import { DEFAULT_WEB_DAILY_BUDGET, dailyBudget, secondsToReset, spend } from "./budget.ts";

interface KV {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, opts?: { expirationTtl?: number }): Promise<void>;
}

export interface Env {
  WX_CACHE: KV;
  WEATHERKIT_TEAM_ID: string;
  WEATHERKIT_SERVICE_ID: string;
  WEATHERKIT_KEY_ID: string;
  /** PKCS#8 PEM (.p8) — set with `wrangler secret put WEATHERKIT_PRIVATE_KEY`. */
  WEATHERKIT_PRIVATE_KEY: string;
  /** Workers Rate Limiting binding (`[[ratelimits]]` in wrangler.toml). */
  UPSTREAM_LIMITER?: RateLimit;
  /** Opt-in shared trips (D1, see schema.sql). */
  TRIPS?: D1;
  TRIP_LIMITER?: RateLimit;
  /** WeatherKit calls allowed per UTC day across all app clients (budget.ts). Default 5000. */
  DAILY_WEATHERKIT_BUDGET?: string;
  /** The forecast web pages' own daily share, reached only through `WebForecast` (web.ts). Default 1500. */
  WEB_DAILY_WEATHERKIT_BUDGET?: string;
}

/**
 * Who is asking. The apps: misses limited per IP, the app budget, saved copies only on request
 * (`x-accept-stale`). The forecast web pages (web.ts, reachable only through a service binding):
 * their own daily budget, no per-IP limit (their cron paces them) and always the saved copy
 * when the budget is spent, since a page shows its age.
 */
export interface Policy {
  allow(): Promise<boolean>;
  spend(cost: number, now: Date): Promise<boolean>;
  acceptStale: boolean;
}

const appPolicy = (req: Request, env: Env): Policy => ({
  allow: () => allowUpstream(req, env),
  spend: (cost, now) => spendWeatherKit(env, cost, now),
  acceptStale: acceptsStale(req),
});

export const webPolicy = (env: Env): Policy => ({
  allow: async () => true,
  spend: (cost, now) =>
    spend(env.WX_CACHE, dailyBudget(env.WEB_DAILY_WEATHERKIT_BUDGET, DEFAULT_WEB_DAILY_BUDGET), cost, now, "wkbudget-web"),
  acceptStale: true,
});

interface D1 {
  prepare(sql: string): { bind(...values: unknown[]): { run(): Promise<unknown> } };
}

interface RateLimit {
  limit(opts: { key: string }): Promise<{ success: boolean }>;
}

/**
 * Cache hits are cheap; cache misses cost a WeatherKit call or NOAA requests
 * plus a KV write. Misses are limited per client IP so a script walking the
 * geohash grid cannot drain the WeatherKit quota from one address.
 */
async function allowUpstream(req: Request, env: Env): Promise<boolean> {
  if (!env.UPSTREAM_LIMITER) return true;
  const ip = req.headers.get("cf-connecting-ip") ?? "unknown";
  return (await env.UPSTREAM_LIMITER.limit({ key: ip })).success;
}

const tooMany = () => json({ error: "rate limited" }, 429, { "retry-after": "60" });

const DAY = 86_400;

/**
 * Reserves WeatherKit calls from the account-wide daily budget (budget.ts). Each forecast is
 * one call, a modelled water temperature three.
 */
const spendWeatherKit = (env: Env, cost: number, now: Date) =>
  spend(env.WX_CACHE, dailyBudget(env.DAILY_WEATHERKIT_BUDGET), cost, now);

/** Today's WeatherKit budget is spent and nothing is saved for this cell. Never cached. */
const budgetSpent = (now: Date) => {
  const retry = secondsToReset(now);
  return json({ error: "budget", retryAfter: retry }, 503, { "retry-after": String(retry), "cache-control": "no-store" });
};

/**
 * Saved answers are served only to clients that ask for them with `x-accept-stale: 1`: app
 * 1.2.0 cannot tell a saved answer from a fresh one, so it gets the 503 and uses its own copy.
 */
const acceptsStale = (req: Request) => req.headers.get("x-accept-stale") === "1";

/** Last good answers, kept past their hourly/daily keys to stand in while the budget is spent. */
const lastWxKey = (gh: string) => `wxlast:${gh}`;
const lastWaterKey = (kind: WaterKind, gh: string) => `waterlast:${kind}:${gh}`;

/** JSON API only: nothing may be rendered, framed or sniffed as another type. */
const SECURITY_HEADERS = {
  "strict-transport-security": "max-age=31536000; includeSubDomains",
  "x-content-type-options": "nosniff",
  "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
  "referrer-policy": "no-referrer",
};

const json = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
  new Response(typeof body === "string" ? body : JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...SECURITY_HEADERS, ...extra },
  });

export async function weather(gh: string, env: Env, policy: Policy): Promise<Response> {
  const now = new Date();
  const key = cacheKey(gh, now);
  const cached = await env.WX_CACHE.get(key);
  if (cached) return json(cached, 200, { "x-cache": "hit", "cache-control": "public, max-age=900" });
  if (!(await policy.allow())) return tooMany();
  if (!(await policy.spend(1, now))) {
    // The saved copy carries its own `fetchedAt`, so the app can say how old it is.
    const stale = policy.acceptStale ? await env.WX_CACHE.get(lastWxKey(gh)) : null;
    if (stale) return json(stale, 200, { "x-cache": "stale", "cache-control": "no-store" });
    return budgetSpent(now);
  }

  const token = await weatherKitToken(env, now);
  const upstream = await fetch(weatherKitUrl(gh, now), { headers: { authorization: `Bearer ${token}` } });
  if (!upstream.ok) return json({ error: "upstream", status: upstream.status }, 502);

  const slimmed = slim(gh, await upstream.json(), now);
  // An empty forecast is unusable to the app; do not pin it in the cache for an hour.
  if (slimmed.hours.length === 0) return json({ error: "upstream", status: "empty" }, 502);
  const body = JSON.stringify(slimmed);
  // Entry is keyed by hour; keep it a little past the hour for slow clocks.
  await env.WX_CACHE.put(key, body, { expirationTtl: 3900 });
  await env.WX_CACHE.put(lastWxKey(gh), body, { expirationTtl: 3 * DAY });
  return json(body, 200, { "x-cache": "miss", "cache-control": "public, max-age=900" });
}

async function stations(env: Env): Promise<StationRef[] | null> {
  const cached = await env.WX_CACHE.get("tide:stations");
  if (cached) return JSON.parse(cached);
  const res = await fetch(stationListUrl());
  if (!res.ok) return null;
  const list = parseStationList(await res.json());
  // An empty list is a broken response, not "no stations anywhere": caching
  // its consequence would mark every cell as station-less for 30 days.
  if (list.length === 0) return null;
  await env.WX_CACHE.put("tide:stations", JSON.stringify(list), { expirationTtl: 7 * DAY });
  return list;
}

/** Why `/tide` answered the way it did. Added after app 1.2.0, which reads `station` only. */
export type TideStatus = "ok" | "none_in_range" | "no_constituents";

/**
 * Harmonic constants for the nearest NOAA station to a geohash-5 cell.
 * `{ station: null }` is not an error, so the app can stop asking; `status` says why:
 * `none_in_range` (no harmonic station within 40 km) or `no_constituents` (the nearest
 * station has none of the constituents the engine evaluates; `nearest` names it).
 * Constants change rarely: cached 30 days per cell, one day for `no_constituents`, which
 * may be a gap in NOAA's data that gets filled.
 */
export async function tide(gh: string, env: Env, policy: Policy): Promise<Response> {
  const key = `tide:${gh}`;
  const headers = { "cache-control": "public, max-age=86400" };
  const cached = await env.WX_CACHE.get(key);
  if (cached) return json(cached, 200, { ...headers, "x-cache": "hit" });
  if (!(await policy.allow())) return tooMany();

  const list = await stations(env);
  if (!list) return json({ error: "upstream" }, 502);
  const { lat, lon } = decodeGeohash(gh);
  const near = nearestStation(list, lat, lon);

  let station = null;
  let status: TideStatus = "none_in_range";
  if (near) {
    const [h, d] = await Promise.all([fetch(harconUrl(near.station.id)), fetch(datumsUrl(near.station.id))]);
    if (!h.ok) return json({ error: "upstream", status: h.status }, 502);
    // Without datums the mean level falls back to 0 and every height is off;
    // fail now rather than cache a wrong station for 30 days.
    if (!d.ok) return json({ error: "upstream", status: d.status }, 502);
    station = toTideStation(near.station, await h.json(), await d.json());
    status = station ? "ok" : "no_constituents";
  }
  const km = near ? Math.round(near.km * 10) / 10 : null;
  const body = JSON.stringify({
    gh,
    station,
    // Kept as before (null without a usable station) for app 1.2.0.
    km: station ? km : null,
    status,
    ...(status === "no_constituents" && near ? { nearest: { id: near.station.id, name: near.station.name, km } } : {}),
  });
  await env.WX_CACHE.put(key, body, { expirationTtl: status === "no_constituents" ? DAY : 30 * DAY });
  return json(body, 200, { ...headers, "x-cache": "miss" });
}

async function weatherKitToken(env: Env, now: Date): Promise<string> {
  const privateKey = await importPrivateKey(env.WEATHERKIT_PRIVATE_KEY);
  return weatherKitJwt(
    { teamId: env.WEATHERKIT_TEAM_ID, serviceId: env.WEATHERKIT_SERVICE_ID, keyId: env.WEATHERKIT_KEY_ID, privateKey },
    now,
  );
}

/** Lake model: 30 days of air temperature from WeatherKit. Null when there is too little history. */
async function modelledFromAir(gh: string, env: Env, now: Date): Promise<number | null> {
  const headers = { authorization: `Bearer ${await weatherKitToken(env, now)}` };
  const answers = await Promise.all(airHistoryUrls(gh, now).map((u) => fetch(u, { headers })));
  // A missing stretch would bias the model towards the days that did arrive.
  if (answers.some((r) => !r.ok)) return null;
  return lakeTemp(dailyAirMeans(mergeHours(await Promise.all(answers.map((r) => r.json())))));
}

/**
 * Estimated water temperature for a cell (see water.ts). Sea cells use the satellite
 * analysis and fall back to the air model when no sea cell is in reach or NOAA does not
 * answer, so one free upstream is never the only source. Changes by tenths of a degree a
 * day: cached 24 hours, 2 hours when there is no estimate.
 */
export async function water(gh: string, kind: WaterKind, env: Env, policy: Policy): Promise<Response> {
  const key = `water:${kind}:${gh}`;
  const headers = { "cache-control": "public, max-age=3600" };
  const cached = await env.WX_CACHE.get(key);
  if (cached) return json(cached, 200, { ...headers, "x-cache": "hit" });
  if (!(await policy.allow())) return tooMany();

  const now = new Date();
  const answer: WaterAnswer = { gh, kind, tempC: null, source: null, asOf: now.toISOString() };
  if (kind === "salt") {
    try {
      const res = await fetch(sstUrl(gh), { signal: AbortSignal.timeout(8000) });
      const { lat, lon } = decodeGeohash(gh);
      const sst = res.ok ? nearestSst(await res.json(), lat, lon) : null;
      if (sst) Object.assign(answer, { tempC: sst.tempC, source: "sst", asOf: sst.asOf });
    } catch {
      // NOAA slow or down: the air model below stands in.
    }
  }
  if (answer.tempC === null) {
    // The air model costs three WeatherKit calls.
    if (!(await policy.spend(3, now))) {
      const stale = policy.acceptStale ? await env.WX_CACHE.get(lastWaterKey(kind, gh)) : null;
      if (stale) return json(stale, 200, { "x-cache": "stale", "cache-control": "no-store" });
      return budgetSpent(now);
    }
    const modelled = await modelledFromAir(gh, env, now);
    if (modelled !== null) Object.assign(answer, { tempC: modelled, source: "air" });
  }
  const body = JSON.stringify(answer);
  await env.WX_CACHE.put(key, body, { expirationTtl: answer.tempC === null ? 2 * 3600 : 24 * 3600 });
  if (answer.tempC !== null) await env.WX_CACHE.put(lastWaterKey(kind, gh), body, { expirationTtl: 10 * DAY });
  return json(body, 200, { ...headers, "x-cache": "miss" });
}

/** The request body as JSON, or null when it is too large or not JSON. */
async function smallJson(req: Request): Promise<unknown> {
  // A declared length is required: a chunked body could otherwise be buffered whole before
  // its size is known.
  const declared = Number(req.headers.get("content-length") ?? Number.NaN);
  if (!Number.isInteger(declared) || declared < 2 || declared > MAX_BODY) return null;
  const text = await req.text();
  if (text.length > MAX_BODY) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

/**
 * `POST /trip` stores one shared trip; `POST /trip/delete` removes everything sent under an
 * angler id. Neither touches WeatherKit or NOAA, and the caller's address is used for the
 * rate limit only, never stored.
 */
async function trips(path: string, req: Request, env: Env): Promise<Response> {
  if (!env.TRIPS) return json({ error: "sharing is not set up" }, 503);
  if (env.TRIP_LIMITER) {
    const ip = req.headers.get("cf-connecting-ip") ?? "unknown";
    if (!(await env.TRIP_LIMITER.limit({ key: ip })).success) return tooMany();
  }
  const body = await smallJson(req);
  if (path === "/trip/delete") {
    const angler = (body as { angler?: unknown } | null)?.angler;
    if (!isAngler(angler)) return json({ error: "bad request" }, 400);
    await env.TRIPS.prepare("DELETE FROM trips WHERE angler = ?").bind(angler).run();
    return new Response(null, { status: 204, headers: SECURITY_HEADERS });
  }
  const trip = parseTrip(body);
  if (!trip) return json({ error: "bad request" }, 400);
  const payload = JSON.stringify(trip);
  const { hours, catches } = totals(trip);
  await env.TRIPS.prepare(
    "INSERT OR IGNORE INTO trips (received, angler, digest, gh, month, water, species, hours, catches, payload) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
  )
    .bind(new Date().toISOString().slice(0, 7), trip.angler, await digest(payload), trip.gh, trip.month, trip.water,
      trip.species, hours, catches, payload)
    .run();
  return new Response(null, { status: 204, headers: SECURITY_HEADERS });
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/health") return json({ ok: true });
    if (req.method === "POST" && (url.pathname === "/trip" || url.pathname === "/trip/delete")) {
      try {
        return await trips(url.pathname, req, env);
      } catch {
        return json({ error: "storage" }, 502);
      }
    }
    if (req.method !== "GET" || !["/wx", "/tide", "/water"].includes(url.pathname)) {
      return json({ error: "not found" }, 404);
    }
    const gh = url.searchParams.get("gh");
    if (!isGeohash5(gh)) return json({ error: "gh must be a 5-character geohash" }, 400);
    const kind = url.searchParams.get("kind");
    if (url.pathname === "/water" && !isWaterKind(kind)) return json({ error: "kind must be salt or fresh" }, 400);
    try {
      const policy = appPolicy(req, env);
      if (url.pathname === "/water") return await water(gh, kind as WaterKind, env, policy);
      return await (url.pathname === "/wx" ? weather(gh, env, policy) : tide(gh, env, policy));
    } catch {
      // Upstream reset, timed out or sent something that is not JSON.
      return json({ error: "upstream" }, 502);
    }
  },
};
