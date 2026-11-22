// The cron: refreshes the pages whose stored result is oldest, one at a time, through the
// BiteCurve backend's WebForecast entrypoint (backend/src/web.ts). Pages never call the backend
// when a visitor arrives, so traffic cannot spend WeatherKit calls; the web's own daily budget
// (budget.ts) caps what the cron can spend. Pages, the queue and the counter live in R2, whose
// free writes are plentiful, rather than KV (1,000 writes a day on the free plan, shared with
// the app backend).

import { MAX_COST, record, used } from "./budget.ts";
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

/** Text objects by key (an R2 bucket in the worker, a Map in tests). */
export interface Store {
  get(key: string): Promise<string | null>;
  put(key: string, value: string): Promise<void>;
}

/** A page older than this is not shown (WeatherKit terms §1.6: kept only briefly); an R2
 *  lifecycle rule deletes `pages/` objects after 3 days. Until then a failed refresh leaves
 *  the last page up. */
export const PAGE_MAX_AGE = 36 * 3600;
/** A forecast older than this is not scored into a page. */
const FORECAST_MAX_AGE = 24 * 3600;
const STATUS_KEY = "status.json";
export const pageKey = (path: string) => `pages${path}page.json`;

/** Per page: the last attempt (`at`, orders the queue) and the last success (`ok`, 0 for none). */
type Status = Record<string, { at: number; ok: number }>;

async function readStatus(kv: Store): Promise<Status> {
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

export type Outcome = "ok" | "no-weather" | "budget" | "failed";

/** WeatherKit calls an answer cost, from what the backend says it did. */
function cost(kind: "forecast" | "water", a: WebAnswer | null): number {
  if (!a || a.status !== 200 || a.cache !== "miss") return 0;
  if (kind === "forecast") return 1;
  return a.data?.source === "air" ? 3 : 0;
}

/** Fetches one water's inputs and stores its page. A page is never replaced by one without weather. */
export async function refreshOne(water: Water, backend: Backend, kv: Store, now: number, budget = 1500): Promise<Outcome> {
  const path = pathOf(water);
  let spent = 0;
  try {
    if ((await used(kv, now)) + MAX_COST > budget) return "budget";
    const kind = water.kind === "coast" ? "salt" : "fresh";
    // One after the other: no water or tide call is made when there is no forecast.
    const f = await backend.forecast(water.gh);
    spent += cost("forecast", f);
    const forecast: SlimForecast | null = f.status === 200 && Array.isArray(f.data?.hours) && f.data.hours.length > 0 ? f.data : null;
    const age = forecast ? now - Date.parse(forecast.fetchedAt) / 1000 : Infinity;
    if (!forecast || !(age <= FORECAST_MAX_AGE)) return "no-weather";
    const wt = await backend.water(water.gh, kind);
    spent += cost("water", wt);
    const td = water.kind === "coast" ? await backend.tide(water.gh) : null;
    const waterTemp: Inputs["waterTemp"] =
      wt.status === 200 && Number.isFinite(wt.data?.tempC) && (wt.data.source === "air" || wt.data.source === "sst")
        ? { c: wt.data.tempC, source: wt.data.source }
        : null;
    const station: TideStation | null = td && td.status === 200 && td.data?.station ? td.data.station : null;
    const page: PageData = computePage(water, path, { forecast, waterTemp, station }, now);
    await kv.put(pageKey(path), JSON.stringify(page));
    return "ok";
  } catch {
    return "failed";
  } finally {
    // Calls already made are counted even when a later step failed: Apple counts them too.
    try {
      await record(kv, now, spent);
    } catch {
      // A lost increment undercounts by at most MAX_COST.
    }
  }
}

/** One cron run. The picked pages move to the back of the queue before any work starts, so a
 *  run that is cut short (CPU limit, a thrown error) cannot leave the same page at the front. */
export async function refresh(backend: Backend, kv: Store, now: number, perRun: number, budget = 1500): Promise<Record<string, Outcome>> {
  const status = await readStatus(kv);
  const picked = pick(status, perRun);
  for (const w of picked) status[pathOf(w)] = { at: now, ok: status[pathOf(w)]?.ok ?? 0 };
  await kv.put(STATUS_KEY, JSON.stringify(status));
  const out: Record<string, Outcome> = {};
  for (const w of picked) {
    const result = await refreshOne(w, backend, kv, now, budget);
    out[pathOf(w)] = result;
    if (result === "ok") status[pathOf(w)].ok = now;
    // A failed page keeps its last good page up (until PAGE_MAX_AGE) and is tried again in its turn.
  }
  if (Object.values(out).includes("ok")) await kv.put(STATUS_KEY, JSON.stringify(status));
  return out;
}

export async function readPage(kv: Store, path: string, now: number): Promise<PageData | null> {
  const raw = await kv.get(pageKey(path));
  if (!raw) return null;
  try {
    const p = JSON.parse(raw) as PageData;
    return p.v === 1 && now - p.generatedAt <= PAGE_MAX_AGE ? p : null;
  } catch {
    return null;
  }
}

/** Paths that have a stored page, for the sitemap. */
export async function livePaths(kv: Store, now: number): Promise<Set<string>> {
  const status = await readStatus(kv);
  return new Set(Object.entries(status).filter(([, s]) => s.ok > 0 && now - s.ok <= PAGE_MAX_AGE).map(([p]) => p));
}
