# Space Apps 2026 submission — Team A11 (copy into the project form)

Form: https://www.spaceappschallenge.org/2026/find-a-team/a11/?tab=project → Edit.
Deadline: **Sunday Nov 15, 2026, 23:59 (Monterrey time)**. "Save Progress" does not submit: click **Submit for Judging**.

---

## Project Name

Ember Atlas: a harmonized burning activity calendar from 25 years of MODIS and VIIRS hotspots

## Summary (≤ 1500 characters, 50–200 words)

Ember Atlas is a web application that turns 25 years of NASA FIRMS active-fire hotspots into one consistent burning
activity calendar for any area of interest. MODIS (2000→) and VIIRS (2012→) cannot be compared directly: VIIRS sees
several times more hotspots, so joining the raw records makes fire seem to explode after 2012. We convert MODIS to
the VIIRS scale with one factor per calendar month (median VIIRS ÷ Aqua over 2012–2021) and an uncertainty band,
validated by leaving each year out (3.7% typical error on the yearly total for Mexico). Users pick a
municipality, draw a polygon or enter coordinates, and see a month-by-year calendar from 2001 to this week, how the
current month compares with its historical normal range, the fire season, detected vs reported fires, and a 72-hour
forecast. Everything downloads as CSV, PNG or a one-page report. Ember, an assistant that uses the page, explains the
numbers in plain language. It helps fire managers, civil protection, land managers and researchers see when burning
is critical and whether today is unusual.

## Project Demonstration (public link)

https://emberatlas.ink/deck.html

(7 slides including the title. Keep it at 7 or fewer. If you also record a video, it must be 30 seconds or less.)

## Project (public link)

https://github.com/leonardos4enz/a11-nasa-2026

(Live app: https://emberatlas.ink — mention it in Project Details.)

## Project Details

**What it does.** Ember Atlas is a burning activity calendar built on harmonized NASA FIRMS hotspots. Live at
https://emberatlas.ink. For any area of interest (a municipality or protected area from the list, a polygon drawn on
the map, or a circle around a latitude/longitude) it shows:

- A calendar of monthly hotspots from 2001 to today (month × year heatmap with a sequential color ramp), so the
  critical months and the most active years stand out at a glance.
- The selected month against the same month in the previous 25 years: median, normal range (middle third of past
  years), percentile and a plain-language label from "much below" to "record high", colored with a
  colorblind-safe diverging ramp (ColorBrewer RdBu).
- The fire season (months holding 80% of hotspots, peak month) and what usually comes next.
- Detected vs reported fires: hotspots against CONAFOR wildfire records (Mexico) and NIFC incidents (United States).
- A 72-hour forecast of the chance of detecting fire in the area, from our FireCast model.
- A map with the individual hotspots, filters by FIRMS fire type and FRP, and the forecast layer.
- Downloads for any date range: hotspots CSV, monthly calendar CSV, calendar and charts as PNG, one-page summary.

**How the harmonization works.** VIIRS is the reference scale (S-NPP until March 2018, NOAA-20 after), with one
reference satellite per sensor so a new launch never creates a jump. On the MODIS side we use Aqua, which passes at
13:30 like VIIRS. Five steps: divide VIIRS by Aqua for each month in Mexico; take the median over 2012–2021, before the
MODIS orbit drift; keep twelve factors, one per calendar month, because the gap changes with the season; translate
2002–2011 as Aqua × k (Terra-only months first go to the Aqua scale with their own factor); and compare each month with
its historical median. The interquartile range of the yearly ratios is the uncertainty band. All sensors use the same
filters (vegetation fires, nominal/high confidence); gas flares and volcanoes are removed from the near-real-time feed
(95.6% of static detections removed, 1.5% of vegetation fires lost, tested out of sample). Validation by
leave-one-year-out: 3.7% typical error on the yearly total for Mexico (worst year +11.5%), and r = 0.83 monthly against
77,420 fires reported by CONAFOR 2015–2025. After harmonization the sensor of origin no longer matters; the patterns,
trends and anomalies do.

**FireCast (72 h forecast).** LightGBM on VIIRS NOAA-20 history in 0.25° cells (recent hotspots, FRP, fire days,
neighbours, climatology, season). Trained on 2024 and tested on all of 2025: AUC 0.914 vs 0.849 for climatology and
0.814 for persistence, and calibrated (says 72% → happened 69%).

**Ember, the assistant.** A LangChain agent that answers questions about the area on screen and can operate the page
(search an area, change the month, show layers). It cites only numbers from the page, its tools or our documentation
(search over our own docs), and checks every figure in its reply before answering.

