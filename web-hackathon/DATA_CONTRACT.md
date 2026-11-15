# Harmonized data contract

The Burning Activity Calendar (`public/index.html`) reads two JSON documents, `index` and `areas/<id>`, through
`public/harmonized.js` (the only browser code that knows this format).

## Where the data comes from

```
n8n pipelines ─► hotspots (a11-db)
                   │  polygon_monthly_raw(geom)      counts per month and satellite inside a polygon
                   │  harmonize_polygon(geom)        >>> the harmonization step — PROVISIONAL, replace it <<<
                   │  harmonized_index_json()        ─► GET  /api/harmonized/index
                   │  harmonized_area_json(id)       ─► GET  /api/harmonized/areas/<id>
                   └  harmonized_drawn_json(geojson) ─► POST /api/harmonized/polygon   (areas drawn by the user)
                                                          server.js (DATABASE_URL, 10-min cache)
```

All SQL is in `analysis/db/schema.sql` (applied by the n8n workflow "A11 DB setup"). The areas in the picker are
rows of the `areas` table. The n8n workflow "A11 DB status" has a **Harmonized** node that shows what the API
would return (month counts, first/last month, yearly totals per area).

**To plug in the real harmonization**, replace only the body of `harmonize_polygon()` (keep its signature:
`month, count, low, high, source`), set `'provisional'` to `false` in `harmonized_index_json()`, and re-run
"A11 DB setup". The server and the page do not change.

**Method used by the app:** apply `analysis/db/harmonization.sql` after `schema.sql` — one factor k per calendar
month (VIIRS ÷ Aqua, median 2012-2021), MODIS-era `low`/`high` = 10th-90th percentile of the yearly ratios, NRT
static sources removed. See `docs/research/14-harmonization-simple.md`.

**Regional v2 method (improved, not implemented):** `analysis/db/harmonization_v2.sql` — regional, seasonal
calibration with S-NPP as a bridge and NRT static sources removed. See `docs/research/13-harmonization-v2.md`.

**Provisional method (schema.sql alone):** NOAA-20 counts from its first full month (2018) on; earlier months are MODIS
(Terra + Aqua) × the area's median yearly NOAA-20/MODIS ratio, with `low`/`high` from the 10th/90th percentile
of those ratios.

### Fallback: fake files

If `DATABASE_URL` is not set or the database fails, the server answers the GETs with the fake files in
`public/data/harmonized/` (`"synthetic": true`, the page shows "Illustrative data"). A plain static server
(local preview) has no `/api`, so `harmonized.js` reads those files directly. Regenerate them with:

```bash
py analysis/make_fake_harmonized.py --through 2026-11-14
```

## `index.json`

```json
{
  "schema_version": 1,
  "synthetic": true,
  "generated_at": "2026-11-14T15:00:00Z",
  "data_through": "2026-11-14",
  "baseline": { "first_year": 2001, "normal_first_year": 2003, "last_year": 2025 },
  "units": "VIIRS-equivalent vegetation-fire hotspots per month",
  "reference": "VIIRS (NOAA-20)",
  "method": "short description of the harmonization",
  "areas": [
    { "id": "stgo", "name": "Santiago, Nuevo León", "kind": "municipality", "file": "areas/stgo.json" }
  ]
}
```

| Field | Meaning in the page |
| --- | --- |
| `schema_version` | Must be `1`; the page refuses other versions. |
| `provisional` | Optional. `true` adds "Provisional ·" to the data pill, the method to its tooltip, and tells Ember. |
| `synthetic` | `true` shows the "Illustrative data" pill, tags the CSV as `_ILLUSTRATIVE` and tells Ember the data is illustrative. `false` shows "Data through <date>". |
| `generated_at` | "Updated … ago" under the current month. |
| `data_through` | Last day with data. Its month is the "in progress" month; later months are hidden. |
| `baseline` | `first_year` = start of the timeline; `normal_first_year`–`last_year` = the years used for "typical", percentiles and categories (optional, defaults to `first_year`; 2003 = first full year of Aqua). |
| `units`, `reference`, `method` | Shown in the pill tooltip. |

