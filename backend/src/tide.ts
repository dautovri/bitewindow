// NOAA CO-OPS harmonic constants -> BiteCore `TideStation` JSON.
// Pure helpers; the worker route lives in index.ts.
//
// Response shapes follow the CO-OPS Metadata API (mdapi) docs. They have NOT
// been checked against live responses from this environment (host blocked).

const MDAPI = "https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi";

/** Constituents BiteCore's tide engine evaluates. Others are dropped. */
export const SUPPORTED = ["M2", "S2", "N2", "K2", "K1", "O1", "P1", "Q1"] as const;

/** Spots farther than this from every harmonic station get no tide. */
export const MAX_STATION_KM = 40;

export interface StationRef {
  id: string;
  name: string;
  lat: number;
  lon: number;
}

/** Matches `TideStation` in Sources/BiteCore/Tide.swift (Codable). */
export interface TideStationJSON {
  id: string;
  name: string;
  meanLevel: number;
  constituents: { name: string; amplitude: number; phase: number }[];
}

export const stationListUrl = () => `${MDAPI}/stations.json?type=harcon`;
export const harconUrl = (id: string) => `${MDAPI}/stations/${encodeURIComponent(id)}/harcon.json?units=metric`;
export const datumsUrl = (id: string) => `${MDAPI}/stations/${encodeURIComponent(id)}/datums.json?units=metric`;

export function parseStationList(raw: any): StationRef[] {
  return (raw?.stations ?? [])
    .filter((s: any) => s?.id != null && Number.isFinite(s?.lat) && Number.isFinite(s?.lng))
    .map((s: any) => ({ id: String(s.id), name: String(s.name ?? s.id), lat: s.lat, lon: s.lng }));
}

export function haversineKm(aLat: number, aLon: number, bLat: number, bLon: number): number {
  const r = Math.PI / 180;
  const dLat = (bLat - aLat) * r;
  const dLon = (bLon - aLon) * r;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(aLat * r) * Math.cos(bLat * r) * Math.sin(dLon / 2) ** 2;
  return 2 * 6371 * Math.asin(Math.min(1, Math.sqrt(h)));
}

export function nearestStation(
  stations: StationRef[],
  lat: number,
  lon: number,
  maxKm = MAX_STATION_KM,
): { station: StationRef; km: number } | null {
  let best: { station: StationRef; km: number } | null = null;
  for (const s of stations) {
    const km = haversineKm(lat, lon, s.lat, s.lon);
    if (km <= maxKm && (!best || km < best.km)) best = { station: s, km };
  }
  return best;
}

/**
 * Builds the engine's station record. Amplitudes are metres (units=metric),
 * phases are Greenwich epochs (`phase_GMT`), and `meanLevel` is MSL above
 * MLLW so heights read like a tide table. Returns null when no supported
 * constituent is present.
 */
export function toTideStation(ref: StationRef, harcon: any, datums: any): TideStationJSON | null {
  const wanted = new Set<string>(SUPPORTED);
  const constituents = (harcon?.HarmonicConstituents ?? [])
    .filter(
      (c: any) =>
        wanted.has(String(c?.name).toUpperCase()) && Number.isFinite(c?.amplitude) && Number.isFinite(c?.phase_GMT),
    )
    .map((c: any) => ({ name: String(c.name).toUpperCase(), amplitude: c.amplitude, phase: c.phase_GMT }));
  if (constituents.length === 0) return null;

  const datum = (n: string) => (datums?.datums ?? []).find((d: any) => d?.name === n)?.value;
  const msl = datum("MSL");
  const mllw = datum("MLLW");
  const meanLevel = Number.isFinite(msl) && Number.isFinite(mllw) ? msl - mllw : 0;

  return { id: ref.id, name: ref.name, meanLevel, constituents };
}
