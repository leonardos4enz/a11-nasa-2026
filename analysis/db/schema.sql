-- A11 FIRMS hotspot store (PostgreSQL 17 + PostGIS 3.5)
-- Target: Easypanel service learn/a11-db, database "firms".
-- Idempotent: safe to run more than once.

CREATE EXTENSION IF NOT EXISTS postgis;

-- One row per FIRMS detection (MODIS or VIIRS, Standard Processing or NRT).
CREATE TABLE IF NOT EXISTS hotspots (
    id           bigserial PRIMARY KEY,
    sensor       text        NOT NULL CHECK (sensor IN ('MODIS', 'VIIRS')),
    satellite    text        NOT NULL,          -- Terra, Aqua, SNPP, NOAA20, NOAA21
    acq_date     date        NOT NULL,          -- UTC
    acq_time     smallint    NOT NULL,          -- HHMM, UTC
    latitude     real        NOT NULL,
    longitude    real        NOT NULL,
    geom         geometry(Point, 4326)
                 GENERATED ALWAYS AS (ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)) STORED,
    brightness   real,                          -- MODIS ch21/22 or VIIRS I-4 (K); not comparable across sensors
    bright_2     real,                          -- MODIS bright_t31 or VIIRS bright_ti5 (K)
    scan         real,
    track        real,
    confidence   text,                          -- raw value: MODIS 0-100, VIIRS l/n/h
    conf_class   char(1)     NOT NULL,          -- harmonized: l / n / h
    frp          real,                          -- MW
    daynight     char(1),
    fire_type    smallint,                      -- 0 vegetation, 1 volcano, 2 static land, 3 offshore; NULL in NRT
    version      text,
    processing   text        NOT NULL CHECK (processing IN ('SP', 'NRT')),
    country      text,
    loaded_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (satellite, acq_date, acq_time, latitude, longitude)
);

CREATE INDEX IF NOT EXISTS hotspots_date_idx ON hotspots (acq_date);
CREATE INDEX IF NOT EXISTS hotspots_geom_idx ON hotspots USING gist (geom);
CREATE INDEX IF NOT EXISTS hotspots_sat_date_idx ON hotspots (satellite, acq_date);

-- Bookkeeping for each pipeline run (historical loads and the daily NRT pull).
CREATE TABLE IF NOT EXISTS load_runs (
    id          bigserial PRIMARY KEY,
    job         text        NOT NULL,           -- e.g. 'sp_country_csv', 'nrt_area_api'
    source      text        NOT NULL,           -- file URL or API source name
    rows_in     integer,
    rows_new    integer,
    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    status      text        NOT NULL DEFAULT 'running',
    message     text
);

-- Monthly counts on a 0.25 degree grid: the input for calibration and the burning calendar.
-- Vegetation fires only (fire_type 0, or NULL for NRT rows that have no type yet).
CREATE MATERIALIZED VIEW IF NOT EXISTS monthly_grid AS
SELECT
    floor(latitude  / 0.25)::int            AS cell_y,
    floor(longitude / 0.25)::int            AS cell_x,
    date_trunc('month', acq_date)::date     AS month,
    satellite,
    sensor,
    count(*)                                AS hotspots,
    count(*) FILTER (WHERE conf_class <> 'l') AS hotspots_nominal_high,
    sum(frp)                                AS frp_sum
FROM hotspots
WHERE coalesce(fire_type, 0) = 0
GROUP BY 1, 2, 3, 4, 5;

CREATE UNIQUE INDEX IF NOT EXISTS monthly_grid_pk
    ON monthly_grid (cell_y, cell_x, month, satellite);

-- Refresh after each load (n8n runs this at the end of the daily workflow):
--   SELECT refresh_after_load();

-- Raw CSV bodies dropped here by n8n (one row per downloaded file / API response).
CREATE TABLE IF NOT EXISTS staging_csv (
    id          bigserial PRIMARY KEY,
    source      text NOT NULL,          -- URL without the MAP_KEY
    processing  text NOT NULL,          -- SP or NRT
    country     text,
    csv         text NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now()
);

-- Parse every staged CSV into hotspots, log it in load_runs, and empty the staging table.
-- Columns are located by header name, so MODIS/VIIRS, country files and API responses all work.
CREATE OR REPLACE FUNCTION load_staged() RETURNS TABLE (source text, rows_in integer, rows_new integer)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    s       record;
    hdr     text[];
    hdr_line text;
    n_in    integer;
    n_new   integer;
