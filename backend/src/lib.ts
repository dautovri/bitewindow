// Pure helpers for the weather cache worker. No Cloudflare bindings here so
// they run under `node --test`.

const ALPHABET = "0123456789bcdefghjkmnpqrstuvwxyz";

export function isGeohash5(s: string | null): s is string {
  return typeof s === "string" && s.length === 5 && [...s].every((c) => ALPHABET.includes(c));
}

/** Centre of a geohash cell. */
export function decodeGeohash(hash: string): { lat: number; lon: number } {
  let lat: [number, number] = [-90, 90];
  let lon: [number, number] = [-180, 180];
  let even = true;
  for (const c of hash) {
    const idx = ALPHABET.indexOf(c);
    if (idx < 0) throw new Error("invalid geohash");
    for (let shift = 4; shift >= 0; shift--) {
      const on = ((idx >> shift) & 1) === 1;
      const r = even ? lon : lat;
      const mid = (r[0] + r[1]) / 2;
      if (on) r[0] = mid;
      else r[1] = mid;
      even = !even;
    }
  }
  return { lat: (lat[0] + lat[1]) / 2, lon: (lon[0] + lon[1]) / 2 };
}

/** One cache entry per cell per UTC hour. */
export function cacheKey(gh: string, now: Date): string {
  return `wx:${gh}:${now.toISOString().slice(0, 13)}`;
}

export function weatherKitUrl(gh: string, now: Date): string {
  const { lat, lon } = decodeGeohash(gh);
  const hour = new Date(Math.floor(now.getTime() / 3_600_000) * 3_600_000);
  const start = new Date(hour.getTime() - 48 * 3_600_000); // history for pressure deltas
  const end = new Date(hour.getTime() + 240 * 3_600_000);
  const q = new URLSearchParams({
    dataSets: "forecastHourly",
    hourlyStart: start.toISOString(),
    hourlyEnd: end.toISOString(),
  });
  return `https://weatherkit.apple.com/api/v1/weather/en/${lat.toFixed(4)}/${lon.toFixed(4)}?${q}`;
}

export interface SlimHour {
  t: string; // ISO start of hour
  p: number; // sea-level pressure, hPa
  c: number; // cloud cover 0..1
  ws: number; // wind speed, km/h
  wd: number | null; // wind FROM bearing, degrees
  ta: number; // air temperature, °C
}

export interface SlimForecast {
  gh: string;
  fetchedAt: string;
  hours: SlimHour[];
}

/** Keeps only the fields the scoring engine uses. */
export function slim(gh: string, raw: any, now: Date): SlimForecast {
  const hours: SlimHour[] = (raw?.forecastHourly?.hours ?? [])
    .filter((h: any) => typeof h?.forecastStart === "string" && Number.isFinite(h?.pressure))
    .map((h: any) => ({
      t: h.forecastStart,
      p: h.pressure,
      c: Number.isFinite(h.cloudCover) ? h.cloudCover : 0.5,
      ws: Number.isFinite(h.windSpeed) ? h.windSpeed : 0,
      wd: Number.isFinite(h.windDirection) ? h.windDirection : null,
      ta: Number.isFinite(h.temperature) ? h.temperature : 15,
    }));
  return { gh, fetchedAt: now.toISOString(), hours };
}

function b64url(data: ArrayBuffer | Uint8Array | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function pemToPkcs8(pem: string): Uint8Array {
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

export interface WeatherKitCredentials {
  teamId: string;
  serviceId: string;
  keyId: string;
  privateKey: CryptoKey;
}

export async function importPrivateKey(pem: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("pkcs8", pemToPkcs8(pem), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

/** ES256 developer token for the WeatherKit REST API. */
export async function weatherKitJwt(cred: WeatherKitCredentials, now: Date, ttlSeconds = 1800): Promise<string> {
  const iat = Math.floor(now.getTime() / 1000);
  const header = { alg: "ES256", kid: cred.keyId, id: `${cred.teamId}.${cred.serviceId}` };
  const claims = { iss: cred.teamId, sub: cred.serviceId, iat, exp: iat + ttlSeconds };
  const input = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claims))}`;
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, cred.privateKey, new TextEncoder().encode(input));
  return `${input}.${b64url(sig)}`;
}
