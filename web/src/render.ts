// Server-rendered HTML for the forecast pages, in the site's guide-page style (/guides.css,
// /consent.js on apps.dautov.dev). US units first: these pages are for US waters.

import type { DayOut, PageData } from "./compute.ts";
import { localDate } from "./compute.ts";
import { DISPLAY_NAME } from "./engine/species.ts";
import { pathOf, STATE_NAMES, WATERS, type Water } from "./waters.ts";

export const SITE = "https://apps.dautov.dev";
export const APP_ID = "6834430484";
const PT = "127464313";
export const appStoreUrl = (ct: string) => `https://apps.apple.com/app/id${APP_ID}?pt=${PT}&ct=${ct}&mt=8`;
/** One campaign token per app: App Store Connect hides campaigns with fewer than 5 of anything. */
export const CAMPAIGN = "web-bitecurve";
/** Sister app. Its own token, counted in Houby's App Store analytics. */
export const HOUBY_URL = `https://apps.apple.com/app/id6829188074?pt=${PT}&ct=web-xpromo&mt=8`;

const APPLE_WEATHER_LEGAL = "https://developer.apple.com/weatherkit/data-source-attribution/";
const LOGO_LIGHT = "https://weatherkit.apple.com/assets/branding/en/Apple_Weather_blk_en_2X_090122.png";
const LOGO_DARK = "https://weatherkit.apple.com/assets/branding/en/Apple_Weather_wht_en_2X_090122.png";

export function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

// MARK: Formatting

const fmtCache = new Map<string, Intl.DateTimeFormat>();
function fmt(tz: string, opts: Intl.DateTimeFormatOptions): Intl.DateTimeFormat {
  const key = tz + JSON.stringify(opts);
  let f = fmtCache.get(key);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", { timeZone: tz, ...opts });
    fmtCache.set(key, f);
  }
  return f;
}

export const clock = (tz: string, t: number) => fmt(tz, { hour: "numeric", minute: "2-digit" }).format(new Date(t * 1000));
const zoneName = (tz: string, t: number) =>
  fmt(tz, { timeZoneName: "short" }).formatToParts(new Date(t * 1000)).find((p) => p.type === "timeZoneName")?.value ?? "";
const weekday = (tz: string, t: number) => fmt(tz, { weekday: "long", month: "short", day: "numeric" }).format(new Date(t * 1000));
const fahrenheit = (c: number) => Math.round((c * 9) / 5 + 32);
const mph = (kmh: number) => Math.round(kmh * 0.621371);
/** One decimal, without a "-0.0" for heights that round to zero. */
const feet = (m: number) => {
  const v = Math.round(m * 32.8084) / 10;
  return (v === 0 ? 0 : v).toFixed(1);
};

/** The app's wording and colour steps for the bite index (BiteScale in the app). */
export function biteLabel(index: number): { label: string; step: "strong" | "above" | "below" | "slow" } {
  const r = Math.round(index);
  if (r >= 65) return { label: "Strong bite", step: "strong" };
  if (r >= 50) return { label: "Above average", step: "above" };
  if (r >= 35) return { label: "Below average", step: "below" };
  return { label: "Slow", step: "slow" };
}

export function moonPhaseName(angle: number): string {
  const a = ((angle % 360) + 360) % 360;
  if (a < 11.25 || a >= 348.75) return "New moon";
  if (a < 78.75) return "Waxing crescent";
  if (a < 101.25) return "First quarter";
  if (a < 168.75) return "Waxing gibbous";
  if (a < 191.25) return "Full moon";
  if (a < 258.75) return "Waning gibbous";
  if (a < 281.25) return "Last quarter";
  return "Waning crescent";
}

function pressureWords(change: number): string {
  if (change <= -3) return "falling fast (a front may be coming)";
  if (change <= -1) return "falling";
  if (change >= 3) return "rising fast";
  if (change >= 1) return "rising";
  return "steady";
}

const ago = (now: number, t: number) => {
  const m = Math.max(0, Math.round((now - t) / 60));
  if (m < 2) return "just now";
  if (m < 60) return `${m} minute${m === 1 ? "" : "s"} ago`;
  const h = Math.round(m / 60);
  return `${h} hour${h === 1 ? "" : "s"} ago`;
};

const list = (tz: string, times: number[]) => (times.length ? times.map((t) => clock(tz, t)).join(", ") : "none");

// MARK: Page chrome

interface Head {
  title: string;
  description: string;
  canonical: string;
  robots?: string;
  jsonLd?: unknown;
}

