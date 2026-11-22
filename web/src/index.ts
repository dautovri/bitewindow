// bitecurve-web: free fishing forecast pages on apps.dautov.dev/bitecurve/fishing/*.
// Requests only read KV (results the cron stored); the cron alone talks to the BiteCurve
// backend, through its WebForecast entrypoint and under the web's own WeatherKit budget.

import { livePaths, readPage, refresh, type Backend, type PageKV } from "./refresh.ts";
import { CSS, renderHub, renderPending, renderWater, sitemap } from "./render.ts";
import { findWater, WATERS } from "./waters.ts";

export interface Env {
  BACKEND: Backend;
  PAGES: PageKV;
  /** Pages refreshed per cron run (default 1: fits the 10 ms CPU limit of the free plan). */
  PAGES_PER_RUN?: string;
}

const CSP = [
  "default-src 'self'",
  "script-src 'self' https://www.googletagmanager.com",
  "style-src 'self'",
  "img-src 'self' https://weatherkit.apple.com https://*.google-analytics.com https://*.googletagmanager.com",
  "connect-src 'self' https://*.google-analytics.com https://*.analytics.google.com https://*.googletagmanager.com",
  "frame-ancestors 'none'",
  "base-uri 'none'",
  "form-action 'none'",
].join("; ");

const SECURITY = {
  "content-security-policy": CSP,
  "strict-transport-security": "max-age=31536000; includeSubDomains",
  "x-content-type-options": "nosniff",
  "referrer-policy": "strict-origin-when-cross-origin",
  "x-frame-options": "DENY",
};

const html = (body: string, status = 200, extra: Record<string, string> = {}) =>
  new Response(body, {
    status,
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=600", ...SECURITY, ...extra },
  });

const notFound = () =>
  new Response("Not found", { status: 404, headers: { "content-type": "text/plain; charset=utf-8", ...SECURITY } });

export async function handle(req: Request, env: Env, now = Date.now() / 1000): Promise<Response> {
  const url = new URL(req.url);
  if (req.method !== "GET" && req.method !== "HEAD") return new Response(null, { status: 405, headers: { allow: "GET, HEAD", ...SECURITY } });
  const path = url.pathname;
  const base = "/bitecurve/fishing";
  if (path === base) return Response.redirect(`${url.origin}${base}/`, 301);
  if (!path.startsWith(`${base}/`)) return notFound();
  const rest = path.slice(base.length + 1);

  if (rest === "") return html(renderHub(null));
  if (rest === "forecast.css") {
    return new Response(CSS, { headers: { "content-type": "text/css; charset=utf-8", "cache-control": "public, max-age=86400", ...SECURITY } });
  }
  if (rest === "sitemap.xml") {
    return new Response(sitemap(await livePaths(env.PAGES, now)), {
      headers: { "content-type": "application/xml; charset=utf-8", "cache-control": "public, max-age=3600", ...SECURITY },
    });
  }

  const parts = rest.split("/");
  // /{state}/ and /{state}/{water}/, each with the trailing slash; without it, redirect.
  if (parts.length === 1 || (parts.length === 2 && parts[1] !== "" && !rest.endsWith("/"))) {
    const target = `${base}/${rest}/`;
    const known = parts.length === 1 ? WATERS.some((w) => w.state.toLowerCase() === parts[0]) : !!findWater(parts[0], parts[1]);
    return known ? Response.redirect(url.origin + target, 301) : notFound();
  }
  if (parts.length === 2 && parts[1] === "") {
    return WATERS.some((w) => w.state.toLowerCase() === parts[0]) ? html(renderHub(parts[0])) : notFound();
  }
  if (parts.length === 3 && parts[2] === "") {
    const water = findWater(parts[0], parts[1]);
    if (!water) return notFound();
    const page = await readPage(env.PAGES, path);
    // No stored forecast: 503 so search engines come back later instead of indexing an empty page.
    if (!page) return html(renderPending(water), 503, { "retry-after": "3600", "cache-control": "no-store" });
    return html(renderWater(water, page, now));
  }
  return notFound();
}

export default {
  fetch: (req: Request, env: Env) => handle(req, env),
  async scheduled(_event: unknown, env: Env, ctx: { waitUntil(p: Promise<unknown>): void }) {
    const perRun = Math.max(1, Math.min(10, Number(env.PAGES_PER_RUN) || 1));
    ctx.waitUntil(refresh(env.BACKEND, env.PAGES, Date.now() / 1000, perRun));
  },
};
