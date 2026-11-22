// The cron: refreshes the pages whose stored result is oldest, a few per run, through the
// BiteCurve backend's WebForecast entrypoint (backend/src/web.ts). Pages never call the backend
// when a visitor arrives, so traffic cannot spend WeatherKit calls; the web's own daily budget
// in the backend caps what the cron can spend.

import { computePage, type Inputs, type PageData, type SlimForecast } from "./compute.ts";
import type { TideStation } from "./engine/tide.ts";
import { pathOf, WATERS, type Water } from "./waters.ts";

export interface WebAnswer {
  status: number;
  cache: string | null;
  data: any;
}

/** The backend's RPC entrypoint, through the service binding. */
export interface Backend {
  forecast(gh: string): Promise<WebAnswer>;
  water(gh: string, kind: string): Promise<WebAnswer>;
  tide(gh: string): Promise<WebAnswer>;
}

export interface PageKV {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, opts?: { expirationTtl?: number }): Promise<void>;
}

/** A stored page expires after this; until then a failed refresh leaves the last one up. */
export const PAGE_TTL = 3 * 86400;
const STATUS_KEY = "status";
export const pageKey = (path: string) => `page:${path}`;

/** Per page: the last attempt (`at`, orders the queue) and the last success (`ok`, 0 for none). */
type Status = Record<string, { at: number; ok: number }>;

async function readStatus(kv: PageKV): Promise<Status> {
  try {
    const raw = JSON.parse((await kv.get(STATUS_KEY)) ?? "{}");
    return raw && typeof raw === "object" ? raw : {};
  } catch {
    return {};
  }
}

/** The pages to refresh now: never refreshed first, then the oldest. */
export function pick(status: Status, count: number, waters: Water[] = WATERS): Water[] {
  return [...waters]
    .map((w, i) => ({ w, i, at: status[pathOf(w)]?.at ?? 0 }))
    .sort((a, b) => a.at - b.at || a.i - b.i)
    .slice(0, count)
    .map((x) => x.w);
}

export type Outcome = "ok" | "no-weather" | "failed";

/** Fetches one water's inputs and stores its page. A page is never replaced by one without weather. */
export async function refreshOne(water: Water, backend: Backend, kv: PageKV, now: number): Promise<Outcome> {
  const path = pathOf(water);
  try {
    const kind = water.kind === "coast" ? "salt" : "fresh";
    const [f, wt, td] = await Promise.all([
      backend.forecast(water.gh),
      backend.water(water.gh, kind),
      water.kind === "coast" ? backend.tide(water.gh) : Promise.resolve(null),
    ]);
    const forecast: SlimForecast | null = f.status === 200 && Array.isArray(f.data?.hours) && f.data.hours.length > 0 ? f.data : null;
    if (!forecast) return "no-weather";
    const waterTemp: Inputs["waterTemp"] =
      wt.status === 200 && Number.isFinite(wt.data?.tempC) && (wt.data.source === "air" || wt.data.source === "sst")
        ? { c: wt.data.tempC, source: wt.data.source }
        : null;
    const station: TideStation | null = td && td.status === 200 && td.data?.station ? td.data.station : null;
    const page: PageData = computePage(water, path, { forecast, waterTemp, station }, now);
    await kv.put(pageKey(path), JSON.stringify(page), { expirationTtl: PAGE_TTL });
    return "ok";
  } catch {
    return "failed";
  }
}

/** One cron run. Pages that failed are tried again on the next run, after the others. */
export async function refresh(backend: Backend, kv: PageKV, now: number, perRun: number): Promise<Record<string, Outcome>> {
  const status = await readStatus(kv);
  const out: Record<string, Outcome> = {};
  for (const w of pick(status, perRun)) {
    const result = await refreshOne(w, backend, kv, now);
    out[pathOf(w)] = result;
    // A failure moves the page to the back of the queue too, so one bad cell cannot block the
    // rest; its last good page stays up (until PAGE_TTL) and it is tried again in its turn.
    const ok = result === "ok" ? now : (status[pathOf(w)]?.ok ?? 0);
    status[pathOf(w)] = { at: now, ok };
  }
  await kv.put(STATUS_KEY, JSON.stringify(status));
  return out;
}

export async function readPage(kv: PageKV, path: string): Promise<PageData | null> {
  const raw = await kv.get(pageKey(path));
  if (!raw) return null;
  try {
    const p = JSON.parse(raw) as PageData;
    return p.v === 1 ? p : null;
  } catch {
    return null;
  }
}

/** Paths that have a stored page, for the sitemap. */
export async function livePaths(kv: PageKV, now: number): Promise<Set<string>> {
  const status = await readStatus(kv);
  return new Set(Object.entries(status).filter(([, s]) => now - s.ok < PAGE_TTL).map(([p]) => p));
}