## `areas/<id>.json`

```json
{
  "id": "stgo",
  "name": "Santiago, Nuevo León",
  "kind": "municipality",
  "polygon": [[25.52, -100.28], [25.53, -100.05], [25.30, -99.98]],
  "months": [
    {"month": "2001-01", "count": 14, "low": 11, "high": 17, "source": "MODIS_calibrated"},
    {"month": "2026-11", "count": 4, "low": 4, "high": 4, "source": "VIIRS", "partial": true}
  ]
}
```

- `polygon`: `[lat, lon]` pairs (Leaflet order), outline drawn on the map.
- `months`: one row per month from `baseline.first_year`-01 to the month of `data_through`.
  - `count`: harmonized (VIIRS-equivalent) hotspots. For the current month it is the **count so far**
    (days 1 → `data_through`); the page compares it with the same fraction of past months.
  - `low` / `high`: uncertainty range (equal to `count` for VIIRS months).
  - `source`: `"VIIRS"` or `"MODIS_calibrated"`. The last year with any non-VIIRS month defines the
    "MODIS era" band on the timeline, heatmap and annual chart.
  - A missing month inside the covered period is read as 0 hotspots.

## Drawn areas

`POST /api/harmonized/polygon` with `{ "polygon": [[lat, lon], ...] }` (3–200 points, ≤ 100,000 km²) returns
`{ "area_km2": 812, "months": [...] }` computed by `harmonized_drawn_json()`. Without the database the page
falls back to an illustrative estimate (the first area scaled by size) and labels it "illustrative".

## Detections and raw counts (read straight from `hotspots`, no schema change)

Both take `{ "area": "<id>" }` or `{ "polygon": [[lat, lon], ...] }` (≤ 100,000 km²) and need the database.

- `POST /api/hotspots` with `from` / `to` (`YYYY-MM-DD`) and `format`:
  - `"json"` → `{ total, points: [[lat, lon, frp, conf_class, satellite], ...] }`, the 3,000 strongest. The map uses it
    for the real dots of the selected month: NOAA-20 for VIIRS months, Terra + Aqua for MODIS-era months.
  - `"csv"` → every vegetation-fire detection, all satellites (or `satellites: [...]`), up to 200,000 rows; headers
    `X-Rows`, `X-Truncated`. This is the Report tab's "Hotspots in this area and range" download.
- `POST /api/harmonized/raw` → `{ months: [{ month, modis, noaa20, snpp, noaa21 }] }`, counts before harmonization. The
  Method tab cross-validates the MODIS→VIIRS ratio with it (leave-one-year-out over the overlap years). That check
  re-implements the provisional method in the page; if `harmonize_polygon()` changes, update `validate()` in `index.html`.

Without the database the dots fall back to random positions (labelled "positions illustrative") and the Method tab
uses invented raw counts. `dev_server.py` previews the page on Python: it proxies the deployed API and mocks these two.

## Reported fires

The source follows the area's centroid (`countryOf()` in `index.html`, a coarse US–Mexico border):

- **Mexico:** `public/data/reported/conafor-mx.json` holds every CONAFOR-reported wildfire 2015–2025 with coordinates
  (columnar: `t` months since 2015-01, `lat`/`lon` × 1000, `ha` × 10). Rebuild it with
  `analysis/build_reported_fires.py` (source URLs in the script).
- **United States:** the browser queries NIFC's public WFIGS Incident Locations service (wildfires `WF` discovered
  since 2015) by the area's bounding box, then keeps the points inside the outline. WFIGS holds only incidents
  reported to IRWIN, so it undercounts state and local fires; `IncidentSize` is the whole fire's size.

The page counts the fires inside the area for the "Detected vs reported" section and the Report range. Areas in
neither country hide the section.

## Not covered yet

- Area outlines in the `areas` table are rough hand-drawn polygons; load official municipal/county boundaries.
- US hotspots exclude S-NPP (the harmonized series uses MODIS and NOAA-20 only).
