// Account-wide daily WeatherKit budget, shared by every client of this worker.
//
// The WeatherKit allowance (500,000 calls a month) belongs to the developer account and is
// shared with other apps (Houby uses about 20,000 a month). The per-IP limiter in index.ts
// stops one address from draining it; this cap stops many addresses together from doing so.
// The default, 5,000 calls a day, is about 150,000 a month: well under the allowance with
// room for the other apps.
//
// Approximation: KV has no atomic increment, is eventually consistent between Cloudflare
// locations (a write can take up to about a minute to be seen elsewhere, and reads are cached
// at the edge for about as long), and allows about one write per second to the same key. The
// counter is a read-then-write, last writer wins: requests that race, or run in different
// locations, can read the same count and overwrite each other, and a write refused by the
// per-key limit is dropped (the request still goes ahead). So the counter undercounts under
// concurrent load, by more the more traffic there is. At this app's traffic (cache misses are
// one per cell per hour) it is a guard against runaway use, not an exact meter. An exact
// counter needs a Durable Object (phase 2).

export const DEFAULT_DAILY_BUDGET = 5000;

export interface CounterKV {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, opts?: { expirationTtl?: number }): Promise<void>;
}

/** The configured daily budget; the default when the variable is missing or not a whole number >= 0. */
export function dailyBudget(raw: string | undefined, fallback = DEFAULT_DAILY_BUDGET): number {
  if (raw === undefined || raw.trim() === "") return fallback;
  const n = Number(raw);
  return Number.isInteger(n) && n >= 0 ? n : fallback;
}

/** The forecast web pages' own daily share (decided 2026-11-22), counted apart from the apps'. */
export const DEFAULT_WEB_DAILY_BUDGET = 1500;

/** One counter per UTC day; the web pages count under their own prefix. */
export function budgetKey(now: Date, prefix = "wkbudget"): string {
  return `${prefix}:${now.toISOString().slice(0, 10)}`;
}

/** Seconds until the next UTC midnight, when the budget starts again. */
export function secondsToReset(now: Date): number {
  const next = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
  return Math.max(1, Math.ceil((next - now.getTime()) / 1000));
}

/**
 * Reserves `cost` WeatherKit calls from today's budget. True when they fit (and are now
 * counted), false when today's budget is spent. Counted before the calls are made, so a call
 * that fails upstream still counts: Apple counts it too.
 */
export async function spend(kv: CounterKV, budget: number, cost: number, now: Date, prefix = "wkbudget"): Promise<boolean> {
  const key = budgetKey(now, prefix);
  const used = Number(await kv.get(key)) || 0;
  if (used + cost > budget) return false;
  try {
    // Kept two days so the counter outlives its day in every location.
    await kv.put(key, String(used + cost), { expirationTtl: 2 * 86_400 });
  } catch {
    // KV refuses more than about one write a second to a key: losing one increment is better
    // than failing the request (see the note at the top).
  }
  return true;
}
