# BiteWindow

Evidence-calibrated fishing bite-window prediction for iOS. Working name.

| Part | Path | What it is |
|---|---|---|
| Engine | `Sources/BiteCore` | Pure Swift: sun/moon ephemeris, solunar periods, bite-score terms, tide harmonics, Gamma–Poisson personalization, geohash |
| App | `App/` | SwiftUI + SwiftData + StoreKit 2 + CoreMotion + MapKit, iOS 17+, generated with XcodeGen |
| Backend | `backend/` | Cloudflare Worker: WeatherKit REST behind a geohash-5 / hourly KV cache; NOAA CO-OPS harmonic constants for the nearest tide station (`/tide`) |

## Status

| Component | State |
|---|---|
| `BiteCore` | 28 unit tests pass on Linux (Swift 6.0, container `swift:6.0`) |
| `backend` | 11 tests pass on Node 22; never deployed, never called the live WeatherKit or NOAA APIs (NOAA response shapes taken from docs) |
| `App` | Compiles in CI (`ios` job, macos-15, iOS Simulator, unsigned). Never run on a simulator or device; no UI tests |
| Tide engine | 8 constituents, tested for self-consistency only; not checked against NOAA predictions |
| Species thermal parameters, factor weights | Heuristic placeholders (see `docs/SCIENCE.md`) |

## Run

```sh
swift test                      # engine
cd backend && npm test          # worker
cd App && xcodegen generate && open BiteWindow.xcodeproj   # app (macOS, `brew install xcodegen`)
```

The app runs on synthetic sample weather until `BiteAPIBase` in `App/project.yml` points at a deployed worker.

## Setup still required

1. **WeatherKit**: enable the capability for a Services ID, create a key (`.p8`), fill `backend/wrangler.toml`, `wrangler kv namespace create WX_CACHE`, `wrangler secret put WEATHERKIT_PRIVATE_KEY`, `wrangler deploy`.
2. **WeatherKit terms**: confirm that serving cached WeatherKit data from your own server to your own app is permitted before launch. The whole backend design depends on it.
3. **App Store Connect**: subscription group "Pro" with `bitewindow.pro.annual` ($39.99, 7-day trial) and `bitewindow.pro.monthly` ($7.99); non-consumable `bitewindow.pro.lifetime` later. Enable Billing Grace Period. Enroll in the Small Business Program.
4. **StoreKit testing**: add a StoreKit configuration file in Xcode with the same product IDs.
5. **iCloud sync**: add the iCloud/CloudKit capability; the SwiftData schema is already CloudKit-compatible.

## Free vs Pro (as implemented)

| | Free | Pro |
|---|---|---|
| Trip log incl. zero-catch trips | yes | yes |
| Saved spots | 3 | unlimited |
| Daily best window + index | today, tomorrow | 10 days |
| Hourly bite curve | no | yes |
| Tide height curve (saltwater) | no | yes |
| Expected catch in the best window, scaled by your log | no | yes |

## Personal model and barometer (as implemented)

- Ending a trip stores `Trip.expectedCatch`: `0.5 fish/h × ∫ index/50 dt` over the trip, from the real forecast. Sample weather, no spot, or no data gives the neutral value (`0.5 × hours`).
- `Spot.catchMultiplier` is the Gamma–Poisson posterior over that spot's finished trips of 24 h or less. Pro shows `expected catch in window × multiplier`. The bite index and the window timing do not change.
- The 0.5 fish/h baseline is a placeholder. The multiplier corrects it per spot once trips accumulate.
- While a trip is active at a spot, phone barometer samples taken since the trip started replace the forecast pressure trace over the sampled span (`Barometry.fuse`: median offset removed, readings more than 2 hPa off dropped, at least 3 readings over 30 minutes).
- The "live pressure" toggle persists across launches (`UserDefaults`); samples older than 72 h are deleted at launch.

## Tides (as implemented)

- `GET /tide?gh=<geohash-5>` returns `{ gh, station, km }`, `station` in the engine's `TideStation` JSON (or null). Station list cached 7 days, per-cell result 30 days.
- Saltwater spots (inshore, offshore) attach the station to `SpotContext.tide`, which turns on the tide term, and list the day's high/low times. Free and Pro both see tide times.

## Not built yet

- Personal model: only the per-spot catch-rate scale is fitted (`CatchRateMultiplier`). Factor weights are not refitted from the log.
- Tides: US (NOAA) stations only; within 40 km of the spot; no validation against NOAA published predictions.
- Bathymetry overlays, offline map packs, push alerts, CoreML model, App Store Server Notifications, backend rate limiting / App Attest.
