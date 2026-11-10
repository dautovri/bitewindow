# BiteWindow

Evidence-calibrated fishing bite-window prediction for iOS. Working name.

| Part | Path | What it is |
|---|---|---|
| Engine | `Sources/BiteCore` | Pure Swift: sun/moon ephemeris, solunar periods, bite-score terms, tide harmonics, Gamma–Poisson personalization, geohash |
| App | `App/` | SwiftUI + SwiftData + StoreKit 2 + CoreMotion + MapKit, iOS 17+, generated with XcodeGen |
| Backend | `backend/` | Cloudflare Worker: WeatherKit REST behind a geohash-5 / hourly KV cache |

## Status

| Component | State |
|---|---|
| `BiteCore` | 22 unit tests passed on Linux (Swift 6.0.3); `Personal.swift` and its 4 tests were written without a Swift toolchain and have never been compiled or run |
| `backend` | 7 tests pass on Node 22; never deployed, never called the live WeatherKit API |
| `App` | **Never compiled.** Written without Xcode; the `ios` CI job is its first build |
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
| Expected catch in the best window, scaled by your log | no | yes |

## Personal model and barometer (as implemented)

- Ending a trip stores `Trip.expectedCatch`: `0.5 fish/h × ∫ index/50 dt` over the trip, from the real forecast. Sample weather, no spot, or no data gives the neutral value (`0.5 × hours`).
- `Spot.catchMultiplier` is the Gamma–Poisson posterior over that spot's finished trips of 24 h or less. Pro shows `expected catch in window × multiplier`. The bite index and the window timing do not change.
- The 0.5 fish/h baseline is a placeholder. The multiplier corrects it per spot once trips accumulate.
- While a trip is active at a spot, phone barometer samples taken since the trip started replace the forecast pressure trace over the sampled span (`Barometry.fuse`: median offset removed, readings more than 2 hPa off dropped, at least 3 readings over 30 minutes).

## Not built yet

- Personal model: only the per-spot catch-rate scale is fitted (`CatchRateMultiplier`). Factor weights are not refitted from the log.
- Barometer: old `PressureSample` rows are never pruned; the "live pressure" toggle resets on launch.
- Tides in the app: `TideStation` exists; no station data or UI.
- Bathymetry overlays, offline map packs, push alerts, CoreML model, App Store Server Notifications, backend rate limiting / App Attest.
