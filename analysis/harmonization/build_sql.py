"""Generates analysis/db/harmonization_v2.sql from the calibrate.py factors.

    python analysis/harmonization/build_sql.py

The SQL is idempotent and replaces the provisional harmonize_polygon() without changing its signature
(contract: web-hackathon/DATA_CONTRACT.md), so the server and the page do not change.
"""
from __future__ import annotations

import json
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "data" / "harmonization"
OUT = ROOT / "analysis" / "db" / "harmonization_v2.sql"

from calibrate import BETA, LINKS  # noqa: E402

METHOD = ("Reference VIIRS NOAA-20 (2018-04 on). 2012-02..2018-03: S-NPP x NOAA-20/S-NPP factor. "
          "2002-07..2012-01: MODIS Terra+Aqua x MODIS->S-NPP factor; before 2002-07: Terra-only factor. "
          "Factors per 1-degree region and calendar month, shrunk to the national month factor, plus a "
          "local correction for the polygon. Areas with no S-NPP data (United States): MODIS/Terra calibrated straight "
          "to NOAA-20 through 2018-03. Factors calibrated on Mexico; elsewhere the Mexican national month factors apply. "
          "Vegetation fires, nominal/high confidence; NRT static sources removed. "
          "Low/high = 10-90% range from leave-one-year-out validation.")