function page(head: Head, body: string): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(head.title)}</title>
<meta name="description" content="${esc(head.description)}">
<link rel="canonical" href="${esc(head.canonical)}">
${head.robots ? `<meta name="robots" content="${esc(head.robots)}">\n` : ""}<meta name="apple-itunes-app" content="app-id=${APP_ID}, affiliate-data=pt=${PT}&amp;ct=${CAMPAIGN}">
<meta name="color-scheme" content="light dark">
<meta property="og:type" content="website">
<meta property="og:title" content="${esc(head.title)}">
<meta property="og:description" content="${esc(head.description)}">
<meta property="og:url" content="${esc(head.canonical)}">
<link rel="stylesheet" href="/guides.css">
<link rel="stylesheet" href="/bitecurve/fishing/forecast.css">
${head.jsonLd ? `<script type="application/ld+json">${JSON.stringify(head.jsonLd).replace(/</g, "\\u003c")}</script>\n` : ""}<script src="/consent.js" defer></script>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<nav class="top" aria-label="Site">
<div class="wrap">
<a href="/">Apps by Ruslan Dautov</a>
<a href="/bitecurve/fishing/">Fishing forecasts</a>
</div>
</nav>
<main id="main" class="wrap">
${body}
</main>
<footer class="site">
<div class="wrap">
<p><a href="/bitecurve/">BiteCurve support</a> · <a href="/bitecurve/privacy/">BiteCurve privacy</a> · <a href="${esc(HOUBY_URL)}">Houby mushroom forecast</a> · <a href="/">All apps</a></p>
<p>Impressum / Legal notice: Ruslan Dautov, Germany · <a href="mailto:dautovri@outlook.com">dautovri@outlook.com</a></p>
</div>
</footer>
</body>
</html>`;
}

function attribution(page: PageData | null): string {
  const tide = page?.station
    ? ` Tide predictions are computed from the harmonic constants of NOAA station ${esc(page.station.id)} (${esc(page.station.name)}).`
    : "";
  const sst = page?.waterTemp?.source === "sst" ? " Sea surface temperature: NOAA OISST via NOAA CoastWatch." : "";
  return `<section class="attribution" aria-label="Data sources">
<p><a href="${APPLE_WEATHER_LEGAL}" class="wk-mark"><picture><source srcset="${LOGO_DARK}" media="(prefers-color-scheme: dark)"><img src="${LOGO_LIGHT}" alt="Apple Weather" width="86" height="18"></picture></a> <a href="${APPLE_WEATHER_LEGAL}">Other data sources</a></p>
<p class="note">Forecast data comes from Apple Weather. The bite windows, the bite index and the day summaries are computed by BiteCurve from that data, so they are modified, not Apple's own forecast.${tide}${sst} Sun and moon times are computed by BiteCurve.</p>
<p class="note">YOUR USE OF THIS REAL TIME WEATHER GUIDANCE WEBSITE IS AT YOUR SOLE RISK. WEATHER DATA MAY NOT BE ACCURATE. Check official forecasts and local regulations before you go out on the water.</p>
</section>`;
}

const appCta = (h: string) => `<section class="app-cta">
<h2>${h}</h2>
<p>BiteCurve on iPhone shows the hourly bite curve, the 10-day outlook and the tide curve for your own spots, learns from the trips you log, and works offline with the last forecast.</p>
<p class="cta"><a class="btn" href="${esc(appStoreUrl(CAMPAIGN))}">Get BiteCurve on the App Store</a></p>
<p class="note">Foraging too? <a href="${esc(HOUBY_URL)}">Houby</a>, from the same developer, forecasts when mushrooms come up in the forests near you.</p>
</section>`;

// MARK: Water page

function dayLabel(tz: string, day: DayOut, today: string): string {
  const name = weekday(tz, day.start + 3600);
  if (day.date === today) return `Today, ${name}`;
  return `Tomorrow, ${name}`;
}

type Win = { start: number; end: number; index: number };

/** Today: the best window that has not ended, and the day's best if that one is over. */
function windowLine(tz: string, now: number, species: string, windows: Win[]): string {
  const best = windows[0];
  if (!best) return `<li><strong>${esc(species)}</strong>: no window</li>`;
  const ahead = windows.find((w) => w.end > now);
  if (!ahead) {
    return `<li class="win"><span class="pill done" aria-hidden="true">–</span><span><strong>${esc(species)}</strong>: the good windows are over for the day (the best was ${clock(tz, best.start)}–${clock(tz, best.end)}, ${Math.round(best.index)})</span></li>`;
  }
  const { label, step } = biteLabel(ahead.index);
  const lead = ahead === best ? "best window" : "best window left";
  // The note is worth it only when the missed window was clearly better.
  const missed = ahead === best || Math.round(best.index) <= Math.round(ahead.index) ? "" : ` <span class="note">(the day's best, ${clock(tz, best.start)}–${clock(tz, best.end)} at ${Math.round(best.index)}, is over)</span>`;
  const now_ = ahead.start <= now ? " <strong>now</strong>" : "";
  return `<li class="win"><span class="pill ${step}">${Math.round(ahead.index)}</span><span><strong>${esc(species)}</strong>: ${lead} ${clock(tz, ahead.start)}–${clock(tz, ahead.end)}${now_}, ${label.toLowerCase()}${missed}</span></li>`;
}