**Benefits and impact.** Fire managers and civil protection can see if the current month is outside the normal range
and when the season starts; land managers can plan prescribed burns and patrols; municipalities can set burn
calendars (Mexico's NOM-015 asks them to); researchers get a long, consistent series without sensor jumps.

**Tools and languages.** NASA FIRMS (Standard Processing archive + Area API NRT), n8n pipelines (daily refresh),
PostgreSQL 17 + PostGIS (hotspot storage, polygon counts and harmonization in SQL), Python (sensor comparison, validation,
data exploration), Node.js server, HTML/CSS/JavaScript with Leaflet for the web app, LightGBM for FireCast,
LangChain + MiniMax for Ember, OpenAI embeddings for the document search, Docker on Easypanel for hosting.

**Creativity and decisions.** We chose a method simple enough to explain in five steps: one factor per calendar month
instead of a single global factor, because the VIIRS/Aqua ratio changes with the season (about ×5.9 in January to
×10.7 in June). We also built and tested a regional version (factors per 1° cell and a local correction per area) that
is more accurate in small areas, and documented it as a future improvement instead of shipping the extra complexity.
Every estimate carries an uncertainty band. The calendar puts the current month next to its own history, not next to
a global average. Areas cover both Mexico and the United States. Method and limits:
`docs/research/14-harmonization-simple.md` (national factors from Mexico; US areas use Aqua × k until NOAA-20).

## Use of Super Intelligence (SI) — select what applies

Suggested selections (check against the form's exact options):

- Code: yes — AI coding assistant (Claude by Anthropic) for parts of the code, SQL and pipelines, reviewed by the team.
- Data processing / analysis: yes — scripts drafted with AI help; every number is reproducible from `analysis/`.
- Text: yes — documentation drafts, reviewed by the team.
- In the product: the Ember assistant runs on an LLM (MiniMax) with OpenAI embeddings for document search.
- Images / video / audio: only select if any were generated with AI (they must then carry a visible SI watermark).

Where it is disclosed in the project: README section "AI (SI) assistance disclosure" and the last slide of the deck.

## NASA Data (Link Text → Link URL)

| Link Text | Link URL |
|---|---|
| NASA FIRMS — Fire Information for Resource Management System | https://www.earthdata.nasa.gov/data/tools/firms |
| FIRMS archive download (MODIS C6.1 and VIIRS 375 m, Standard Processing) | https://firms.modaps.eosdis.nasa.gov/download/ |
| FIRMS Area API (near real-time hotspots) | https://firms.modaps.eosdis.nasa.gov/api/area/ |
| MODIS Collection 6.1 Active Fire product (MCD14) | https://www.earthdata.nasa.gov/data/instruments/modis/near-real-time-data |
| VIIRS 375 m Active Fire product (VNP14IMG / VJ114IMG) | https://www.earthdata.nasa.gov/data/instruments/viirs/viirs-i-band-375-m-active-fire-data |
| LANCE — Land, Atmosphere Near real-time Capability for Earth observations | https://www.earthdata.nasa.gov/data/projects/lance |

## Space Agency Partner & Other Data (Link Text → Link URL)

| Link Text | Link URL |
|---|---|
| CONAFOR wildfire records (Mexico), datos.gob.mx, CC BY 4.0 | https://datos.gob.mx/ |
| NIFC WFIGS wildland fire incident locations (United States) | https://data-nifc.opendata.arcgis.com/ |
| Esri basemap (with HERE, Garmin, OpenStreetMap contributors) | https://www.esri.com/ |
| OpenStreetMap contributors | https://www.openstreetmap.org/copyright |
| Leaflet (map library) | https://leafletjs.com/ |
| PostGIS | https://postgis.net/ |
| n8n (data pipelines) | https://n8n.io/ |
| LightGBM (FireCast model) | https://github.com/microsoft/LightGBM |
| LangChain.js (Ember agent) | https://js.langchain.com/ |
| MiniMax (LLM behind Ember) | https://www.minimax.io/ |
| OpenAI embeddings (document search) | https://platform.openai.com/docs/guides/embeddings |
| Claude by Anthropic (AI coding assistant) | https://www.anthropic.com/claude |
| Project source code | https://github.com/leonardos4enz/a11-nasa-2026 |

Before submitting, check that each link opens without a login, and add any other library or image you used.

## Final checklist

- [ ] All fields above filled in, in English.
- [ ] "About the Team" on the team page in English (it currently says "Equipo de programadores"), e.g.
      "Three developers from Monterrey building tools on NASA fire data."
- [ ] Both verification boxes ticked (terms; original work and all resources listed).
- [ ] **Submit for Judging** clicked before 23:59; the notification bar confirms it.
- [ ] Backup for the 2-minute local pitch: screenshots or a short screen recording in case the site or Wi-Fi fails.