BEGIN
    FOR s IN SELECT * FROM staging_csv ORDER BY id LOOP
        hdr_line := split_part(s.csv, E'\n', 1);
        IF hdr_line NOT LIKE 'latitude,%' THEN
            INSERT INTO load_runs (job, source, rows_in, rows_new, finished_at, status, message, run_id)
            VALUES ('load_staged', s.source, 0, 0, now(), 'error', left(s.csv, 300), s.run_id);
            DELETE FROM staging_csv WHERE id = s.id;
            source := s.source; rows_in := 0; rows_new := 0; RETURN NEXT;
            CONTINUE;
        END IF;
        hdr := string_to_array(btrim(hdr_line, E'\r '), ',');

        WITH lines AS (
            SELECT string_to_array(btrim(l, E'\r '), ',') AS f
            FROM string_to_table(s.csv, E'\n') WITH ORDINALITY AS t(l, i)
            WHERE i > 1 AND btrim(l, E'\r ') <> ''
        ), parsed AS (
            SELECT
                f[array_position(hdr, 'latitude')]::real                         AS latitude,
                f[array_position(hdr, 'longitude')]::real                        AS longitude,
                nullif(f[coalesce(array_position(hdr, 'brightness'),
                                  array_position(hdr, 'bright_ti4'))], '')::real  AS brightness,
                nullif(f[coalesce(array_position(hdr, 'bright_t31'),
                                  array_position(hdr, 'bright_ti5'))], '')::real  AS bright_2,
                nullif(f[array_position(hdr, 'scan')], '')::real                 AS scan,
                nullif(f[array_position(hdr, 'track')], '')::real                AS track,
                f[array_position(hdr, 'acq_date')]::date                         AS acq_date,
                f[array_position(hdr, 'acq_time')]::smallint                     AS acq_time,
                f[array_position(hdr, 'satellite')]                              AS sat_raw,
                f[array_position(hdr, 'instrument')]                             AS instrument,
                f[array_position(hdr, 'confidence')]                             AS confidence,
                f[array_position(hdr, 'version')]                                AS version,
                nullif(f[array_position(hdr, 'frp')], '')::real                  AS frp,
                f[array_position(hdr, 'daynight')]                               AS daynight,
                CASE WHEN array_position(hdr, 'type') IS NOT NULL
                     THEN nullif(f[array_position(hdr, 'type')], '')::smallint END AS fire_type
            FROM lines
        ), ins AS (
            INSERT INTO hotspots (sensor, satellite, acq_date, acq_time, latitude, longitude,
                                  brightness, bright_2, scan, track, confidence, conf_class,
                                  frp, daynight, fire_type, version, processing, country)
            SELECT
                CASE WHEN upper(instrument) = 'MODIS' THEN 'MODIS' ELSE 'VIIRS' END,
                CASE sat_raw WHEN 'T' THEN 'Terra' WHEN 'A' THEN 'Aqua'
                             WHEN 'N' THEN 'SNPP' WHEN '1' THEN 'NOAA20' WHEN 'N20' THEN 'NOAA20'
                             WHEN 'N21' THEN 'NOAA21' ELSE sat_raw END,
                acq_date, acq_time, latitude, longitude, brightness, bright_2, scan, track,
                confidence,
                CASE WHEN lower(confidence) IN ('l', 'low')     THEN 'l'
                     WHEN lower(confidence) IN ('h', 'high')    THEN 'h'
                     WHEN lower(confidence) IN ('n', 'nominal') THEN 'n'
                     WHEN confidence ~ '^\d+$' THEN
                          CASE WHEN confidence::int < 30 THEN 'l'
                               WHEN confidence::int < 80 THEN 'n' ELSE 'h' END
                     ELSE 'n' END,
                frp, daynight, fire_type, version, s.processing, s.country
            FROM parsed
            ON CONFLICT (satellite, acq_date, acq_time, latitude, longitude) DO NOTHING
            RETURNING 1
        )
        SELECT (SELECT count(*) FROM lines), (SELECT count(*) FROM ins) INTO n_in, n_new;

        INSERT INTO load_runs (job, source, rows_in, rows_new, finished_at, status, run_id)
        VALUES ('load_staged', s.source, n_in, n_new, now(), 'ok', s.run_id);
        DELETE FROM staging_csv WHERE id = s.id;

        source := s.source; rows_in := n_in; rows_new := n_new; RETURN NEXT;
    END LOOP;
END $$;