function dayTable(w: Water, d: DayOut, page: PageData, isToday: boolean): string {
  const tz = w.tz;
  const rows: Array<[string, string]> = [];
  rows.push(["Sunrise / sunset", `${d.sunrise ? clock(tz, d.sunrise) : "–"} / ${d.sunset ? clock(tz, d.sunset) : "–"}`]);
  rows.push(["Moonrise / moonset", `${d.moonrise ? clock(tz, d.moonrise) : "–"} / ${d.moonset ? clock(tz, d.moonset) : "–"}`]);
  rows.push(["Solunar major times", list(tz, d.majors)]);
  rows.push(["Solunar minor times", list(tz, d.minors)]);
  rows.push(["Moon", `${moonPhaseName(d.moonPhase)}, ${Math.round(d.moonIllumination * 100)}% lit`]);
  if (d.weather) {
    rows.push(["Air temperature", `${fahrenheit(d.weather.minC)}–${fahrenheit(d.weather.maxC)} °F (${Math.round(d.weather.minC)}–${Math.round(d.weather.maxC)} °C)`]);
    rows.push(["Strongest wind", `${mph(d.weather.maxWindKmh)} mph (${Math.round(d.weather.maxWindKmh)} km/h)`]);
    rows.push(["Pressure", pressureWords(d.weather.pressureChange)]);
  }
  if (isToday && page.waterTemp) {
    const how = page.waterTemp.source === "sst" ? "sea surface, NOAA satellite analysis" : "estimated from the last 30 days of air temperature";
    rows.push(["Water temperature", `about ${fahrenheit(page.waterTemp.c)} °F (${Math.round(page.waterTemp.c)} °C), ${how}`]);
  }
  if (d.tides && d.tides.length) {
    rows.push(["Tides", d.tides.map((x) => `${x.isHigh ? "High" : "Low"} ${clock(tz, x.time)} (${feet(x.heightM)} ft)`).join(", ")]);
  }
  return `<div class="table-wrap"><table>
<caption class="sr">Conditions</caption>
<tbody>
${rows.map(([k, v]) => `<tr><th scope="row">${esc(k)}</th><td>${esc(v)}</td></tr>`).join("\n")}
</tbody></table></div>`;
}

export function waterTitle(w: Water): string {
  return `${w.name} Fishing Forecast: Best Times Today (${w.state})`;
}

