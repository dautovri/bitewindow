/**
 * Opt-in trip sharing. The app sends a finished trip only after the angler switched sharing
 * on: no name, account, exact place, date or notes. What arrives is checked field by field and
 * rebuilt from the known fields, so nothing else can ride along into storage.
 */
import { isGeohash5 } from "./lib.ts";

export const WATERS = ["warmFreshwater", "coldFreshwater", "inshoreSalt", "offshore"] as const;
export const SPECIES = [
  "largemouthBass", "walleye", "northernPike", "rainbowTrout", "crucianCarp", "commonCarp", "europeanPerch",
  "commonBream", "general", "europeanSeaBass", "atlanticCod", "atlanticMackerel", "seaTrout", "flounder",
  "stripedBass", "redDrum",
] as const;
export const WATER_SOURCES = ["measured", "satellite", "modelled"] as const;

/** Largest request body accepted, bytes. A 24-hour trip is about 3 kB. */
export const MAX_BODY = 8192;
export const MAX_SLICES = 24;

export interface Slice {
  hours: number;
  catches: number;
  /** Unweighted factor scores: light, thermal, wind, pressure, solunar, tide. */
  z: number[];
}

export interface SharedTrip {
  v: 1;
  /** Random id made on the phone, replaced whenever the angler deletes what they shared. */
  angler: string;
  /** Geohash-5 cell (about 5 km), never the spot itself. */
  gh: string;
  month: number;
  water: string;
  species: string;
  waterTempC: number | null;
  waterSource: string | null;
  hasBank: boolean;
  hasTideStation: boolean;
  /** Every fish was logged within two minutes: probably entered at the end, not as caught. */
  burst: boolean;
  slices: Slice[];
}

export const isAngler = (s: unknown): s is string => typeof s === "string" && /^[0-9a-f]{16}$/.test(s);

const num = (x: unknown, lo: number, hi: number): x is number =>
  typeof x === "number" && Number.isFinite(x) && x >= lo && x <= hi;
const round = (x: number) => Math.round(x * 1000) / 1000;

/** The trip rebuilt from its known fields, or null when anything is off. */
export function parseTrip(body: unknown): SharedTrip | null {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return null;
  const b = body as Record<string, unknown>;
  if (b.v !== 1 || !isAngler(b.angler) || !isGeohash5(b.gh as string | null)) return null;
  if (!num(b.month, 1, 12) || !Number.isInteger(b.month)) return null;
  if (!(WATERS as readonly unknown[]).includes(b.water) || !(SPECIES as readonly unknown[]).includes(b.species)) return null;
  const temp = b.waterTempC ?? null;
  if (temp !== null && !num(temp, -2, 40)) return null;
  const source = b.waterSource ?? null;
  if (source !== null && !(WATER_SOURCES as readonly unknown[]).includes(source)) return null;
  if ((temp === null) !== (source === null)) return null;
  if (typeof b.hasBank !== "boolean" || typeof b.hasTideStation !== "boolean" || typeof b.burst !== "boolean") return null;
  if (!Array.isArray(b.slices) || b.slices.length < 1 || b.slices.length > MAX_SLICES) return null;

  const slices: Slice[] = [];
  let hours = 0;
  let catches = 0;
  for (const raw of b.slices) {
    if (typeof raw !== "object" || raw === null) return null;
    const s = raw as Record<string, unknown>;
    if (!num(s.hours, 1e-6, 1.001) || !num(s.catches, 0, 200) || !Number.isInteger(s.catches)) return null;
    if (!Array.isArray(s.z) || s.z.length !== 6 || !s.z.every((z) => num(z, -2, 2))) return null;
    hours += s.hours;
    catches += s.catches;
    slices.push({ hours: round(s.hours), catches: s.catches, z: (s.z as number[]).map(round) });
  }
  // Under a quarter of an hour is a mis-tap; a full day is a trip nobody ended.
  if (hours < 0.25 || hours > 24.01 || catches > 200) return null;

  return {
    v: 1,
    angler: b.angler,
    gh: b.gh as string,
    month: b.month,
    water: b.water as string,
    species: b.species as string,
    waterTempC: temp === null ? null : round(temp as number),
    waterSource: source as string | null,
    hasBank: b.hasBank,
    hasTideStation: b.hasTideStation,
    burst: b.burst,
    slices,
  };
}

export const totals = (trip: SharedTrip) => ({
  hours: round(trip.slices.reduce((sum, s) => sum + s.hours, 0)),
  catches: trip.slices.reduce((sum, s) => sum + s.catches, 0),
});

/** Hex SHA-256 of the stored payload: the same trip sent twice (a retry) is stored once. */
export async function digest(payload: string): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(payload));
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