-- After any load: drop NRT rows that Standard Processing now covers, then rebuild the monthly grid.
CREATE OR REPLACE FUNCTION refresh_after_load() RETURNS TABLE (nrt_removed integer, grid_rows bigint)
LANGUAGE plpgsql AS $$
DECLARE
    removed integer;
BEGIN
    WITH sp_end AS (
        SELECT satellite, max(acq_date) AS last_sp FROM hotspots WHERE processing = 'SP' GROUP BY satellite
    ), del AS (
        DELETE FROM hotspots h USING sp_end e
        WHERE h.processing = 'NRT' AND h.satellite = e.satellite AND h.acq_date <= e.last_sp
        RETURNING 1
    )
    SELECT count(*) INTO removed FROM del;

    REFRESH MATERIALIZED VIEW monthly_grid;

    nrt_removed := removed;
    grid_rows := (SELECT count(*) FROM monthly_grid);
    RETURN NEXT;
END $$;

-- ============================================================================================
-- Pipeline run tracking (for a status page on the website)
-- ============================================================================================

-- One row per pipeline execution (daily NRT, historical backfill, ...).
CREATE TABLE IF NOT EXISTS pipeline_runs (
    id               bigserial PRIMARY KEY,
    pipeline         text        NOT NULL,          -- 'daily_nrt', 'historical_backfill'
    trigger          text        NOT NULL,          -- 'schedule', 'manual'
    n8n_execution_id text,
    status           text        NOT NULL DEFAULT 'running'
                     CHECK (status IN ('running', 'success', 'partial', 'error')),
    started_at       timestamptz NOT NULL DEFAULT now(),
    finished_at      timestamptz,
    sources_expected integer,                       -- files / API calls planned
    sources_ok       integer,
    sources_error    integer,
    rows_in          bigint,
    rows_new         bigint,
    nrt_removed      integer,
    message          text
);
CREATE INDEX IF NOT EXISTS pipeline_runs_pipeline_idx ON pipeline_runs (pipeline, started_at DESC);
CREATE INDEX IF NOT EXISTS pipeline_runs_exec_idx ON pipeline_runs (n8n_execution_id);

-- Link each file/API load to its run.
ALTER TABLE load_runs   ADD COLUMN IF NOT EXISTS run_id bigint REFERENCES pipeline_runs (id);
ALTER TABLE staging_csv ADD COLUMN IF NOT EXISTS run_id bigint;
CREATE INDEX IF NOT EXISTS load_runs_run_idx ON load_runs (run_id);

-- Called by n8n right after the trigger. Returns the run id the rest of the workflow carries along.
CREATE OR REPLACE FUNCTION start_pipeline_run(p_pipeline text, p_trigger text, p_execution_id text)
RETURNS bigint LANGUAGE sql AS $$
    -- n8n execution modes: 'trigger' = schedule, 'manual'/'test' = run from the editor
    INSERT INTO pipeline_runs (pipeline, trigger, n8n_execution_id)
    VALUES (p_pipeline,
            CASE p_trigger WHEN 'trigger' THEN 'schedule' WHEN 'test' THEN 'manual' ELSE p_trigger END,
            p_execution_id)
    RETURNING id;
$$;

-- Called by n8n at the end. Totals come from load_runs; status is success / partial / error.
CREATE OR REPLACE FUNCTION finish_pipeline_run(p_run_id bigint, p_sources_expected integer,
                                               p_nrt_removed integer DEFAULT NULL)
RETURNS SETOF pipeline_runs LANGUAGE sql AS $$
    UPDATE pipeline_runs r SET
        finished_at      = now(),
        sources_expected = p_sources_expected,
        sources_ok       = t.ok,
        sources_error    = t.err,
        rows_in          = t.rows_in,
        rows_new         = t.rows_new,
        nrt_removed      = p_nrt_removed,
        status           = CASE WHEN t.err = 0 AND t.ok >= p_sources_expected THEN 'success'
                                WHEN t.ok = 0 THEN 'error'
                                ELSE 'partial' END,
        message          = CASE WHEN t.err > 0 THEN t.err || ' source(s) failed, see load_runs' END
    FROM (
        SELECT count(*) FILTER (WHERE status = 'ok')  AS ok,
               count(*) FILTER (WHERE status <> 'ok') AS err,
               coalesce(sum(rows_in), 0)  AS rows_in,
               coalesce(sum(rows_new), 0) AS rows_new
        FROM load_runs WHERE run_id = p_run_id
    ) t
    WHERE r.id = p_run_id
    RETURNING r.*;
