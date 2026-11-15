-- A11 harmonization, simple method (monthly factor k). Replaces harmonization_v2.sql.
-- Apply AFTER analysis/db/schema.sql (e.g. with the n8n workflow "A11 Harmonization (apply)"). Idempotent.
-- Hand-written: the factors are computed inside the database by refresh_harmonization_k(), no Python step.
--
-- Method (docs/research/14-harmonization-simple.md):
--   1. Divide   VIIRS / Aqua for each month of Mexico, same filters for both (SP, vegetation, nominal/high).
--               VIIRS = S-NPP until 2018-03, NOAA-20 from 2018-04 (one reference satellite per sensor, never summed).
--   2. Median   of those ratios over 2012-02..2021-12 (before the MODIS orbit drift); 10-90 % range of the ratios = uncertainty.
--   3. Per month: twelve factors k, one per calendar month.
--   4. Translate: 2002-07..2012-01 = Aqua x k. Before 2002-07 only Terra flies:
--               Terra x (Aqua/Terra factor, median of 2003..2011) x k. From 2012-02: VIIRS as observed.
--   5. Compare  each month with its historical median from 2003 (baseline.normal_first_year; the page computes it).
-- Kept from v2: the NRT static-source filter (gas flares, refineries, volcanoes), which is data cleaning.
-- The regional v2 method is documented as an improvement not implemented: docs/research/13-harmonization-v2.md.
BEGIN;

-- ------------------------------------------------------------------ static sources (unchanged from v2)
-- Static sources (volcanoes, industry, platforms) on a 0.01° (~1 km) grid, derived from the
-- SP rows that do carry fire_type: cells with >= 3 static detections that are also >= 50 % of their detections.
-- NRT rows carry no fire_type: they are dropped if they fall in one of those cells or a neighbouring one.
-- Validated out of sample (sites from SP <= 2024, tested on NOAA-20 2025): removes 95.6 % of the static
-- detections and only 1.5 % of the vegetation ones.
CREATE TABLE IF NOT EXISTS static_sites (fy int NOT NULL, fx int NOT NULL, PRIMARY KEY (fy, fx));

CREATE OR REPLACE FUNCTION refresh_static_sites() RETURNS bigint LANGUAGE sql AS $$
    TRUNCATE static_sites;
    INSERT INTO static_sites
    SELECT floor(latitude / 0.01)::int, floor(longitude / 0.01)::int
    FROM hotspots WHERE processing = 'SP' AND fire_type IS NOT NULL
    GROUP BY 1, 2
    HAVING count(*) FILTER (WHERE fire_type IN (1, 2, 3)) >= 3
       AND count(*) FILTER (WHERE fire_type IN (1, 2, 3)) >= 0.5 * count(*);
    SELECT count(*) FROM static_sites;
$$;

CREATE OR REPLACE FUNCTION is_static_site(p_lat real, p_lon real) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM static_sites s
                   WHERE s.fy BETWEEN floor(p_lat / 0.01)::int - 1 AND floor(p_lat / 0.01)::int + 1
                     AND s.fx BETWEEN floor(p_lon / 0.01)::int - 1 AND floor(p_lon / 0.01)::int + 1);
$$;

-- Counts per 1° cell, month and satellite inside a polygon, with the harmonization filters.
-- (The 1° cell columns are no longer used by the harmonization; kept because server.js /api/harmonized/raw reads it.)
CREATE OR REPLACE FUNCTION polygon_monthly_cells(p_geom geometry)
RETURNS TABLE (ry int, rx int, month date, satellite text, n bigint) LANGUAGE sql STABLE AS $$
    SELECT floor(h.latitude)::int, floor(h.longitude)::int, date_trunc('month', h.acq_date)::date, h.satellite, count(*)
    FROM hotspots h
    WHERE ST_Intersects(h.geom, p_geom)
      AND h.conf_class <> 'l'
      AND (h.fire_type = 0 OR (h.fire_type IS NULL AND NOT is_static_site(h.latitude, h.longitude)))
    GROUP BY 1, 2, 3, 4;
