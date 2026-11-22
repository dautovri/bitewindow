// The forecast web pages' door into this worker: an RPC entrypoint reached only through a
// service binding from the `bitecurve-web` worker (web/), never from the internet. It runs the
// same cached lookups as the app routes under `webPolicy`: the web's own daily WeatherKit
// budget, no per-IP limit and the last good copy once that budget is spent. A cache hit (an
// app or the web asked within the hour or day) costs no WeatherKit call.

import { WorkerEntrypoint } from "cloudflare:workers";
import { isGeohash5 } from "./lib.ts";
import { isWaterKind } from "./water.ts";
import { tide, water, weather, webPolicy, type Env } from "./index.ts";

export interface WebAnswer {
  status: number;
  /** "hit", "miss" or "stale" (a saved copy served because the web budget is spent). */
  cache: string | null;
  data: unknown;
}

async function answer(res: Response): Promise<WebAnswer> {
  const text = await res.text();
  let data: unknown = null;
  try {
    data = JSON.parse(text);
  } catch {
    // Not JSON: keep the status, drop the body.
  }
  return { status: res.status, cache: res.headers.get("x-cache"), data };
}

const bad = (error: string): WebAnswer => ({ status: 400, cache: null, data: { error } });

const guarded = async (run: () => Promise<Response>): Promise<WebAnswer> => {
  try {
    return await answer(await run());
  } catch {
    return { status: 502, cache: null, data: { error: "upstream" } };
  }
};

export class WebForecast extends WorkerEntrypoint<Env> {
  async forecast(gh: string): Promise<WebAnswer> {
    if (!isGeohash5(gh)) return bad("gh");
    return guarded(() => weather(gh, this.env, webPolicy(this.env)));
  }

  async water(gh: string, kind: string): Promise<WebAnswer> {
    if (!isGeohash5(gh) || !isWaterKind(kind)) return bad("gh or kind");
    return guarded(() => water(gh, kind, this.env, webPolicy(this.env)));
  }

  async tide(gh: string): Promise<WebAnswer> {
    if (!isGeohash5(gh)) return bad("gh");
    return guarded(() => tide(gh, this.env, webPolicy(this.env)));
  }
}