$$;

-- Called by the n8n error workflow when an execution crashes.
CREATE OR REPLACE FUNCTION fail_pipeline_run(p_execution_id text, p_message text)
RETURNS SETOF pipeline_runs LANGUAGE sql AS $$
    UPDATE pipeline_runs SET status = 'error', finished_at = now(), message = left(p_message, 1000)
    WHERE n8n_execution_id = p_execution_id AND status = 'running'
    RETURNING *;
$$;

-- Latest run of each pipeline, with a derived health flag for the status page.
CREATE OR REPLACE VIEW pipeline_status AS
SELECT DISTINCT ON (pipeline)
    pipeline, id AS run_id, trigger, status, started_at, finished_at,
    extract(epoch FROM coalesce(finished_at, now()) - started_at)::int AS duration_s,
    sources_expected, sources_ok, sources_error, rows_new, message,
    CASE
        WHEN status = 'running' AND started_at < now() - interval '2 hours' THEN 'stalled'
        WHEN pipeline = 'daily_nrt' AND started_at < now() - interval '26 hours' THEN 'overdue'
        ELSE status
    END AS health
FROM pipeline_runs
ORDER BY pipeline, started_at DESC;

-- How fresh the data is, per satellite and processing level (rebuilt by refresh_after_load()).
CREATE MATERIALIZED VIEW IF NOT EXISTS data_freshness AS
SELECT satellite, sensor, processing,
       min(acq_date) AS first_date, max(acq_date) AS last_date,
       count(*) AS hotspots, max(loaded_at) AS last_loaded_at
FROM hotspots
GROUP BY satellite, sensor, processing;

-- Everything a status page needs, as one JSON document:  SELECT pipeline_status_json();
CREATE OR REPLACE FUNCTION pipeline_status_json() RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'generated_at', now(),
        'pipelines',  coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.pipeline) FROM pipeline_status p), '[]'),
        'recent_runs', coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.started_at DESC)
                                 FROM (SELECT id, pipeline, trigger, status, started_at, finished_at,
                                              sources_ok, sources_error, rows_new, message
                                       FROM pipeline_runs ORDER BY started_at DESC LIMIT 20) r), '[]'),
        'data', coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.satellite, d.processing) FROM data_freshness d), '[]'),
        'totals', jsonb_build_object(
            'hotspots', (SELECT count(*) FROM hotspots),
            'first_date', (SELECT min(acq_date) FROM hotspots),
            'last_date',  (SELECT max(acq_date) FROM hotspots))
    );
$$;

-- Redefined here so it also rebuilds data_freshness (supersedes the earlier definition).
CREATE OR REPLACE FUNCTION refresh_after_load() RETURNS TABLE (nrt_removed integer, grid_rows bigint)
LANGUAGE plpgsql AS $$
DECLARE
    removed integer;
BEGIN
    WITH sp_end AS (
        SELECT satellite, max(acq_date) AS last_sp FROM hotspots WHERE processing = 'SP' GROUP BY satellite
    ), del AS (
        DELETE FROM hotspots h USING sp_end e
        WHERE h.processing = 'NRT' AND h.satellite = e.satellite AND h.acq_date <= e.last_sp
        RETURNING 1
    )
    SELECT count(*) INTO removed FROM del;

    REFRESH MATERIALIZED VIEW monthly_grid;
    REFRESH MATERIALIZED VIEW data_freshness;

    nrt_removed := removed;
    grid_rows := (SELECT count(*) FROM monthly_grid);
    RETURN NEXT;
END $$;

-- Normalise trigger names written before start_pipeline_run() mapped them.
UPDATE pipeline_runs SET trigger = 'manual' WHERE trigger = 'test';
UPDATE pipeline_runs SET trigger = 'schedule' WHERE trigger = 'trigger';

-- ============================================================================================
-- Harmonized monthly series for the website (contract: web-hackathon/DATA_CONTRACT.md)
--
--   hotspots ─► polygon_monthly_raw(geom)    counts per month and satellite inside a polygon
--            ─► harmonize_polygon(geom)       >>> THE HARMONIZATION STEP (provisional, replace it) <<<
--            ─► harmonized_*_json()           the JSON documents served by web-hackathon/server.js
-- ============================================================================================