$$;

-- ------------------------------------------------------------------ calibration (steps 1-3)
-- National monthly counts of Mexico used for the calibration, one column per reference satellite.
CREATE TABLE IF NOT EXISTS harmonization_calib (
    month date PRIMARY KEY,
    terra bigint NOT NULL,
    aqua  bigint NOT NULL,
    viirs bigint NOT NULL       -- S-NPP until 2018-03, NOAA-20 from 2018-04
);

-- The factors: twelve per link (one per calendar month). Dropped first: its columns changed (IQR -> 10-90 %).
DROP TABLE IF EXISTS harmonization_k;
CREATE TABLE IF NOT EXISTS harmonization_k (
    link    text     NOT NULL,  -- 'AQUA'  = VIIRS / Aqua  (2012-02..2021-12)
                                -- 'TERRA' = Aqua / Terra  (2003-01..2011-12), only for the Terra-only months
    m       smallint NOT NULL,  -- calendar month 1-12
    k       float8   NOT NULL,  -- median of the yearly ratios
    k_p10   float8   NOT NULL,  -- 10th-90th percentile of the yearly ratios = uncertainty band
    k_p90   float8   NOT NULL,
    n_years int      NOT NULL,
    PRIMARY KEY (link, m)
);

CREATE OR REPLACE FUNCTION refresh_harmonization_k() RETURNS bigint LANGUAGE sql AS $$
    TRUNCATE harmonization_calib, harmonization_k;
    INSERT INTO harmonization_calib (month, terra, aqua, viirs)
    SELECT date_trunc('month', acq_date)::date,
           count(*) FILTER (WHERE satellite = 'Terra'),
           count(*) FILTER (WHERE satellite = 'Aqua'),
           count(*) FILTER (WHERE (satellite = 'SNPP' AND acq_date < date '2018-04-01')
                               OR (satellite = 'NOAA20' AND acq_date >= date '2018-04-01'))
    FROM hotspots
    WHERE processing = 'SP' AND country = 'Mexico' AND fire_type = 0 AND conf_class <> 'l'
      AND acq_date >= date '2003-01-01' AND acq_date < date '2022-01-01'
    GROUP BY 1;

    INSERT INTO harmonization_k (link, m, k, k_p10, k_p90, n_years)
    SELECT 'AQUA', extract(month FROM month)::int,
           percentile_cont(0.50) WITHIN GROUP (ORDER BY viirs::float8 / aqua),
           percentile_cont(0.10) WITHIN GROUP (ORDER BY viirs::float8 / aqua),
           percentile_cont(0.90) WITHIN GROUP (ORDER BY viirs::float8 / aqua),
           count(*)
    FROM harmonization_calib
    WHERE month >= date '2012-02-01'          -- S-NPP starts 2012-01-19: January 2012 is a partial month
      AND aqua > 0 AND viirs > 0
    GROUP BY 2
    UNION ALL
    SELECT 'TERRA', extract(month FROM month)::int,
           percentile_cont(0.50) WITHIN GROUP (ORDER BY aqua::float8 / terra),
           percentile_cont(0.10) WITHIN GROUP (ORDER BY aqua::float8 / terra),
           percentile_cont(0.90) WITHIN GROUP (ORDER BY aqua::float8 / terra),
           count(*)
    FROM harmonization_calib
    WHERE month < date '2012-01-01' AND terra > 0 AND aqua > 0
    GROUP BY 2;

    SELECT count(*) FROM harmonization_k;
$$;