def body(S: str) -> str:
    """S = schema prefix for objects created here ('' in production, 'pg_temp.' for testing)."""
    return f"""
-- Static sources (volcanoes, industry, platforms) on a 0.01° (~1 km) grid, derived from the
-- SP rows that do carry fire_type: cells with >= 3 static detections that are also >= 50 % of their detections.
-- NRT rows carry no fire_type: they are dropped if they fall in one of those cells or a neighbouring one.
-- Validated out of sample (sites from SP <= 2024, tested on NOAA-20 2025): removes 95.6 % of the static
-- detections and only 1.5 % of the vegetation ones.
CREATE TABLE IF NOT EXISTS {S}static_sites (fy int NOT NULL, fx int NOT NULL, PRIMARY KEY (fy, fx));

CREATE OR REPLACE FUNCTION {S}refresh_static_sites() RETURNS bigint LANGUAGE sql AS $$
    TRUNCATE {S}static_sites;
    INSERT INTO {S}static_sites
    SELECT floor(latitude / 0.01)::int, floor(longitude / 0.01)::int
    FROM hotspots WHERE processing = 'SP' AND fire_type IS NOT NULL
    GROUP BY 1, 2
    HAVING count(*) FILTER (WHERE fire_type IN (1, 2, 3)) >= 3
       AND count(*) FILTER (WHERE fire_type IN (1, 2, 3)) >= 0.5 * count(*);
    SELECT count(*) FROM {S}static_sites;
$$;

CREATE OR REPLACE FUNCTION {S}is_static_site(p_lat real, p_lon real) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM {S}static_sites s
                   WHERE s.fy BETWEEN floor(p_lat / 0.01)::int - 1 AND floor(p_lat / 0.01)::int + 1
                     AND s.fx BETWEEN floor(p_lon / 0.01)::int - 1 AND floor(p_lon / 0.01)::int + 1);
$$;

-- Counts per 1° cell, month and satellite inside a polygon, with the harmonization filters.
CREATE OR REPLACE FUNCTION {S}polygon_monthly_cells(p_geom geometry)
RETURNS TABLE (ry int, rx int, month date, satellite text, n bigint) LANGUAGE sql STABLE AS $$
    SELECT floor(h.latitude)::int, floor(h.longitude)::int, date_trunc('month', h.acq_date)::date, h.satellite, count(*)
    FROM hotspots h
    WHERE ST_Intersects(h.geom, p_geom)
      AND h.conf_class <> 'l'
      AND (h.fire_type = 0 OR (h.fire_type IS NULL AND NOT {S}is_static_site(h.latitude, h.longitude)))
    GROUP BY 1, 2, 3, 4;
$$;

-- >>> HARMONIZATION STEP (v2). Same signature as the provisional version.
CREATE OR REPLACE FUNCTION {S}harmonize_polygon(p_geom geometry)
RETURNS TABLE (month date, count integer, low integer, high integer, source text) LANGUAGE sql STABLE AS $$
    WITH last AS (SELECT max(acq_date) AS d FROM hotspots),
    raw AS (SELECT * FROM {S}polygon_monthly_cells(p_geom)),
    cm AS (   -- cell-month, with the cell's factors (or the national month factor if the cell has none)
        SELECT r.month, r.ry, r.rx, extract(month FROM r.month)::int AS m,
               sum(r.n) FILTER (WHERE r.satellite = 'NOAA20')          AS n20,
               sum(r.n) FILTER (WHERE r.satellite = 'SNPP')            AS snpp,
               sum(r.n) FILTER (WHERE r.satellite IN ('Terra', 'Aqua')) AS modis,
               sum(r.n) FILTER (WHERE r.satellite = 'Terra')           AS terra
        FROM raw r GROUP BY 1, 2, 3, 4
    ),
    cmk AS (
        SELECT cm.*,
               coalesce(fm.k, nm.k) AS k_modis, coalesce(ft.k, nt.k) AS k_terra, coalesce(fs.k, ns.k) AS k_snpp
        FROM cm
        LEFT JOIN {S}harmonization_factors fm ON fm.link = 'MODIS' AND fm.ry = cm.ry AND fm.rx = cm.rx AND fm.m = cm.m
        LEFT JOIN {S}harmonization_factors nm ON nm.link = 'MODIS' AND nm.ry = -999 AND nm.m = cm.m
        LEFT JOIN {S}harmonization_factors ft ON ft.link = 'TERRA' AND ft.ry = cm.ry AND ft.rx = cm.rx AND ft.m = cm.m
        LEFT JOIN {S}harmonization_factors nt ON nt.link = 'TERRA' AND nt.ry = -999 AND nt.m = cm.m
        LEFT JOIN {S}harmonization_factors fs ON fs.link = 'SNPP' AND fs.ry = cm.ry AND fs.rx = cm.rx AND fs.m = cm.m
        LEFT JOIN {S}harmonization_factors ns ON ns.link = 'SNPP' AND ns.ry = -999 AND ns.m = cm.m
    ),
    pm AS (   -- polygon-month: real counts and regional predictions for each link
        SELECT month, max(m) AS m,
               coalesce(sum(n20), 0) AS n20, coalesce(sum(snpp), 0) AS snpp,
               coalesce(sum(k_modis * modis), 0) AS p_modis,   -- MODIS in S-NPP units
               coalesce(sum(k_terra * terra), 0) AS p_terra,   -- Terra in S-NPP units
               coalesce(sum(k_snpp * snpp), 0)  AS p_snpp      -- S-NPP in NOAA-20 units
        FROM cmk GROUP BY month
    ),
    par AS (SELECT link, beta, overlap_from, overlap_to FROM {S}harmonization_params),
    corr AS (   -- local polygon correction, shrunk toward 1 with beta
        SELECT
          (SELECT (sum(pm.snpp) + p.beta) / (sum(pm.p_modis) + p.beta) FROM pm, par p
            WHERE p.link = 'MODIS' AND pm.month BETWEEN p.overlap_from AND p.overlap_to GROUP BY p.beta) AS c_modis,
          (SELECT (sum(pm.snpp) + p.beta) / (sum(pm.p_terra) + p.beta) FROM pm, par p
            WHERE p.link = 'TERRA' AND pm.month BETWEEN p.overlap_from AND p.overlap_to GROUP BY p.beta) AS c_terra,
          (SELECT (sum(pm.n20) + p.beta) / (sum(pm.p_snpp) + p.beta) FROM pm, par p
            WHERE p.link = 'SNPP' AND pm.month BETWEEN p.overlap_from AND p.overlap_to GROUP BY p.beta) AS c_snpp,
          -- Fallback without S-NPP (US: the backfill does not download it). MODIS/Terra -> NOAA-20 directly:
          -- regional k to S-NPP x national k S-NPP->NOAA-20, corrected in the polygon against NOAA-20 (2018-04..2025-12).
          (SELECT (sum(pm.n20) + p.beta) / (sum(ns.k * pm.p_modis) + p.beta) FROM pm, par p, par q,
                  {S}harmonization_factors ns
            WHERE p.link = 'MODIS' AND q.link = 'SNPP' AND ns.link = 'SNPP' AND ns.ry = -999 AND ns.m = pm.m
              AND pm.month BETWEEN q.overlap_from AND q.overlap_to GROUP BY p.beta) AS c_modis_n20,
          (SELECT (sum(pm.n20) + p.beta) / (sum(ns.k * pm.p_terra) + p.beta) FROM pm, par p, par q,
                  {S}harmonization_factors ns
            WHERE p.link = 'TERRA' AND q.link = 'SNPP' AND ns.link = 'SNPP' AND ns.ry = -999 AND ns.m = pm.m
              AND pm.month BETWEEN q.overlap_from AND q.overlap_to GROUP BY p.beta) AS c_terra_n20,
          -- Does the polygon have S-NPP in its overlaps (2012-02..2025-12)? If not, the fallback is used.
          coalesce((SELECT sum(pm.snpp) > 0 FROM pm, par a, par b
                     WHERE a.link = 'MODIS' AND b.link = 'SNPP' AND pm.month BETWEEN a.overlap_from AND b.overlap_to),
                   false) AS has_snpp
    ),
    months AS (
        SELECT g::date AS month, extract(month FROM g)::int AS m
        FROM last, generate_series(date '2001-01-01', date_trunc('month', last.d), interval '1 month') g
    ),
    est AS (
        SELECT mo.month,
               CASE WHEN mo.month >= date '2018-04-01' THEN 'N20'
                    WHEN mo.month >= date '2012-02-01' AND c.has_snpp THEN 'SNPP'
                    WHEN mo.month >= date '2002-07-01' THEN 'MODIS'
                    ELSE 'TERRA' END AS era,
               CASE WHEN mo.month >= date '2018-04-01' THEN coalesce(pm.n20, 0)::float8
                    WHEN mo.month >= date '2012-02-01' AND c.has_snpp THEN coalesce(c.c_snpp, 1) * coalesce(pm.p_snpp, 0)
                    WHEN mo.month >= date '2002-07-01' AND c.has_snpp
                         THEN coalesce(c.c_snpp, 1) * ns.k * coalesce(c.c_modis, 1) * coalesce(pm.p_modis, 0)
                    WHEN mo.month >= date '2002-07-01' THEN ns.k * coalesce(c.c_modis_n20, 1) * coalesce(pm.p_modis, 0)
                    WHEN c.has_snpp THEN coalesce(c.c_snpp, 1) * ns.k * coalesce(c.c_terra, 1) * coalesce(pm.p_terra, 0)
                    ELSE ns.k * coalesce(c.c_terra_n20, 1) * coalesce(pm.p_terra, 0) END AS h
        FROM months mo CROSS JOIN corr c
        LEFT JOIN pm ON pm.month = mo.month
        LEFT JOIN {S}harmonization_factors ns ON ns.link = 'SNPP' AND ns.ry = -999 AND ns.m = mo.m
    )
    SELECT e.month,
           round(e.h)::int,
           CASE WHEN e.era = 'N20' THEN round(e.h)::int
                ELSE greatest(0, floor((e.h + 1) * exp(b.q_lo) - 1))::int END,
           CASE WHEN e.era = 'N20' THEN round(e.h)::int
                ELSE ceil((e.h + 1) * exp(b.q_hi) - 1)::int END,
           CASE WHEN e.era IN ('N20', 'SNPP') THEN 'VIIRS' ELSE 'MODIS_calibrated' END
    FROM est e
    LEFT JOIN {S}harmonization_bins b
           ON b.link = CASE e.era WHEN 'SNPP' THEN 'SNPP' WHEN 'MODIS' THEN 'MODIS' ELSE 'TERRA' END
          AND e.h >= b.pred_min AND e.h < b.pred_max
    ORDER BY e.month;
$$;
"""