export function renderWater(w: Water, page: PageData, now: number): string {
  const tz = w.tz;
  const today = localDate(tz, now);
  const days = page.days.filter((d) => d.date >= today).slice(0, 2);
  const state = STATE_NAMES[w.state] ?? w.state;
  const speciesNames = w.species.filter((s) => s !== "general").map((s) => DISPLAY_NAME[s].toLowerCase());
  const target = speciesNames.length ? speciesNames.join(" and ") : "any fish";
  const factors = w.kind === "coast" ? "weather, sun, moon and tide" : "weather, sun and moon";
  const updated = page.weatherFetchedAt ? `Forecast updated ${ago(now, page.weatherFetchedAt)}.` : "No weather forecast in this update.";
  const oldWeather = page.weatherFetchedAt !== null && now - page.weatherFetchedAt > 18 * 3600;

  const sections = days.map((d) => `<section class="day">
<h2>${esc(dayLabel(tz, d, today))}</h2>
<ul class="wins">
${d.species.map((s) => windowLine(tz, now, DISPLAY_NAME[s.species], s.windows)).join("\n")}
</ul>
${dayTable(w, d, page, d.date === today)}
</section>`).join("\n");

  const nearby = WATERS.filter((o) => o.state === w.state && o !== w && o.kind === w.kind).slice(0, 12);
  const otherKind = WATERS.filter((o) => o.state === w.state && o.kind !== w.kind).slice(0, 6);

  const body = `<header class="hero">
<p class="eyebrow">Fishing forecast · ${esc(state)}</p>
<h1>${esc(w.name)} fishing forecast</h1>
<p class="lede">The best times to fish ${esc(w.name)} today and tomorrow for ${esc(target)}, worked out from the ${factors}. ${esc(updated)} Times are local (${esc(zoneName(tz, now))}).</p>
</header>
${oldWeather ? `<p class="stale" role="note">This forecast is older than usual: the next update has not arrived yet.</p>` : ""}
${days.length ? sections : `<p class="stale" role="note">Today's forecast for ${esc(w.name)} is being updated. Please check back in a few hours.</p>`}
<p class="note">The bite index runs from 0 to 100; 50 is an average day. A high number means conditions favour feeding, not that you will catch fish. Each window is two hours long.</p>
${appCta(`Your own spots on ${esc(w.name)}, hour by hour`)}
<h2>How this forecast works</h2>
<ul>
<li><strong>Light:</strong> fish feed most around sunrise and sunset, and more under cloud.</li>
<li><strong>Pressure:</strong> a falling barometer before a front tends to help; the bright, high-pressure day after a front tends to be slow.</li>
<li><strong>Wind:</strong> a breeze of around 10 mph helps most; from about 22 mph the wind term is at its worst.</li>
<li><strong>Moon:</strong> solunar major times (moon overhead or underfoot) and minor times (moonrise, moonset) add a little, more around new and full moon.</li>
${w.kind === "coast" ? "<li><strong>Tide:</strong> moving water fishes better than slack water, and spring tides better than neap tides.</li>" : "<li><strong>Water temperature:</strong> each species has a preferred range; the lake temperature is estimated from recent air temperature.</li>"}
</ul>
<p class="note">The weights come from published fishing studies where they exist and are estimates where they don't (scoring model ${esc(page.model)}). <a href="/bitecurve/">More about the bite index</a>.</p>
${nearby.length ? `<h2>More ${w.kind === "coast" ? "coastal spots" : "lakes"} in ${esc(state)}</h2>
<ul class="links">${nearby.map((o) => `<li><a href="${pathOf(o)}">${esc(o.name)}</a></li>`).join("")}</ul>` : ""}
${otherKind.length ? `<p>${w.kind === "coast" ? "Lakes" : "Coastal spots"} in ${esc(state)}: ${otherKind.map((o) => `<a href="${pathOf(o)}">${esc(o.name)}</a>`).join(", ")}.</p>` : ""}
${attribution(page)}`;

  const canonical = SITE + pathOf(w);
  return page_(w, canonical, body, days.length > 0);
}

function page_(w: Water, canonical: string, body: string, indexable: boolean): string {
  const state = STATE_NAMES[w.state] ?? w.state;
  return page(
    {
      title: waterTitle(w),
      description: `Best fishing times today and tomorrow at ${w.name}, ${state}: bite windows${w.kind === "coast" ? ", tides" : ""}, solunar times, sunrise and sunset, wind and pressure. Updated twice a day.`,
      canonical,
      robots: indexable ? undefined : "noindex",
      jsonLd: {
        "@context": "https://schema.org",
        "@type": "WebPage",
        name: waterTitle(w),
        url: canonical,
        about: { "@type": w.kind === "coast" ? "Place" : "LakeBodyOfWater", name: w.name, geo: { "@type": "GeoCoordinates", latitude: w.lat, longitude: w.lon } },
        isPartOf: { "@type": "WebSite", name: "Apps by Ruslan Dautov", url: SITE + "/" },
      },
    },
    body,
  );
}

/** No stored forecast yet (first fill, or every refresh failed for days): honest, not indexed. */
export function renderPending(w: Water): string {
  const body = `<header class="hero">
<p class="eyebrow">Fishing forecast · ${esc(STATE_NAMES[w.state] ?? w.state)}</p>
<h1>${esc(w.name)} fishing forecast</h1>
<p class="lede">The forecast for ${esc(w.name)} is being prepared. Please check back in a few hours.</p>
</header>
${appCta("Get the forecast for your own spots now")}
${attribution(null)}`;
  return page_(w, SITE + pathOf(w), body, false);
}

// MARK: Hubs

export function renderHub(statePick: string | null): string {
  const states = [...new Set(WATERS.map((w) => w.state))].sort((a, b) => (STATE_NAMES[a] ?? a).localeCompare(STATE_NAMES[b] ?? b));
  const shown = statePick ? states.filter((s) => s.toLowerCase() === statePick) : states;
  const blocks = shown.map((s) => {
    const lakes = WATERS.filter((w) => w.state === s && w.kind === "lake");
    const coasts = WATERS.filter((w) => w.state === s && w.kind === "coast");
    const li = (ws: Water[]) => ws.map((w) => `<li><a href="${pathOf(w)}">${esc(w.name)}</a></li>`).join("");
    return `<section>
<h2>${statePick ? "Waters" : `<a href="/bitecurve/fishing/${s.toLowerCase()}/">${esc(STATE_NAMES[s] ?? s)}</a>`}</h2>
${lakes.length ? `<h3>Lakes</h3><ul class="links">${li(lakes)}</ul>` : ""}
${coasts.length ? `<h3>Coast and tides</h3><ul class="links">${li(coasts)}</ul>` : ""}
</section>`;
  }).join("\n");
  const name = statePick ? STATE_NAMES[statePick.toUpperCase()] ?? statePick.toUpperCase() : null;
  const title = name ? `${name} Fishing Forecast: Best Times Today by Lake and Coast` : "Fishing Forecast by Lake and Coast: Best Times Today";
  const path = statePick ? `/bitecurve/fishing/${statePick}/` : "/bitecurve/fishing/";
  const body = `<header class="hero">
<p class="eyebrow">Fishing forecasts${name ? ` · ${esc(name)}` : ""}</p>
<h1>${name ? `${esc(name)} fishing forecast` : "Fishing forecast: best times today"}</h1>
<p class="lede">The best two-hour fishing windows for today and tomorrow, with solunar times, sunrise and sunset, wind and pressure${name ? "" : ", for lakes and coasts across the southern United States"}. Updated twice a day.</p>
</header>
${blocks}
${appCta("Your own spots, with the hourly bite curve")}
${attribution(null)}`;
  return page({ title, description: `${title}. Bite windows, solunar times, tides and weather, updated twice a day.`, canonical: SITE + path }, body);
}

export function sitemap(live: Set<string>): string {
  const urls = ["/bitecurve/fishing/", ...[...new Set(WATERS.map((w) => w.state.toLowerCase()))].map((s) => `/bitecurve/fishing/${s}/`)]
    .concat(WATERS.map(pathOf).filter((p) => live.has(p)));
  return `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls.map((u) => `<url><loc>${SITE}${u}</loc><changefreq>daily</changefreq></url>`).join("\n")}