-- ------------------------------------------------------------------ harmonization (step 4)
-- Same signature as before (contract: web-hackathon/DATA_CONTRACT.md), so server.js and the page do not change.
CREATE OR REPLACE FUNCTION harmonize_polygon(p_geom geometry)
RETURNS TABLE (month date, count integer, low integer, high integer, source text) LANGUAGE sql STABLE AS $$
    WITH last AS (SELECT max(acq_date) AS d FROM hotspots),
    pm AS (   -- polygon-month counts per reference satellite
        SELECT r.month,
               coalesce(sum(r.n) FILTER (WHERE r.satellite = 'Terra'), 0)  AS terra,
               coalesce(sum(r.n) FILTER (WHERE r.satellite = 'Aqua'), 0)   AS aqua,
               coalesce(sum(r.n) FILTER (WHERE r.satellite = 'SNPP'), 0)   AS snpp,
               coalesce(sum(r.n) FILTER (WHERE r.satellite = 'NOAA20'), 0) AS n20
        FROM polygon_monthly_cells(p_geom) r GROUP BY r.month
    ),
    -- The US backfill does not download S-NPP: without it, Aqua x k is used until NOAA-20 starts (2018-04).
    flag AS (SELECT coalesce(sum(snpp) > 0, false) AS has_snpp
             FROM pm WHERE month BETWEEN date '2012-02-01' AND date '2018-03-01'),
    months AS (
        SELECT g::date AS month, extract(month FROM g)::int AS m
        FROM last, generate_series(date '2001-01-01', date_trunc('month', last.d), interval '1 month') g
    ),
    est AS (
        SELECT mo.month,
               CASE WHEN mo.month >= date '2018-04-01' THEN 'NOAA20'
                    WHEN mo.month >= date '2012-02-01' AND f.has_snpp THEN 'SNPP'
                    WHEN mo.month >= date '2002-07-01' THEN 'AQUA'
                    ELSE 'TERRA' END AS era,
               coalesce(pm.terra, 0) AS terra, coalesce(pm.aqua, 0) AS aqua,
               coalesce(pm.snpp, 0) AS snpp, coalesce(pm.n20, 0) AS n20,
               ka.k AS ka, ka.k_p10 AS ka_lo, ka.k_p90 AS ka_hi,
               kt.k AS kt, kt.k_p10 AS kt_lo, kt.k_p90 AS kt_hi
        FROM months mo CROSS JOIN flag f
        LEFT JOIN pm ON pm.month = mo.month
        LEFT JOIN harmonization_k ka ON ka.link = 'AQUA'  AND ka.m = mo.m
        LEFT JOIN harmonization_k kt ON kt.link = 'TERRA' AND kt.m = mo.m
    ),
    val AS (   -- estimate and its band (VIIRS months are observed: no band)
        SELECT month, era,
               CASE era WHEN 'NOAA20' THEN n20::float8 WHEN 'SNPP' THEN snpp::float8
                        WHEN 'AQUA' THEN aqua * ka ELSE terra * kt * ka END AS h,
               CASE era WHEN 'NOAA20' THEN n20::float8 WHEN 'SNPP' THEN snpp::float8
                        WHEN 'AQUA' THEN aqua * ka_lo ELSE terra * kt_lo * ka_lo END AS lo,
               CASE era WHEN 'NOAA20' THEN n20::float8 WHEN 'SNPP' THEN snpp::float8
                        WHEN 'AQUA' THEN aqua * ka_hi ELSE terra * kt_hi * ka_hi END AS hi
        FROM est
    )
    SELECT month,
           round(h)::int,
           floor(lo)::int,
           ceil(hi)::int,
           CASE WHEN era IN ('NOAA20', 'SNPP') THEN 'VIIRS' ELSE 'MODIS_calibrated' END
    FROM val
    ORDER BY month;
$$;

