# 13 — Harmonization v2: regional calibration (improved method, not implemented)

> **Status: not used by the app.** The app uses the simple method of [doc 14](14-harmonization-simple.md): one
> national factor k per calendar month (VIIRS ÷ Aqua, median 2012-2021). This regional version was applied on a11-db
> on 2026-11-15 and then replaced to keep the method simple and easy to explain. It stays here as a **tested
> improvement** for when small areas need more accuracy: it lowers the monthly error in areas whose fires differ from
> the country average (Sierra de Arteaga 36.6 % → 25.8 %). The code still works: `analysis/harmonization/*.py`
> generates `analysis/db/harmonization_v2.sql`. Applying that file would bring it back (and the NRT static filter is
> the same in both).
>
> What it adds on top of the simple method: factors per 1° region and month with hierarchical shrinkage, a local
> correction per polygon, S-NPP as an explicit bridge (S-NPP → NOAA-20 factor), Terra + Aqua as the MODIS reference,
> calibration 2012-2023, and a 10-90 % range from leave-one-year-out errors by estimate size.

Replaced the provisional `harmonize_polygon()` (one median ratio per area). Same signature and JSON contract, so
`server.js` and the page do not change.

- SQL to apply: [`analysis/db/harmonization_v2.sql`](../../analysis/db/harmonization_v2.sql) (generated, idempotent)
- Code: [`analysis/harmonization/`](../../analysis/harmonization/) — `pull.py` → `calibrate.py` → `build_sql.py` → `test_sql.py`
- Data: a11-db (Mexico), Standard Processing, `fire_type = 0`, confidence nominal/high, same filters for every sensor.

## 1. What was wrong with the provisional method

| Problem | Effect |
|---|---|
| Factor Terra+Aqua applied to months with **Terra only** (2000-11 → 2002-06) | 2001 and early 2002 **~54 % too low** (e.g. Ocosingo 2001: 1,139 → 2,349) |
| One factor for the whole year | Ignores the seasonal swing we measured (3.3× in Jan/Sep/Dec → 5.1× in June) |
| Calibrated inside each (small) area | Santiago/Arteaga have months with 0–3 fires → noisy ratio |
| S-NPP not used | MODIS-era extended to 2017 although real VIIRS data exist since 2012 |
| NRT rows have no `fire_type` → counted as vegetation | Aug–Nov 2026 inflated by gas flares/refineries: **40–59 % of NOAA-20 detections in those months nationally are static sources**. Drawn area in Tabasco: 1,185 → 150 (Aug 2026) |
| Low-confidence detections mixed in | Changes the ratio (4.29 → 3.86, see doc 03) |

## 2. Method

Reference: **VIIRS NOAA-20** (used as-is from 2018-04). Each link is calibrated on two *real* overlapping sensors:

| Period | Source | Calibration (overlap) |
|---|---|---|
| 2018-04 → now | NOAA-20 | — |
| 2012-02 → 2018-03 | S-NPP × k<sub>S</sub> | NOAA-20 / S-NPP, 2018-04 → 2025-12 (≈ 1.00, national by month) |
| 2002-07 → 2012-01 | MODIS (Terra+Aqua) × k<sub>M</sub> × k<sub>S</sub> | S-NPP / MODIS, 2012-02 → 2023-12 |
| 2001-01 → 2002-06 | Terra × k<sub>T</sub> × k<sub>S</sub> | S-NPP / Terra, same overlap |

MODIS is calibrated only up to 2023: from 2024 Terra's orbit drift shows (Aqua/Terra goes from ~1.2 to 1.6).

**Factors per 1° region and calendar month, with hierarchical shrinkage** (regions with few fires borrow from the
national value): national month factor → region level shrunk to national (α) → region × month shrunk to the region
with the national seasonal shape. α chosen by leave-one-year-out error (α = 30 for MODIS/Terra; S-NPP→NOAA-20 is
best as a national month factor).

**Local correction of the polygon:** `c = (ΣV + β) / (Σpred + β)` over the overlap years inside the polygon (β = 100,
30 for Terra). Areas with few fires keep the regional factor; areas with many fires use their own (this is what fixed
Arteaga, a mountain range with large forest fires whose ratio differs from the farmland around it).

**Uncertainty (`low`/`high`):** 10–90 % range of `(true+1)/(pred+1)` from leave-one-year-out residuals, by size of the
estimate. Coverage measured: 84 % on 1° cells, 80 % on the areas (target 80 %).

**NRT static sources:** `static_sites` = 0.01° cells with ≥ 3 static detections (type 1/2/3) that are ≥ 50 % of the
cell's detections; NRT points in such a cell or a neighbour are dropped. Out of sample (sites from SP ≤ 2024, tested
on NOAA-20 2025): removes **95.6 %** of static detections and **1.5 %** of vegetation ones.