</urlset>
`;
}

export const CSS = `.day{margin-top:1.5rem}
.day>h2{margin-top:1.2rem}
.wins{list-style:none;padding:0;margin:0 0 1rem}
.win{display:flex;gap:.75rem;align-items:flex-start;margin-bottom:.7rem}
.pill{flex:none;min-width:2.6rem;text-align:center;font-weight:700;font-variant-numeric:tabular-nums;border-radius:980px;padding:.15rem .6rem;color:#fff}
.pill.done{background:transparent;color:var(--muted);box-shadow:inset 0 0 0 1.5px var(--line)}
.pill.strong{background:#046A4E}.pill.above{background:#0062CC}.pill.below{background:#B54708}.pill.slow{background:#5E6B7C}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]) .pill{color:#041017}:root:not([data-theme="light"]) .pill.strong{background:#2EE59D}:root:not([data-theme="light"]) .pill.above{background:#52A8FF}:root:not([data-theme="light"]) .pill.below{background:#FB923C}:root:not([data-theme="light"]) .pill.slow{background:#8B9BB0}}
.stale{background:var(--card);border-left:4px solid var(--warn);border-radius:10px;padding:.8rem 1rem}
.app-cta{background:var(--card);border-radius:18px;padding:1.1rem 1.3rem;margin:2.2rem 0}
.app-cta h2{margin-top:0;font-size:1.3rem}
.links{columns:2;column-gap:1.5rem;padding-left:1.1rem}
@media (min-width:700px){.links{columns:3}}
.attribution{margin-top:3rem;border-top:1px solid var(--line);padding-top:1rem}
.wk-mark img{vertical-align:middle;height:18px;width:auto}
.sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
th[scope=row]{white-space:normal;width:38%}
`;
