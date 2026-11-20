import assert from "node:assert/strict";
import { test } from "node:test";
import { digest, isAngler, parseTrip, totals } from "../src/trip.ts";

const good = () => ({
  v: 1,
  angler: "0123456789abcdef",
  gh: "u1x0e",
  month: 11,
  water: "warmFreshwater",
  species: "northernPike",
  waterTempC: 11.4321,
  waterSource: "modelled",
  hasBank: true,
  hasTideStation: false,
  burst: false,
  slices: [
    { hours: 1, catches: 0, z: [0.12, -0.3, 0.45, -0.1, 0.6, 0] },
    { hours: 0.5, catches: 2, z: [0.85, -0.3, 0.4, -0.05, 0.2, 0] },
  ],
});

test("a valid trip is rebuilt from known fields only", () => {
  const trip = parseTrip({ ...good(), name: "Secret Lake", notes: "x" });
  assert.ok(trip);
  assert.deepEqual(Object.keys(trip).sort(), [...Object.keys(good()), "model", "planned"].sort());
  assert.equal(trip.v, 2);
  assert.equal(trip.model, "prior-1");
  assert.equal(trip.planned, null);
  assert.equal(trip.waterTempC, 11.432);
  assert.deepEqual(totals(trip), { hours: 1.5, catches: 2 });
});

test("anything off is refused", () => {
  const bad: Array<(t: any) => void> = [
    (t) => (t.v = 3),
    (t) => (t.model = "prior-1"),
    (t) => (t.planned = true),
    (t) => (t.angler = "0123456789ABCDEF"),
    (t) => (t.angler = "abc"),
    (t) => (t.gh = "u1x0"),
    (t) => (t.month = 13),
    (t) => (t.month = 1.5),
    (t) => (t.water = "pond"),
    (t) => (t.species = "shark"),
    (t) => (t.waterTempC = 80),
    (t) => (t.waterSource = null),
    (t) => (t.hasBank = "yes"),
    (t) => delete t.burst,
    (t) => (t.slices = []),
    (t) => (t.slices = Array.from({ length: 25 }, () => t.slices[0])),
    (t) => (t.slices[0].hours = 2),
    (t) => (t.slices[0].catches = -1),
    (t) => (t.slices[0].catches = 1.5),
    (t) => (t.slices[0].z = [0, 0, 0, 0, 0]),
    (t) => (t.slices[0].z[2] = Number.NaN),
    (t) => (t.slices = [{ hours: 0.1, catches: 0, z: [0, 0, 0, 0, 0, 0] }]),
  ];
  for (const [i, change] of bad.entries()) {
    const t = good();
    change(t);
    assert.equal(parseTrip(t), null, `case ${i}`);
  }
  for (const body of [null, "x", 3, [], undefined]) assert.equal(parseTrip(body), null);
});

test("no water temperature is allowed when both fields are missing", () => {
  const t: any = good();
  t.waterTempC = null;
  t.waterSource = null;
  assert.ok(parseTrip(t));
});

test("angler ids and digests", async () => {
  assert.equal(isAngler("0123456789abcdef"), true);
  assert.equal(isAngler("0123456789abcdeg"), false);
  assert.equal(await digest("a"), await digest("a"));
  assert.notEqual(await digest("a"), await digest("b"));
  assert.equal((await digest("a")).length, 64);
});

test("version 2 carries a known model and an optional planned answer", () => {
  const v2 = { ...good(), v: 2, model: "prior-1", planned: true };
  assert.deepEqual(parseTrip(v2)?.planned, true);
  const unanswered: any = { ...good(), v: 2, model: "prior-1" };
  assert.equal(parseTrip(unanswered)?.planned, null);
  assert.equal(parseTrip({ ...good(), v: 2 }), null);
  assert.equal(parseTrip({ ...good(), v: 2, model: "my-tracker-id" }), null);
  assert.equal(parseTrip({ ...good(), v: 2, model: "prior-1", planned: "yes" }), null);
});