## 3. Validation (leave one year out)

Each year of the overlap is hidden, factors are fitted on the others, and the hidden year is predicted from MODIS
and compared with what S-NPP really saw. WAPE = Σ|pred − true| / Σtrue (lower is better).

**MODIS → VIIRS (2012–2023), monthly error**

| Unit | Provisional | **v2** |
|---|---|---|
| Mexico (national) | 5.4 % | **3.6 %** |
| 1° cells (all) | 23.0 % | **20.7 %** |
| Ocosingo | 16.8 % | **14.6 %** |
| Santiago | 35.9 % | **34.0 %** |
| Sierra de Arteaga | 36.6 % | **25.8 %** |

Annual error: Arteaga 21.1 % → **13.4 %**, Santiago 31.1 % → **23.4 %**, Ocosingo 7.9 % → 8.2 % (same).

**Terra-only months (2001 – mid 2002):** provisional bias **−54 %** nationally (−49 to −54 % in the areas);
v2 national monthly error **5.5 %**. Small areas stay noisy in this period (only one satellite, few fires): that is
what the wide `low`/`high` range shows.

**S-NPP → NOAA-20 (2018–2025):** national 3.2 %, Ocosingo 11.8 % → 10.2 %, Arteaga 17.8 % → 14.3 %, Santiago ≈ same.

Full numbers: `data/harmonization/validation.json` after running `calibrate.py`.

## 3b. Checked against the recommendation in doc 12 (state of the art)

Doc 12 suggests Aqua as the only MODIS reference and calibrating on 2012–2021. Same leave-one-year-out test,
same test years (2012–2021), monthly WAPE:

| MODIS reference · calibration window | National | 1° cells |
|---|---|---|
| **Terra + Aqua · 2012–2023 (v2)** | **3.3 %** | **20.3 %** |
| Terra + Aqua · 2012–2021 | 3.3 % | 20.4 % |
| Aqua only · 2012–2021 | 4.2 % | 23.6 % |
| Aqua only · 2012–2023 | 4.0 % | 23.6 % |

Aqua alone has half the detections, so its factors are noisier; ending the window in 2021 or 2023 makes no
measurable difference (Aqua/Terra in our data only jumps from 2024: 1.07–1.23 up to 2023, 1.35 in 2024, 1.39 in
2025). Small areas (Santiago) swing a lot between variants and were not used to decide. Still open from doc 12:
cell-days instead of detections, day/night split, local-time months.

## 4. How to apply

1. Run `analysis/db/schema.sql` as today (unchanged), then `analysis/db/harmonization_v2.sql` (≈ 180 KB, a few
   seconds). It creates `harmonization_factors`, `harmonization_bins`, `harmonization_params`, `static_sites`,
   replaces `harmonize_polygon()` and `harmonized_index_json()` (provisional → false) and grants SELECT to `a11_web`.
2. Clear the 10-minute cache of `server.js` (restart the service) and reload the page: the pill no longer says
   "Provisional".
3. After big historical loads run `SELECT refresh_static_sites();` (the daily NRT does not need it).

Tested against the real a11-db inside a temporary schema (`test_sql.py`): 0.1 s per municipality, 0.4 s for
Ocosingo, 311 months each, no change to `public`.

## 5. Re-running

```bash
python analysis/harmonization/pull.py        # DATABASE_URL (read-only is enough) in .env
python analysis/harmonization/calibrate.py
python analysis/harmonization/build_sql.py
python analysis/harmonization/test_sql.py    # optional: check against the DB without writing
```

## 6. Limits

- Calibrated on Mexico only; the national fallback factors are Mexico's.
- United States: the US backfill does not download S-NPP, so a polygon with no S-NPP detections in
  2012-02..2025-12 skips the S-NPP link. 2002-07..2018-03 become `p_modis × k_SNPP→N20 (national) × c`,
  with the local correction `c = (ΣN20 + β) / (Σ p_modis·k_SNPP→N20 + β)` fitted directly against NOAA-20 in
  2018-04..2025-12 (same for Terra-only months). Those months are labelled `MODIS_calibrated` and use the MODIS
  uncertainty bins. Downloading S-NPP for the US would restore the full chain.
- Small areas in the Terra-only months are uncertain (±50 % or more): shown as the estimate range.
- The NRT static filter removes a few vegetation fires right next to flares/refineries (1.5 % nationally,
  more in Tabasco), and cannot catch a brand-new static source.
- Day/night and local-time binning (doc 04 §0) are still UTC months.
