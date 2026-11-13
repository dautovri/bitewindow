import { cacheKey, decodeGeohash, importPrivateKey, isGeohash5, slim, weatherKitJwt, weatherKitUrl } from "./lib.ts";
import {
  datumsUrl,
  harconUrl,
  nearestStation,
  parseStationList,
  stationListUrl,
  toTideStation,
  type StationRef,
} from "./tide.ts";

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

const json = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
  new Response(typeof body === "string" ? body : JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...extra },
  });

async function weather(gh: string, req: Request, env: Env): Promise<Response> {
  const now = new Date();
  const key = cacheKey(gh, now);
  const cached = await env.WX_CACHE.get(key);
  if (cached) return json(cached, 200, { "x-cache": "hit", "cache-control": "public, max-age=900" });
  if (!(await allowUpstream(req, env))) return tooMany();

  const privateKey = await importPrivateKey(env.WEATHERKIT_PRIVATE_KEY);
  const token = await weatherKitJwt(
    { teamId: env.WEATHERKIT_TEAM_ID, serviceId: env.WEATHERKIT_SERVICE_ID, keyId: env.WEATHERKIT_KEY_ID, privateKey },
    now,
  );
  const upstream = await fetch(weatherKitUrl(gh, now), { headers: { authorization: `Bearer ${token}` } });
  if (!upstream.ok) return json({ error: "upstream", status: upstream.status }, 502);

  const slimmed = slim(gh, await upstream.json(), now);
  // An empty forecast is unusable to the app; do not pin it in the cache for an hour.
  if (slimmed.hours.length === 0) return json({ error: "upstream", status: "empty" }, 502);
  const body = JSON.stringify(slimmed);
  // Entry is keyed by hour; keep it a little past the hour for slow clocks.
  await env.WX_CACHE.put(key, body, { expirationTtl: 3900 });
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

/**
 * Harmonic constants for the nearest NOAA station to a geohash-5 cell.
 * `{ station: null }` means no station within range (not an error), so the app
 * can stop asking. Constants change rarely: cached 30 days per cell.
 */
async function tide(gh: string, req: Request, env: Env): Promise<Response> {
  const key = `tide:${gh}`;
  const headers = { "cache-control": "public, max-age=86400" };
  const cached = await env.WX_CACHE.get(key);
  if (cached) return json(cached, 200, { ...headers, "x-cache": "hit" });
  if (!(await allowUpstream(req, env))) return tooMany();

  const list = await stations(env);
  if (!list) return json({ error: "upstream" }, 502);
  const { lat, lon } = decodeGeohash(gh);
  const near = nearestStation(list, lat, lon);

  let station = null;
  if (near) {
    const [h, d] = await Promise.all([fetch(harconUrl(near.station.id)), fetch(datumsUrl(near.station.id))]);
    if (!h.ok) return json({ error: "upstream", status: h.status }, 502);
    // Without datums the mean level falls back to 0 and every height is off;
    // fail now rather than cache a wrong station for 30 days.
    if (!d.ok) return json({ error: "upstream", status: d.status }, 502);
    station = toTideStation(near.station, await h.json(), await d.json());
  }
  const body = JSON.stringify({ gh, station, km: station && near ? Math.round(near.km * 10) / 10 : null });
  await env.WX_CACHE.put(key, body, { expirationTtl: 30 * DAY });
  return json(body, 200, { ...headers, "x-cache": "miss" });
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/health") return json({ ok: true });
    if (req.method !== "GET" || (url.pathname !== "/wx" && url.pathname !== "/tide")) {
      return json({ error: "not found" }, 404);
    }
    const gh = url.searchParams.get("gh");
    if (!isGeohash5(gh)) return json({ error: "gh must be a 5-character geohash" }, 400);
    try {
      return await (url.pathname === "/wx" ? weather(gh, req, env) : tide(gh, req, env));
    } catch {
      // Upstream reset, timed out or sent something that is not JSON.
      return json({ error: "upstream" }, 502);
    }
  },
};
