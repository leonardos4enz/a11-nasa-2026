-- Ten more areas for the calendar's area picker (five in Mexico, five in the United States), chosen for active,
-- well-known fire histories. Outlines are rough, like the first eight. Idempotent: safe to run again.
-- Applied live through the n8n workflow "A11 Areas (add more)"; the same rows are in schema.sql for fresh setups.
-- Do NOT re-run the whole schema.sql on the live database: it would put back the provisional harmonize_polygon().
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
