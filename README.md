# BiteCurve: Fishing Forecast

Evidence-calibrated fishing bite-window prediction for iOS (App Store id 6834430484). The code and Xcode targets still use the original working name, BiteWindow.

| Part | Path | What it is |
|---|---|---|
| Engine | `Sources/BiteCore` | Pure Swift: sun/moon ephemeris, solunar periods, bite-score terms, tide harmonics, Gamma–Poisson personalization, forecast scorecard, geohash |
| App | `App/` | SwiftUI + SwiftData + StoreKit 2 + WidgetKit + CoreMotion + MapKit, iOS 17+, generated with XcodeGen |
| Backend | `backend/` | Cloudflare Worker: WeatherKit behind a geohash-5 hourly KV cache (`/wx`), NOAA tide constants (`/tide`), water temperature (`/water`), opt-in shared trips in D1 (`/trip`) |
| Android | `android/` | Kotlin port in progress (own branch), with a parity harness against `BiteCore` |

## Status

| Component | State |
|---|---|
| App | 1.0 and 1.1 released; 1.2.0 in App Review. 18 store languages |
| `BiteCore` | 42 unit tests (Linux, `swift:6.0`) |
| App tests | StoreKit purchase tests and structure tests (`App/BiteWindowTests`), run in CI on Xcode 26 |
| `backend` | Deployed at `bitewindow-wx.dautov.workers.dev`; Node tests in `backend/test` |
| Tide engine | Checked against NOAA predictions at three US stations (see `docs/SCIENCE.md`); US stations only |
| Species thermal parameters, factor weights | Heuristic placeholders (see `docs/SCIENCE.md`) |

## Run

```sh
xcrun --toolchain default swift test     # engine
cd backend && npm test                   # worker
cd App && xcodegen generate && open BiteWindow.xcodeproj   # app
```

Debug launch arguments: `-BCSeedSpots YES` (sample spots and trips), `-BCSkipWelcome YES`, `-BCPro YES`, `-BCAPIBase <url>` (another backend, for failure drills).

## Data store

SwiftData, local only, with a versioned schema (`BiteSchemaV1`, `BiteMigrationPlan` in `App/BiteWindow/Models/Models.swift`). Adding optional or defaulted fields needs nothing; any other change needs a new schema version and a migration stage. A store that cannot be opened is moved aside as `default.store.unreadable-<time>`, never deleted.

## Free vs Pro (as implemented)

| | Free | Pro |
|---|---|---|
| Trip log incl. zero-catch trips | yes | yes |
| Saved spots | 3 | unlimited |
| Daily best window + index | today, tomorrow | 10 days |
| Bite alerts and widgets | today, tomorrow | 7 days |
| Planner | today, tomorrow | 10 days |
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

## Offline (as implemented)

- Every forecast response is saved on disk per geohash-5 cell. A spot opens from the saved copy first, then replaces it if the network answers; requests time out after 10 s.
- Forecasts for all spots are downloaded when the app comes to the foreground (at most hourly), from Settings → Offline, and through `BGAppRefreshTask` (iOS decides if and when that runs).
- A saved forecast covers about 10 days from download. Beyond it, or with nothing saved, `Forecaster.curve(fillMissingWeather:)` scores from sun, moon, tide and the entered water temperature, with wind, pressure and cloud neutral. Those days are labelled in the UI.
- Tide constants are saved indefinitely once fetched. Trips, spots and the log are local (SwiftData).
- Trips ended without weather count as neutral in the personal fit, as before.
- Not covered: map tiles (MapKit has no offline pack API; spots can still be added at the crosshair on a blank map), and the paywall, which needs the App Store.

## Languages

English plus 17 translations in `App/BiteWindow/Localizable.xcstrings` (109 strings) and `InfoPlist.xcstrings`: de, nl, sv, nb, da, es, fr, it, pt-BR, fi, pl, ru, uk, tr, ja, ko, zh-Hans. Machine-translated, not reviewed by native speakers; species names for walleye and muskellunge are the least certain. Dates, times and numbers follow the device locale. Species names in `BiteCore` stay English; the app uses `Species.localizedName`. Tide station names come from NOAA in English.

## Not built yet

- Factor weights are not refitted yet: opt-in shared trips (`/trip`) collect what a refit needs.
- Tides outside the US (moon phase stands in), offline map packs, iCloud sync, bathymetry.