-- Areas offered in the calendar's area picker. Outlines are rough for now; replace with official boundaries.
CREATE TABLE IF NOT EXISTS areas (
    id         text PRIMARY KEY,
    name       text    NOT NULL,
    kind       text    NOT NULL,
    sort_order integer NOT NULL DEFAULT 0,
    geom       geometry(MultiPolygon, 4326) NOT NULL
);
INSERT INTO areas (id, name, kind, sort_order, geom) VALUES
    ('stgo', 'Santiago, Nuevo León', 'municipality', 1, ST_Multi(ST_GeomFromText(
        'POLYGON((-100.28 25.52,-100.05 25.53,-99.98 25.30,-100.18 25.20,-100.33 25.33,-100.28 25.52))', 4326))),
    ('arteaga', 'Sierra de Arteaga', 'drawn area · NL–Coahuila', 2, ST_Multi(ST_GeomFromText(
        'POLYGON((-100.85 25.48,-100.35 25.45,-100.30 25.15,-100.80 25.10,-100.85 25.48))', 4326))),
    ('ocos', 'Ocosingo, Chiapas', 'municipality', 3, ST_Multi(ST_GeomFromText(
        'POLYGON((-92.30 17.35,-91.30 17.20,-90.95 16.45,-91.95 16.55,-92.30 17.35))', 4326)))
ON CONFLICT (id) DO NOTHING;

-- United States: five contrasting fire regimes (rough outlines, like the Mexican ones).
INSERT INTO areas (id, name, kind, sort_order, geom) VALUES
    ('butte', 'Butte County, California', 'county · US · wildfire (Camp Fire 2018)', 11, ST_Multi(ST_GeomFromText(
        'POLYGON((-122.07 39.80,-121.95 40.15,-121.35 40.10,-121.08 39.85,-121.30 39.45,-121.60 39.29,-121.90 39.45,-122.07 39.80))', 4326))),
    ('flagstaff', 'Flagstaff & Coconino forests, Arizona', 'drawn area · US · forest fires', 12, ST_Multi(ST_GeomFromText(
        'POLYGON((-112.20 35.60,-111.00 35.60,-110.90 34.70,-111.60 34.55,-112.20 34.80,-112.20 35.60))', 4326))),
    ('flinthills', 'Flint Hills, Kansas', 'drawn area · US · spring rangeland burning', 13, ST_Multi(ST_GeomFromText(
        'POLYGON((-96.95 39.60,-96.35 39.60,-96.05 38.60,-96.10 37.60,-96.20 37.00,-96.75 37.00,-96.85 37.80,-97.00 38.70,-96.95 39.60))', 4326))),
    ('ardelta', 'Arkansas Delta', 'drawn area · US · crop-residue burning', 14, ST_Multi(ST_GeomFromText(
        'POLYGON((-91.60 35.90,-90.40 36.00,-90.10 35.10,-90.70 34.30,-91.20 33.90,-91.60 34.50,-91.60 35.90))', 4326))),
    ('everglades', 'Everglades & Big Cypress, Florida', 'drawn area · US · wetland and prescribed fire', 15, ST_Multi(ST_GeomFromText(
        'POLYGON((-81.50 26.35,-80.55 26.35,-80.45 25.65,-80.70 25.20,-81.15 25.10,-81.65 25.80,-81.50 26.35))', 4326)))
ON CONFLICT (id) DO NOTHING;

