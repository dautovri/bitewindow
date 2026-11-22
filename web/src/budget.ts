// The web pages' own daily WeatherKit budget (decided 2026-11-22: 1,500 calls a day), kept in
// R2 next to the pages. The cron reserves the most a refresh can cost before it asks the
// backend, then records what the answers say it cost ("miss" = one call for a forecast, three
// for a lake's modelled water temperature). The cron runs one refresh at a time, so the
// read-then-write counter has no concurrent writers.

import type { Store } from "./refresh.ts";

export const DEFAULT_WEB_BUDGET = 1500;
/** The most one refresh can cost: a forecast miss plus the air model for the water. */
export const MAX_COST = 4;

export const budgetKey = (now: number) => `budget/${new Date(now * 1000).toISOString().slice(0, 10)}`;

export function dailyBudget(raw: string | undefined): number {
  const n = Number(raw);
  return raw !== undefined && raw.trim() !== "" && Number.isInteger(n) && n >= 0 ? n : DEFAULT_WEB_BUDGET;
}

export async function used(store: Store, now: number): Promise<number> {
  return Number(await store.get(budgetKey(now))) || 0;
}

export async function record(store: Store, now: number, cost: number): Promise<void> {
  if (cost <= 0) return;
  await store.put(budgetKey(now), String((await used(store, now)) + cost));
}
