import { cacheKey, importPrivateKey, isGeohash5, slim, weatherKitJwt, weatherKitUrl } from "./lib.ts";

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
}

const json = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
  new Response(typeof body === "string" ? body : JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...extra },
  });

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/health") return json({ ok: true });
    if (req.method !== "GET" || url.pathname !== "/wx") return json({ error: "not found" }, 404);

    const gh = url.searchParams.get("gh");
    if (!isGeohash5(gh)) return json({ error: "gh must be a 5-character geohash" }, 400);

    const now = new Date();
    const key = cacheKey(gh, now);
    const cached = await env.WX_CACHE.get(key);
    if (cached) return json(cached, 200, { "x-cache": "hit", "cache-control": "public, max-age=900" });

    const privateKey = await importPrivateKey(env.WEATHERKIT_PRIVATE_KEY);
    const token = await weatherKitJwt(
      { teamId: env.WEATHERKIT_TEAM_ID, serviceId: env.WEATHERKIT_SERVICE_ID, keyId: env.WEATHERKIT_KEY_ID, privateKey },
      now,
    );
    const upstream = await fetch(weatherKitUrl(gh, now), { headers: { authorization: `Bearer ${token}` } });
    if (!upstream.ok) return json({ error: "upstream", status: upstream.status }, 502);

    const body = JSON.stringify(slim(gh, await upstream.json(), now));
    // Entry is keyed by hour; keep it a little past the hour for slow clocks.
    await env.WX_CACHE.put(key, body, { expirationTtl: 3900 });
    return json(body, 200, { "x-cache": "miss", "cache-control": "public, max-age=900" });
  },
};