-- Ten more areas (five per country), also in areas_more.sql, which is how they were applied to the live database.
INSERT INTO areas (id, name, kind, sort_order, geom) VALUES
    ('chimalapas', 'Los Chimalapas, Oaxaca', 'drawn area · tropical forest (record fires 2024)', 4, ST_Multi(ST_GeomFromText(
        'POLYGON((-94.60 17.20,-93.90 17.20,-93.90 16.45,-94.60 16.45,-94.60 17.20))', 4326))),
    ('sepultura', 'Sierra Madre de Chiapas (La Sepultura)', 'drawn area · pine-oak forest', 5, ST_Multi(ST_GeomFromText(
        'POLYGON((-94.10 16.55,-93.40 16.55,-93.40 16.05,-94.10 16.05,-94.10 16.55))', 4326))),
    ('tarahumara', 'Sierra Tarahumara (Guachochi), Chihuahua', 'drawn area · pine forest (drought 2011)', 6, ST_Multi(ST_GeomFromText(
        'POLYGON((-107.60 27.30,-106.60 27.30,-106.60 26.40,-107.60 26.40,-107.60 27.30))', 4326))),
    ('calakmul', 'Calakmul, Campeche', 'municipality · tropical forest and farmland', 7, ST_Multi(ST_GeomFromText(
        'POLYGON((-90.25 18.85,-89.15 18.85,-89.15 17.82,-90.25 17.82,-90.25 18.85))', 4326))),
    ('tizimin', 'Tizimín, Yucatán', 'municipality · agricultural burning', 8, ST_Multi(ST_GeomFromText(
        'POLYGON((-88.25 21.55,-87.55 21.55,-87.55 20.90,-88.25 20.90,-88.25 21.55))', 4326))),
    ('okanogan', 'Okanogan, Washington', 'drawn area · US · wildfire (Carlton Complex 2014)', 16, ST_Multi(ST_GeomFromText(
        'POLYGON((-120.40 48.90,-119.30 48.90,-119.30 47.95,-120.40 47.95,-120.40 48.90))', 4326))),
    ('siskiyou', 'Klamath–Siskiyou, Oregon', 'drawn area · US · wildfire (Biscuit Fire 2002)', 17, ST_Multi(ST_GeomFromText(
        'POLYGON((-124.15 42.65,-123.30 42.65,-123.30 41.95,-124.15 41.95,-124.15 42.65))', 4326))),
    ('yosemite', 'Yosemite & Stanislaus, California', 'drawn area · US · wildfire (Rim Fire 2013)', 18, ST_Multi(ST_GeomFromText(
        'POLYGON((-120.30 38.25,-119.55 38.25,-119.55 37.65,-120.30 37.65,-120.30 38.25))', 4326))),
    ('plumas', 'Plumas County, California', 'drawn area · US · wildfire (Dixie Fire 2021)', 19, ST_Multi(ST_GeomFromText(
        'POLYGON((-121.45 40.45,-120.50 40.45,-120.50 39.80,-121.45 39.80,-121.45 40.45))', 4326))),
    ('okefenokee', 'Okefenokee Swamp, Georgia', 'drawn area · US · wetland fire (2007, 2011)', 20, ST_Multi(ST_GeomFromText(
        'POLYGON((-82.60 31.05,-82.10 31.05,-82.10 30.50,-82.60 30.50,-82.60 31.05))', 4326)))
ON CONFLICT (id) DO NOTHING;

-- Vegetation-fire detections per month and satellite inside a polygon (uses the hotspots_geom_idx index).
CREATE OR REPLACE FUNCTION polygon_monthly_raw(p_geom geometry)
RETURNS TABLE (month date, satellite text, hotspots bigint) LANGUAGE sql STABLE AS $$
    SELECT date_trunc('month', h.acq_date)::date, h.satellite, count(*)
    FROM hotspots h
    WHERE ST_Intersects(h.geom, p_geom) AND coalesce(h.fire_type, 0) = 0
    GROUP BY 1, 2;
$$;

