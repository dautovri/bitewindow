import assert from "node:assert/strict";
import { test } from "node:test";
import { airHistoryUrls, dailyAirMeans, mergeHours, isWaterKind, lakeTemp, nearestSst, sstUrl } from "../src/water.ts";

test("water kind validation", () => {
  assert.equal(isWaterKind("salt"), true);
  assert.equal(isWaterKind("fresh"), true);
  assert.equal(isWaterKind("brackish"), false);
  assert.equal(isWaterKind(null), false);
});

test("SST box sits on the OISST grid around the cell", () => {
  const u = decodeURIComponent(sstUrl("u1x0e")); // Kiel Bight
  assert.match(u, /ncdcOisst21NrtAgg_LonPM180\.json\?sst\[\(last\)\]\[\(0\.0\)\]/);
  const nums = [...u.matchAll(/\((-?\d+\.\d{3})\)/g)].map((m) => Number(m[1]));
  assert.equal(nums.length, 4);
  for (const n of nums) assert.ok(Math.abs((Math.abs(n) % 0.25) - 0.125) < 1e-9, `${n} is on the grid`);
  assert.ok(nums[1] - nums[0] >= 1.25 && nums[3] - nums[2] >= 1.25);
});

test("nearest sea cell wins; land (null) and nonsense are skipped", () => {
  const raw = {
    table: {
      columnNames: ["time", "zlev", "latitude", "longitude", "sst"],
      rows: [
        ["2026-11-13T12:00:00Z", 0, 54.375, 10.125, null],
        ["2026-11-13T12:00:00Z", 0, 54.375, 10.625, 9.95],
        ["2026-11-13T12:00:00Z", 0, 54.625, 10.125, 9.87],
        ["2026-11-13T12:00:00Z", 0, 54.625, 10.375, 99],
      ],
    },
  };
  const sst = nearestSst(raw, 54.4, 10.2);
  assert.equal(sst?.tempC, 9.9);
  assert.equal(sst?.asOf, "2026-11-13T12:00:00Z");
  assert.ok(sst!.km < 40);
  assert.equal(nearestSst({ table: { columnNames: ["time", "latitude", "longitude", "sst"], rows: [["t", 1, 1, null]] } }, 1, 1), null);
  assert.equal(nearestSst({}, 1, 1), null);
});

test("air history is three 10-day requests covering the 30 days before now", () => {
  const urls = airHistoryUrls("u33dc", new Date("2026-11-10T15:20:30Z")).map((u) => new URL(u));
  assert.equal(urls.length, 3);
  assert.equal(urls[0].searchParams.get("hourlyStart"), "2026-10-11T15:00:00.000Z");
  assert.equal(urls[0].searchParams.get("hourlyEnd"), "2026-10-21T15:00:00.000Z");
  assert.equal(urls[1].searchParams.get("hourlyStart"), "2026-10-21T15:00:00.000Z");
  assert.equal(urls[2].searchParams.get("hourlyEnd"), "2026-11-10T15:00:00.000Z");
  assert.equal(mergeHours([{ forecastHourly: { hours: [1, 2] } }, {}, { forecastHourly: { hours: [3] } }]).forecastHourly.hours.length, 3);
});

const hoursAt = (day: string, temp: number, n = 24) =>
  Array.from({ length: n }, (_, h) => ({ forecastStart: `${day}T${String(h).padStart(2, "0")}:00:00Z`, temperature: temp }));

test("daily means are per UTC day, in order, without short days", () => {
  const raw = { forecastHourly: { hours: [...hoursAt("2026-11-02", 8), ...hoursAt("2026-11-01", 4), ...hoursAt("2026-11-03", 20, 5)] } };
  assert.deepEqual(dailyAirMeans(raw), [4, 8]);
  assert.deepEqual(dailyAirMeans({}), []);
});

test("lake model lags the air and needs two weeks", () => {
  assert.equal(lakeTemp(Array(13).fill(10)), null);
  assert.equal(lakeTemp(Array(30).fill(15)), 15);
  // A cold snap after a warm month: the water is still well above the air.
  const cooling = lakeTemp([...Array(25).fill(15), ...Array(5).fill(3)])!;
  assert.ok(cooling > 8 && cooling < 12, String(cooling));
  // Deep frost: open water stays at the floor.
  assert.equal(lakeTemp(Array(30).fill(-12)), 1);
});
