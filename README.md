# A11 — Harmonization of MODIS and VIIRS Hot Spots

**2026 NASA Space Apps Challenge** · Team **A11** · Monterrey
Challenge: [Harmonization of MODIS and VIIRS Hot Spots](https://www.spaceappschallenge.org/2026/challenges/modis-and-viirs-hot-spots/)

> Build a web application that harmonizes 25 years of satellite active-fire hotspots (MODIS 2000→ and
> VIIRS 2012→) into a consistent **burning activity calendar**, so responders, scientists and land managers
> can see when and where burning happens, which periods are critical, and whether current activity is unusual.

**Live app: https://emberatlas.ink** · Pitch deck (7 slides): https://emberatlas.ink/deck.html

## What Ember Atlas does

- **Burning activity calendar** (month × year, 2001 → this week) for any area: a listed municipality or protected
  area in Mexico or the United States, a polygon drawn on the map, or a circle around a latitude/longitude.
- **Harmonized series:** MODIS (Terra/Aqua) and Suomi NPP are calibrated to the VIIRS NOAA-20 scale by 1° region and
  calendar month, with a local correction per polygon and a 10–90% uncertainty band. Validated by leaving each year
  out: **3.6% monthly error for Mexico** (first single-ratio method: 5.4%); r = 0.83 monthly against 77,420 fires
  reported by CONAFOR (2015–2025). Method and limits: [doc 13](docs/research/13-harmonization-v2.md).
- **Is this month unusual?** The selected month against the same month in the previous 25 years (median, normal
  range, percentile, category from "much below" to "record high"), the fire season and what usually comes next.
- **Detected vs reported fires:** hotspots against CONAFOR (Mexico) and NIFC WFIGS (United States).
- **72 h forecast** from FireCast (LightGBM on VIIRS NOAA-20, AUC 0.914 on all of 2025). See
  [FORECAST.md](web-hackathon/FORECAST.md).
- **Downloads** for any date range: hotspots CSV, monthly calendar CSV, calendar and charts as PNG, one-page report.
- **Ember**, an assistant that answers about the area on screen and can operate the page; it only cites numbers from
  the page, its tools or our documentation ([web-hackathon/README.md](web-hackathon/README.md)).
- **Daily data:** n8n pipelines load the FIRMS archive and the near-real-time feed into PostgreSQL + PostGIS
  ([n8n/README.md](n8n/README.md)); gas flares and volcanoes are removed from the recent months.

## Status

Phase 1 — Research & study ✅
Phase 2 — Harmonization pipeline ✅ (v2, validated)
Phase 3 — Web platform ✅ (live at emberatlas.ink, refreshed daily)
Phase 4 — Demo & submission ✅

## Key findings

- The only official resource is **NASA FIRMS**. Historical Standard Processing data can be downloaded per
  country and year **without login**; recent data come from the FIRMS Area API (free MAP_KEY).
- On Mexico 2019–2024, **VIIRS NOAA-20 detects ~4.2× more hotspots than MODIS (Terra+Aqua)**, but the monthly
  series correlate at **r ≈ 0.995** → the fire *timing* is consistent; harmonization is mainly a *scale*
  problem. The ratio varies by month (3.2×–5.9×), so a single global factor is not enough.
- **Suomi NPP stopped delivering data on Nov 2, 2026.** VIIRS continuity is NOAA-20 / NOAA-21.
- Method used: **calibration chain through real sensor overlaps, by region and calendar month**
  (MODIS → S-NPP → NOAA-20) plus **anomaly/percentile views** for the calendar.

## Research documents

| # | Document |
|---|---|
| 01 | [Challenge brief](docs/research/01-challenge-brief.md) |
| 02 | [Data sources: NASA FIRMS](docs/research/02-data-sources-firms.md) |
| 03 | [MODIS vs VIIRS empirical comparison](docs/research/03-sensor-comparison.md) |
| 04 | [Harmonization approaches](docs/research/04-harmonization-approaches.md) |
| 05 | [Web app requirements & architecture](docs/research/05-web-app-requirements.md) |
| 06 | [Submission rules that affect us](docs/research/06-submission-rules.md) |
| 07 | [Understanding the data (satellites, coverage, a reading, the overlap)](docs/research/07-understanding-the-data.md) |
| 08 | [End users](docs/research/08-end-users.md) |
| 09 | [User research and use cases](docs/research/09-user-research-and-use-cases.md) |
| 10 | [Interface design](docs/research/10-interface-design.md) |
| 11 | [UI audit and references](docs/research/11-ui-audit-and-references.md) |
| 12 | [Harmonization: state of the art](docs/research/12-harmonization-state-of-the-art.md) |
| 13 | [Harmonization v2: regional calibration, validated](docs/research/13-harmonization-v2.md) |
| — | [References](docs/research/references.md) |

## Interactive Fire Data Explorer

A 3D globe that shows every satellite's hotspots on a grid, simulates each orbit's coverage over 24 hours,
and explains every field of a reading (research tool used before harmonizing). See [web/README.md](web/README.md).

```bash
python web/server.py
```

## Repository structure

```
.
├── docs/research/     Phase 1 study, harmonization method and validation
├── analysis/          Python: sensor comparison, harmonization (pull → calibrate → build_sql → test_sql)
│   └── db/            SQL: schema, harmonization v2, chat memory, document search
├── n8n/               Data pipelines (FIRMS archive + daily NRT → PostgreSQL/PostGIS)
├── web-hackathon/     The deployed app (emberatlas.ink): Node server, calendar page, Ember, deck, knowledge docs
├── web/               Fire Data Explorer (research globe) and early mockup
└── data/              Data folder (raw downloads are git-ignored; see data/README.md)
```

## Team A11 (Monterrey)

Leonardo Sáenz · José Ángel Ipiña · Abiel Jefté Ramírez

## Quick start (analysis)

```bash
python analysis/sensor_overlap.py --country Mexico --years 2019 2020 2021 2022 2023 2024
```
Requires Python 3.10+. `sensor_overlap.py` uses the standard library only; `build_explorer_data.py` also
needs `numpy`. Downloads are cached in `data/raw/`.

## Configuration (FIRMS API key)

```bash
cp .env.example .env   # then set FIRMS_MAP_KEY=<your key>
```
Get a free key at https://firms.modaps.eosdis.nasa.gov/api/map_key/. `.env` is git-ignored: never commit the key
or expose it in front-end code. Needed only for recent NRT data and for VIIRS NOAA-21.

## Data acknowledgment

We acknowledge the use of data and/or imagery from NASA's Fire Information for Resource Management System
(FIRMS) (https://earthdata.nasa.gov/firms), part of NASA's Land, Atmosphere Near real-time Capability for Earth
observations (LANCE) (https://earthdata.nasa.gov/lance) and NASA's Earth Science Data and Information System
(ESDIS).

## AI (SI) assistance disclosure

As required by the Space Apps 2026 SI rules, we disclose where AI tools were used:

- **Code and data processing:** parts of the code (web app, Node server, SQL, n8n pipelines, Python analysis and
  harmonization scripts) were drafted with an AI coding assistant (Claude, by Anthropic) and reviewed, tested and
  validated by the team. All quantitative results are reproducible with the scripts in `analysis/`.
- **Text:** research documents, READMEs and the knowledge documents were drafted with AI assistance and reviewed by
  the team.
- **In the product:** the Ember assistant runs on a large language model (MiniMax, via LangChain) and uses OpenAI
  embeddings to search our own documents (`web-hackathon/knowledge/`). The page tells users that Ember can be wrong.
- No NASA logos or branding were generated or modified with AI.