-- ------------------------------------------------------------------ validation (leave one year out)
-- Each overlap year is hidden, k is recomputed with the other years, and the hidden year is predicted from Aqua
-- and compared with what VIIRS really counted. National (Mexico) monthly counts.
CREATE OR REPLACE FUNCTION harmonization_validation_json() RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH c AS (
        SELECT extract(year FROM month)::int AS y, extract(month FROM month)::int AS m, aqua, viirs
        FROM harmonization_calib WHERE month >= date '2012-02-01' AND aqua > 0 AND viirs > 0
    ),
    pred AS (
        SELECT t.y, t.m, t.viirs::float8 AS truth, t.aqua * o.k AS pred, t.aqua * o.p10 AS lo, t.aqua * o.p90 AS hi
        FROM c t
        CROSS JOIN LATERAL (
            SELECT percentile_cont(0.50) WITHIN GROUP (ORDER BY x.viirs::float8 / x.aqua) AS k,
                   percentile_cont(0.10) WITHIN GROUP (ORDER BY x.viirs::float8 / x.aqua) AS p10,
                   percentile_cont(0.90) WITHIN GROUP (ORDER BY x.viirs::float8 / x.aqua) AS p90
            FROM c x WHERE x.m = t.m AND x.y <> t.y) o
    ),
    yr AS (SELECT y, sum(pred) / sum(truth) - 1 AS err FROM pred GROUP BY y)
    SELECT jsonb_build_object(
        'test', 'leave one year out, Mexico, 2012-02..2021-12, Aqua x k vs VIIRS',
        'monthly_wape', round((SELECT sum(abs(pred - truth)) / sum(truth) FROM pred)::numeric, 3),
        'monthly_median_abs_error',
            round((SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(pred / truth - 1)) FROM pred)::numeric, 3),
        'annual_median_abs_error',
            round((SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(err)) FROM yr)::numeric, 3),
        'annual_error_by_year', (SELECT jsonb_object_agg(y, round(err::numeric, 3) ORDER BY y) FROM yr),
        'band_coverage',
            round((SELECT avg(CASE WHEN truth BETWEEN floor(lo) AND ceil(hi) THEN 1.0 ELSE 0.0 END) FROM pred)::numeric, 3),
        'factors', (SELECT jsonb_agg(jsonb_build_object('link', link, 'm', m, 'k', round(k::numeric, 2),
                                                        'p10', round(k_p10::numeric, 2), 'p90', round(k_p90::numeric, 2),
                                                        'years', n_years) ORDER BY link, m)
                    FROM harmonization_k));
$$;

-- ------------------------------------------------------------------ index.json
CREATE OR REPLACE FUNCTION harmonized_index_json() RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'schema_version', 1,
        'synthetic', false,
        'provisional', false,
        'generated_at', to_char(coalesce((SELECT max(last_loaded_at) FROM data_freshness), now()) AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'data_through', to_char(t.d, 'YYYY-MM-DD'),
        -- first_year = start of the timeline; normal_first_year = first year of the "normal" (2003: first full year of
        -- Aqua; 2001-2002 rest on Terra only and are the least certain).
        'baseline', jsonb_build_object('first_year', 2001, 'normal_first_year', 2003,
                                       'last_year', extract(year FROM t.d)::int - 1),
        'units', 'VIIRS-equivalent vegetation-fire hotspots per month, nominal/high confidence',
        'reference', 'VIIRS (S-NPP until 2018-03, NOAA-20 from 2018-04)',
        'method', 'One factor k per calendar month = median of VIIRS / Aqua over 2012-2021 in Mexico (before the MODIS orbit drift). 2012-02 on: VIIRS as observed (S-NPP, then NOAA-20 from 2018-04). 2002-07..2012-01: Aqua x k. Before 2002-07 only Terra flies: Terra x (Aqua/Terra factor, 2003-2011) x k. Areas with no S-NPP data (United States): Aqua x k until 2018-03. Vegetation fires, nominal/high confidence; NRT static sources removed. Low/high = 10th-90th percentile of the yearly ratios.',
        'areas', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'kind', kind, 'file', 'areas/' || id)
                                            ORDER BY sort_order, name), '[]'::jsonb) FROM areas))
    FROM (SELECT max(acq_date) AS d FROM hotspots) t;
$$;

-- The v2 tables (regional factors, error bins, local-correction params) are no longer read by anything.
DROP TABLE IF EXISTS harmonization_factors, harmonization_bins, harmonization_params;

SELECT refresh_static_sites();
SELECT refresh_harmonization_k();

GRANT SELECT ON static_sites, harmonization_calib, harmonization_k TO a11_web;
COMMIT;

-- Check after applying:  SELECT harmonization_validation_json();