-- >>> HARMONIZATION STEP — PROVISIONAL. Replace the body with the real method (docs/research/04-*.md);
--     keep the signature and everything downstream (JSON, server, page) keeps working.
-- One row per month from 2001-01 to the month of the latest detection, in VIIRS NOAA-20 units:
--   * from the first full NOAA-20 month on: the NOAA-20 count                              (source VIIRS)
--   * before: MODIS (Terra + Aqua) x k, k = median yearly NOAA-20/MODIS ratio of the polygon over the
--     overlap years; low/high use the 10th/90th percentile of those ratios. Polygons with too few fires
--     fall back to the ratio of the whole database.                                        (source MODIS_calibrated)
CREATE OR REPLACE FUNCTION harmonize_polygon(p_geom geometry)
RETURNS TABLE (month date, count integer, low integer, high integer, source text) LANGUAGE sql STABLE AS $$
    WITH last AS (SELECT max(acq_date) AS d FROM hotspots),
    v0 AS (  -- first full month with NOAA-20 data
        SELECT (date_trunc('month', min(first_date) - 1) + interval '1 month')::date AS m
        FROM data_freshness WHERE satellite = 'NOAA20'
    ),
    m AS (
        SELECT r.month,
               sum(r.hotspots) FILTER (WHERE r.satellite IN ('Terra', 'Aqua')) AS modis,
               sum(r.hotspots) FILTER (WHERE r.satellite = 'NOAA20')         AS viirs
        FROM polygon_monthly_raw(p_geom) r GROUP BY 1
    ),
    ratios AS (  -- one ratio per complete overlap year
        SELECT extract(year FROM m.month) AS y, sum(m.viirs)::float8 / nullif(sum(m.modis), 0) AS r
        FROM m, v0, last
        WHERE m.month >= v0.m AND m.month < date_trunc('year', last.d)
        GROUP BY 1 HAVING sum(m.modis) >= 5
    ),
    glob AS (
        SELECT coalesce(sum(g.hotspots) FILTER (WHERE g.satellite = 'NOAA20')::float8
                        / nullif(sum(g.hotspots) FILTER (WHERE g.satellite IN ('Terra', 'Aqua')), 0), 1) AS r
        FROM monthly_grid g, v0, last
        WHERE g.month >= v0.m AND g.month < date_trunc('year', last.d)
    ),
    k AS (
        SELECT coalesce((SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY r) FROM ratios), (SELECT r FROM glob))        AS k,
               coalesce((SELECT percentile_cont(0.1) WITHIN GROUP (ORDER BY r) FROM ratios), (SELECT r * 0.8 FROM glob))  AS k_lo,
               coalesce((SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY r) FROM ratios), (SELECT r * 1.25 FROM glob)) AS k_hi
    ),
    months AS (
        SELECT g::date AS month FROM last, generate_series(date '2001-01-01', date_trunc('month', last.d), interval '1 month') g
    )
    SELECT mo.month,
           CASE WHEN mo.month >= v0.m THEN coalesce(m.viirs, 0) ELSE round(k.k    * coalesce(m.modis, 0)) END::int,
           CASE WHEN mo.month >= v0.m THEN coalesce(m.viirs, 0) ELSE round(k.k_lo * coalesce(m.modis, 0)) END::int,
           CASE WHEN mo.month >= v0.m THEN coalesce(m.viirs, 0) ELSE round(k.k_hi * coalesce(m.modis, 0)) END::int,
           CASE WHEN mo.month >= v0.m THEN 'VIIRS' ELSE 'MODIS_calibrated' END
    FROM months mo CROSS JOIN k CROSS JOIN v0 LEFT JOIN m ON m.month = mo.month
    ORDER BY mo.month;
$$;

-- The "months" array of the contract for any polygon; the month of the latest detection is marked partial.
CREATE OR REPLACE FUNCTION harmonized_polygon_json(p_geom geometry) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT coalesce(jsonb_agg(
               jsonb_build_object('month', to_char(h.month, 'YYYY-MM'), 'count', h.count,
                                  'low', h.low, 'high', h.high, 'source', h.source)
               || CASE WHEN h.month = date_trunc('month', (SELECT max(acq_date) FROM hotspots))
                       THEN '{"partial": true}'::jsonb ELSE '{}'::jsonb END
             ORDER BY h.month), '[]'::jsonb)
    FROM harmonize_polygon(p_geom) h;
$$;

-- index.json of the contract:  SELECT harmonized_index_json();
CREATE OR REPLACE FUNCTION harmonized_index_json() RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'schema_version', 1,
        'synthetic', false,
        'provisional', true,   -- set to false once harmonize_polygon() holds the final method
        'generated_at', to_char(coalesce((SELECT max(last_loaded_at) FROM data_freshness), now()) AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'data_through', to_char(t.d, 'YYYY-MM-DD'),
        'baseline', jsonb_build_object('first_year', 2001, 'last_year', extract(year FROM t.d)::int - 1),
        'units', 'VIIRS-equivalent vegetation-fire hotspots per month',
        'reference', 'VIIRS (NOAA-20)',
        'method', 'PROVISIONAL: NOAA-20 counts; earlier months = MODIS x median yearly NOAA-20/MODIS ratio of the area',
        'areas', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'kind', kind, 'file', 'areas/' || id)
                                            ORDER BY sort_order, name), '[]'::jsonb) FROM areas))
    FROM (SELECT max(acq_date) AS d FROM hotspots) t;
$$;

-- areas/<id>.json of the contract:  SELECT harmonized_area_json('stgo');   (NULL if the id does not exist)
CREATE OR REPLACE FUNCTION harmonized_area_json(p_id text) RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'id', a.id, 'name', a.name, 'kind', a.kind,
        'polygon', (SELECT jsonb_agg(jsonb_build_array(round(ST_Y(d.geom)::numeric, 4), round(ST_X(d.geom)::numeric, 4))
                                     ORDER BY d.path)
                    FROM ST_DumpPoints(ST_ExteriorRing(ST_GeometryN(a.geom, 1))) d),
        'months', harmonized_polygon_json(a.geom))
    FROM areas a WHERE a.id = p_id;
