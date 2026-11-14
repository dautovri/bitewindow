# Scoring model

`BiteIndex(t) = 100 · σ(3 · Σ wᵢ · zᵢ(t))`, each `zᵢ ∈ [-1, 1]`, 50 = neutral.

| Term | Form (`Sources/BiteCore/Terms.swift`) | Evidence |
|---|---|---|
| Light | `0.7·twilight + 0.3·cloud`; twilight = Gaussian bump (60 min) at sunrise/sunset | Moderate–strong (Escanaba Lake creel census, PLOS ONE 2021) |
| Thermal | Asymmetric performance curve on water temperature; neutral when unknown | Strong physiology, small CPUE effect |
| Wind | `0.6·speed + 0.4·direction`; speed peaks at 18 km/h, −1 above 35 km/h | Moderate (Escanaba; pike studies) |
| Pressure | `0.5·tanh(−Δ6h/3) + 0.35·post-front penalty + 0.15·stability`; proxy for fronts | Weak; absolute pressure is not supported |
| Solunar | Gaussian kernels at lunar transits (45 min) and moonrise/set (30 min, ×0.6), phase-modulated | Contradicted for trout (Quigley et al. 2023, SN Applied Sciences); modest for muskellunge (Vinson & Angradi 2014) |
| Tide | `0.7·(2·|dh/dt| / day max − 1) + 0.3·(2·day max / spring-neap max − 1)`, saltwater only; without a station `0.5·cos(2·moon phase)` (spring tides at new and full moon) | Practitioner consensus |

Stratification drives depth advice only, never the timing score.

## Fish for the conditions (map)

Species differ only in the thermal term, so the map ranks them by thermal fit at the measured water temperature, or at an estimate (mean air temperature of the last 72 h, 1–30 °C) labelled as such. Freshwater spots only. It says which fish the conditions suit, not which live in the water.

## Heuristic, to be replaced

- All numeric weights in `Profiles.swift`. Only the ordering of factors is evidence-informed.
- Species thermal parameters (optimum, low-side width, critical maximum), including crucian carp, common carp, perch and bream.
- The air-mean water estimate and the 0.3 spring-neap share of the tide term.
- Kernel widths and the logistic gain.

## Expected catch

`E[catch] = m · b · ∫ index(t)/50 dt`, with `b = 0.5 fish/h` (heuristic) and `m` the per-spot Gamma–Poisson multiplier, prior Gamma(5, 5), updated with `(catches, b · ∫ index/50 dt)` per finished trip. The linear index-to-rate map is an assumption, not a fitted link.

Refit plan: Poisson model of catch count with log(hours) offset, random intercepts per angler and per water, trained on logged trips including zero-catch trips.