def main() -> None:
    fac = pd.read_parquet(DATA / "factors.parquet")
    bins = pd.read_parquet(DATA / "bins.parquet")
    val = json.loads((DATA / "validation.json").read_text(encoding="utf-8"))

    fac_rows = ",\n".join(f"('{r.link}',{int(r.ry)},{int(r.rx)},{int(r.m)},{r.k:.6f})" for r in fac.itertuples())
    bin_rows = ",\n".join(f"('{r.link}',{r.pred_min:g},{r.pred_max:g},{r.q_lo:.6f},{r.q_hi:.6f})" for r in bins.itertuples())
    par_rows = ",\n".join(f"('{k}',{BETA[k]},date '{LINKS[k][2]}',date '{LINKS[k][3]}')" for k in ("SNPP", "MODIS", "TERRA"))

    tables = """
CREATE TABLE IF NOT EXISTS {S}harmonization_factors (
    link text NOT NULL,      -- 'SNPP' (S-NPP -> NOAA-20), 'MODIS' (Terra+Aqua -> S-NPP), 'TERRA' (Terra -> S-NPP)
    ry   int  NOT NULL,      -- floor(latitude)  of the 1° cell; -999 = national month factor
    rx   int  NOT NULL,      -- floor(longitude) of the 1° cell; -999 = national month factor
    m    smallint NOT NULL,  -- calendar month 1-12
    k    float8 NOT NULL,
    PRIMARY KEY (link, ry, rx, m)
);
CREATE TABLE IF NOT EXISTS {S}harmonization_bins (   -- 10-90 % range by estimate size
    link text NOT NULL, pred_min float8 NOT NULL, pred_max float8 NOT NULL, q_lo float8 NOT NULL, q_hi float8 NOT NULL,
    PRIMARY KEY (link, pred_min)
);
CREATE TABLE IF NOT EXISTS {S}harmonization_params (
    link text PRIMARY KEY, beta float8 NOT NULL, overlap_from date NOT NULL, overlap_to date NOT NULL
);
TRUNCATE {S}harmonization_factors, {S}harmonization_bins, {S}harmonization_params;
INSERT INTO {S}harmonization_factors (link, ry, rx, m, k) VALUES
""" + fac_rows + """;
INSERT INTO {S}harmonization_bins (link, pred_min, pred_max, q_lo, q_hi) VALUES
""" + bin_rows + """;
INSERT INTO {S}harmonization_params (link, beta, overlap_from, overlap_to) VALUES
""" + par_rows + ";\n"

    m = val["links"]["MODIS"]
    header = f"""-- A11 harmonization v2 (generated by analysis/harmonization/build_sql.py — do not edit by hand)
-- NOT USED BY THE APP: improved regional method kept for reference (docs/research/13). The app applies analysis/db/harmonization.sql.
-- Apply AFTER analysis/db/schema.sql (e.g. as an extra step of the "A11 DB setup" workflow). Idempotent.
--
-- Validation (leave-one-year-out, MODIS -> S-NPP, 2012-2023, monthly WAPE, current -> v2):
--   national {m['nacional']['actual']['error_mensual_wape']:.1%} -> {m['nacional']['nuevo']['error_mensual_wape']:.1%}
--   1° cells {m['celdas_1grado']['actual']['error_mensual_wape']:.1%} -> {m['celdas_1grado']['nuevo']['error_mensual_wape']:.1%}
--   areas    """ + ", ".join(f"{a} {v['actual']['error_mensual_wape']:.1%} -> {v['nuevo']['error_mensual_wape']:.1%}"
                              for a, v in m["areas"].items()) + """
-- Details: docs/research/13-harmonization-v2.md
BEGIN;
"""
    index_fn = f"""
-- index.json: method updated, provisional = false.
CREATE OR REPLACE FUNCTION harmonized_index_json() RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'schema_version', 1,
        'synthetic', false,
        'provisional', false,
        'generated_at', to_char(coalesce((SELECT max(last_loaded_at) FROM data_freshness), now()) AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'data_through', to_char(t.d, 'YYYY-MM-DD'),
        'baseline', jsonb_build_object('first_year', 2001, 'last_year', extract(year FROM t.d)::int - 1),
        'units', 'VIIRS-equivalent (NOAA-20) vegetation-fire hotspots per month, nominal/high confidence',
        'reference', 'VIIRS (NOAA-20)',
        'method', '{METHOD}',
        'areas', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'kind', kind, 'file', 'areas/' || id)
                                            ORDER BY sort_order, name), '[]'::jsonb) FROM areas))
    FROM (SELECT max(acq_date) AS d FROM hotspots) t;
$$;

SELECT refresh_static_sites();

GRANT SELECT ON static_sites, harmonization_factors, harmonization_bins, harmonization_params TO a11_web;
COMMIT;
"""
    sql = header + tables.replace("{S}", "") + body("") + index_fn
    OUT.write_text(sql, encoding="utf-8")
    # Variant for testing in a temporary session (everything in pg_temp, the public schema is untouched).
    test = tables.replace("{S}", "pg_temp.") + body("pg_temp.") + "SELECT pg_temp.refresh_static_sites();\n"
    (DATA / "harmonization_v2_test.sql").write_text(test, encoding="utf-8")
    print(f"OK {OUT} ({OUT.stat().st_size/1024:.0f} KB, {len(fac)} factors)")


if __name__ == "__main__":
    main()