$$;

-- A polygon drawn in the page (GeoJSON geometry text):  SELECT harmonized_drawn_json('{"type":"Polygon",...}');
CREATE OR REPLACE FUNCTION harmonized_drawn_json(p_geojson text) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    g   geometry := ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(p_geojson), 4326));
    km2 float8   := ST_Area(g::geography) / 1e6;
BEGIN
    IF km2 > 100000 THEN
        RAISE EXCEPTION 'Area too large: % km2 (max 100,000)', round(km2::numeric);
    END IF;
    RETURN jsonb_build_object('area_km2', round(km2::numeric), 'months', harmonized_polygon_json(g));
END $$;

-- Read-only role for the website. Created without login; enable it once with your own password:
--   ALTER ROLE a11_web LOGIN PASSWORD '<password>';
-- then set DATABASE_URL=postgres://a11_web:<password>@learn_a11-db:5432/firms on the web-hackathon service.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'a11_web') THEN CREATE ROLE a11_web NOLOGIN; END IF;
END $$;
GRANT CONNECT ON DATABASE firms TO a11_web;
GRANT USAGE ON SCHEMA public TO a11_web;
GRANT SELECT ON hotspots, areas, monthly_grid, data_freshness, pipeline_runs, pipeline_status TO a11_web;

-- Analyst role for a collaborator working on our data. Created without login; enable it once with your own password:
--   ALTER ROLE a11_analyst LOGIN PASSWORD '<password>';
-- Reads everything in public (current and future tables), owns the "analyst" schema for its own tables and
-- functions, and cannot modify the pipeline objects. Limits keep heavy queries from starving the daily load.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'a11_analyst') THEN CREATE ROLE a11_analyst NOLOGIN; END IF;
END $$;
ALTER ROLE a11_analyst CONNECTION LIMIT 5;
ALTER ROLE a11_analyst SET statement_timeout = '10min';
ALTER ROLE a11_analyst SET idle_in_transaction_session_timeout = '15min';
GRANT CONNECT, TEMPORARY ON DATABASE firms TO a11_analyst;
GRANT USAGE ON SCHEMA public TO a11_analyst;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO a11_analyst;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO a11_analyst;
CREATE SCHEMA IF NOT EXISTS analyst AUTHORIZATION a11_analyst;

-- ---------------------------------------------------------------------------------------------
-- Memory of the Ember agent (web-hackathon/chat-agent.js): one row per chat message, grouped by the browser's sessionId.
-- msg is {r: "human"|"ai"|"tool", c: text, tc: [tool calls], id: tool_call_id}. Idempotent; also part of schema.sql.
-- The website role a11_web may only read and append; the analyst role does not see the conversations.
CREATE TABLE IF NOT EXISTS chat_messages (
    id          bigserial PRIMARY KEY,
    session_id  text        NOT NULL,
    msg         jsonb       NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS chat_messages_session_idx ON chat_messages (session_id, id);
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'a11_web') THEN CREATE ROLE a11_web NOLOGIN; END IF;
END $$;
GRANT SELECT, INSERT ON chat_messages TO a11_web;
GRANT USAGE ON SEQUENCE chat_messages_id_seq TO a11_web;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'a11_analyst') THEN REVOKE ALL ON chat_messages FROM a11_analyst; END IF;
END $$;
-- Housekeeping (optional, e.g. monthly): DELETE FROM chat_messages WHERE created_at < now() - interval '30 days';

-- ---------------------------------------------------------------------------------------------
-- Document search (RAG) of the Ember agent (web-hackathon/rag.js): one row per section of web-hackathon/knowledge/*.md
-- with its OpenAI embedding. The website re-indexes on start: it inserts new sections (by content hash) and deletes
-- the ones that no longer exist. Vectors are plain real[]; the similarity search runs in the server, so pgvector is
-- not needed. Idempotent; also part of schema.sql.
CREATE TABLE IF NOT EXISTS rag_chunks (
    hash        text PRIMARY KEY,          -- sha256 of model + embedded text
    source      text        NOT NULL,      -- file name in knowledge/
    section     text        NOT NULL,
    content     text        NOT NULL,
    model       text        NOT NULL,      -- embedding model, e.g. text-embedding-3-small
    embedding   real[]      NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'a11_web') THEN CREATE ROLE a11_web NOLOGIN; END IF;
END $$;
GRANT SELECT, INSERT, DELETE ON rag_chunks TO a11_web;
