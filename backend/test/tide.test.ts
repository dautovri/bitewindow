import assert from "node:assert/strict";
import { test } from "node:test";
import { haversineKm, nearestStation, parseStationList, toTideStation } from "../src/tide.ts";
import worker from "../src/index.ts";

// Shapes per CO-OPS mdapi docs; values are illustrative, not real station data.
const stationList = {
  stations: [
    { id: "9414290", name: "San Francisco", lat: 37.8063, lng: -122.4659 },
    { id: "9414750", name: "Alameda", lat: 37.772, lng: -122.3 },
    { id: "bad", name: "No coords" },
  ],
};
const harcon = {
  HarmonicConstituents: [
    { number: 1, name: "M2", amplitude: 0.58, phase_GMT: 330.1, phase_local: 0, speed: 28.984104 },
    { number: 2, name: "S2", amplitude: 0.13, phase_GMT: 333.2, phase_local: 0, speed: 30 },
    { number: 4, name: "K1", amplitude: 0.37, phase_GMT: 105.9, phase_local: 0, speed: 15.041069 },
    { number: 7, name: "M4", amplitude: 0.01, phase_GMT: 10, phase_local: 0, speed: 57.96 },
    { number: 9, name: "O1", amplitude: null, phase_GMT: 90 },
  ],
};
const datums = { datums: [{ name: "MLLW", value: 1.2 }, { name: "MSL", value: 2.15 }] };

test("station list parsing drops entries without coordinates", () => {
  const list = parseStationList(stationList);
  assert.equal(list.length, 2);
  assert.deepEqual(list[0], { id: "9414290", name: "San Francisco", lat: 37.8063, lon: -122.4659 });
  assert.deepEqual(parseStationList({}), []);
});

test("haversine and nearest station within range", () => {
  assert.ok(Math.abs(haversineKm(0, 0, 0, 1) - 111.19) < 0.1);
  const list = parseStationList(stationList);
  assert.equal(nearestStation(list, 37.78, -122.31)?.station.id, "9414750");
  assert.equal(nearestStation(list, 37.8, -122.47)?.station.id, "9414290");
  assert.equal(nearestStation(list, 39.5, -122.4), null); // ~190 km inland
  assert.equal(nearestStation([], 0, 0), null);
});

test("harcon converts to engine TideStation", () => {
  const ref = { id: "9414290", name: "San Francisco", lat: 0, lon: 0 };
  const st = toTideStation(ref, harcon, datums)!;
  assert.equal(st.meanLevel.toFixed(2), "0.95");
  assert.deepEqual(
    st.constituents.map((c) => c.name),
    ["M2", "S2", "K1"],
  );
  assert.deepEqual(st.constituents[0], { name: "M2", amplitude: 0.58, phase: 330.1 });
  assert.equal(toTideStation(ref, harcon, null)!.meanLevel, 0);
  assert.equal(toTideStation(ref, { HarmonicConstituents: [] }, datums), null);
});

test("worker /tide: nearest station, no-station result, caching", async () => {
  const store = new Map<string, string>();
  const env = {
    WX_CACHE: { get: async (k: string) => store.get(k) ?? null, put: async (k: string, v: string) => void store.set(k, v) },
    WEATHERKIT_TEAM_ID: "T",
    WEATHERKIT_SERVICE_ID: "S",
    WEATHERKIT_KEY_ID: "K",
    WEATHERKIT_PRIVATE_KEY: "",
  };
  const calls: string[] = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (input: any) => {
    const u = String(input);
    calls.push(u);
    if (u.includes("stations.json")) return new Response(JSON.stringify(stationList));
    if (u.includes("/harcon.json")) return new Response(JSON.stringify(harcon));
    if (u.includes("/datums.json")) return new Response(JSON.stringify(datums));
    return new Response("", { status: 404 });
  }) as typeof fetch;
  try {
    assert.equal((await worker.fetch(new Request("https://x/tide?gh=zz"), env)).status, 400);

    // 9q8zh: cell centre near the Golden Gate.
    const miss = await worker.fetch(new Request("https://x/tide?gh=9q8zh"), env);
    assert.equal(miss.status, 200);
    assert.equal(miss.headers.get("x-cache"), "miss");
    const body = await miss.json();
    assert.equal(body.station.id, "9414290");
    assert.ok(body.km < 40);
    assert.equal(calls.length, 3);

    const hit = await worker.fetch(new Request("https://x/tide?gh=9q8zh"), env);
    assert.equal(hit.headers.get("x-cache"), "hit");
    assert.equal(calls.length, 3);

    // 9qdc4: Fresno, no station in range; station list comes from cache.
    const inland = await (await worker.fetch(new Request("https://x/tide?gh=9qdc4"), env)).json();
    assert.equal(inland.station, null);
    assert.equal(calls.length, 3);
  } finally {
    globalThis.fetch = realFetch;
  }
});
