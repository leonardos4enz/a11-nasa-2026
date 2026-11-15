# 14 — Harmonization (simple method): one factor k per calendar month

**This is the method used by the app.** It replaces the regional v2 method ([doc 13](13-harmonization-v2.md)), which
is kept as a documented improvement that is not implemented. The goal of the change was to make the method simple
enough to explain in five steps, as in the team presentation "Armonización MODIS–VIIRS v2 (documento 12)".

- SQL to apply: [`analysis/db/harmonization.sql`](../../analysis/db/harmonization.sql) (hand-written, idempotent)
- No Python step: the factors are computed inside the database by `refresh_harmonization_k()`.
- Same signature and JSON contract for `harmonize_polygon()`, so `server.js` and the page work unchanged.

## 1. Method

| Step | What | Detail |
|---|---|---|
| 1. Divide | VIIRS ÷ Aqua per month, Mexico | Same filters for both: SP, `fire_type = 0`, confidence nominal/high |
| 2. Median | Median of the yearly ratios, 2012-02..2021-12 | 2022 on is left out (MODIS orbit drift). January 2012 is partial for S-NPP, so January uses 2013-2021 |
| 3. Per month | 12 factors k (`harmonization_k`, link `AQUA`) | Interquartile range of the yearly ratios kept as `k_q25` / `k_q75` |
| 4. Translate | 2002-07..2012-01: Aqua × k | Before 2002-07 (Terra only): Terra × k<sub>T</sub> × k, k<sub>T</sub> = median Aqua ÷ Terra per month, 2003-2011 (link `TERRA`) |
| 5. Compare | Each month vs its historical median | Unchanged (`harmonized_*_json` in `schema.sql`) |

**One reference satellite per sensor** (INPE rule): Aqua for MODIS (13:30 overpass, like VIIRS); VIIRS = S-NPP until
2018-03 and NOAA-20 from 2018-04 (S-NPP ≈ 1.01 × NOAA-20 in 2019-2021, chained without a factor). Satellites are
never added up, because a new launch would create a false jump.

| Period | Value | `source` | low / high |
|---|---|---|---|
| 2018-04 → now | NOAA-20 | `VIIRS` | = count |
| 2012-02 → 2018-03 | S-NPP | `VIIRS` | = count |
| 2002-07 → 2012-01 | Aqua × k[m] | `MODIS_calibrated` | Aqua × k_q25[m] … Aqua × k_q75[m] |
| 2001-01 → 2002-06 | Terra × k<sub>T</sub>[m] × k[m] | `MODIS_calibrated` | both quartiles multiplied |

Polygons with no S-NPP detections in 2012-02..2018-03 (the US backfill does not download S-NPP) use Aqua × k until
2018-03.

**Kept from v2: the NRT static-source filter.** Near-real-time rows have no `fire_type`; `static_sites` (0.01° cells
where the archive shows mostly volcano/industrial/offshore detections) removes them. This is data cleaning, not
harmonization: without it 40-59 % of the NOAA-20 NRT detections in Aug-Nov 2026 nationally would be gas flares and
refineries.

## 2. Validation

`SELECT harmonization_validation_json();` repeats the presentation's test on the database with the app's filters:
each year of 2012-2021 is hidden, k is recomputed with the other years, the hidden year is predicted from Aqua and
compared with VIIRS. It returns the monthly WAPE, the median monthly and yearly errors, the error of each year, the
share of months whose true value falls inside the IQR band, and the twelve factors.

Results of the method study (presentation, national counts of `web/explorer/data/mexico_monthly.json`, all
confidence levels):

| Metric | Value |
|---|---|
| Yearly total, median error | **3.7 %** |
| Worst year | 2015, +11.5 % |
| Single month, median error | 6.5 % |
| Quiet months | January 2012: +109 % |
| Predicting 2022-2025 with 2012-2021 factors | −8.7 % to +7.0 % |

The values with the app's filters (nominal/high confidence) come out of `harmonization_validation_json()` after
applying the SQL; the factors themselves change with the filter, which is why they are recomputed in the database
instead of copied from the presentation.

## 3. What was removed (and why it is still documented)

Compared with v2, the simple method drops: factors per 1° region with hierarchical shrinkage, the local correction
per polygon (β), the S-NPP → NOAA-20 factor, Terra + Aqua as the MODIS reference, the 10-90 % error bins, the
2012-2023 window, and the Python pipeline (`pull → calibrate → build_sql → test_sql`). Doc 13 describes that method as
an **improved version, not implemented**, with its validation, so it can be brought back if small areas need it.

Expected cost, from the measurements in doc 13 §3b: nationally the change is small (Aqua only, 2012-2021: 4.2 %
monthly WAPE vs 3.3 % for v2); on small areas it is larger, because national factors cannot follow an area whose fires
differ from the country's (Sierra de Arteaga: 25.8 % with v2's local correction, 36.6 % with a single ratio).

## 4. How to apply

1. Apply `analysis/db/harmonization.sql` on a11-db (n8n workflow that runs the file, as was done for v2). It replaces
   `harmonize_polygon()` and `harmonized_index_json()`, creates `harmonization_calib` and `harmonization_k`, computes
   the factors, and drops the v2 tables `harmonization_factors`, `harmonization_bins`, `harmonization_params`.
2. Check: `SELECT * FROM harmonization_k ORDER BY link, m;` and `SELECT harmonization_validation_json();`.
3. Restart the web service (10-minute cache of `server.js`).
4. After a big historical load: `SELECT refresh_static_sites(); SELECT refresh_harmonization_k();`. The daily NRT
   does not need it (calibration years are fixed).

## 5. Limits

Same as the presentation (slide "Límites del método"): fixed proportion per calendar month; small areas are noisy
(national k everywhere); zero does not mean no fire; MODIS orbit drift from 2022; day and night mixed; hotspots, not
fires (cell-days would avoid counting one fire several times). Factors are Mexico's and also apply to the US.
