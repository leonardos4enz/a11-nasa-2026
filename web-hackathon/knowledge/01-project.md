# Ember Atlas — the project

## What Ember Atlas is
Ember Atlas is the Burning Activity Calendar built by Team A11 (Monterrey, Mexico) for the 2026 NASA Space Apps
Challenge "Harmonization of MODIS and VIIRS Hot Spots". It turns 25 years of satellite active-fire detections into
one consistent monthly series per area, so people can see when and where burning happens, which months are critical,
and whether the current activity is unusual. The site is https://emberatlas.ink.

## The problem it solves
NASA has detected fires from space with MODIS (on Terra since 2000 and Aqua since 2002) and with VIIRS (S-NPP from
2012, NOAA-20 from 2018, NOAA-21 from 2023). VIIRS has finer pixels (375 m vs 1 km), so it detects several times more
hotspots than MODIS for the same fires. Joining the raw records makes every year after VIIRS look like an explosion
of fire. Ember Atlas harmonizes the older MODIS counts into "VIIRS-equivalent" counts so the whole 2001-to-today
record can be compared fairly.

## Who it is for
Fire managers and civil protection (is this month worse than normal? when does the season start?), land managers and
protected-area staff (planning prescribed burns and patrols), researchers and journalists (long, consistent series),
and farmers or communities that follow burn regulations.

## Data sources
- NASA FIRMS active-fire products: MODIS Collection 6.1 and VIIRS 375 m (S-NPP, NOAA-20, NOAA-21), Standard
  Processing for history and Near Real-Time (NRT) for recent days.
- CONAFOR reported wildfires (Mexico, 2015-2025) and NIFC WFIGS incident locations (United States) for the
  "detected vs reported" comparison.
- FireCast, the team's own 72-hour forecast model trained on VIIRS NOAA-20 history.

## Areas covered
The calendar ships with 18 areas of interest in Mexico and the United States.

- Mexico: Santiago (Nuevo León), Sierra de Arteaga, Ocosingo (Chiapas), Los Chimalapas (Oaxaca, record fires in
  2024), the Sierra Madre de Chiapas (La Sepultura), the Sierra Tarahumara (Guachochi, Chihuahua, record year 2011),
  Calakmul (Campeche) and Tizimín (Yucatán, agricultural burning).
- United States: Butte County (California, Camp Fire 2018), the Flagstaff and Coconino forests (Arizona), the Flint
  Hills (Kansas), the Arkansas Delta, the Everglades (Florida), Okanogan (Washington, Carlton Complex 2014),
  Klamath–Siskiyou (Oregon, Biscuit Fire 2002), Yosemite and Stanislaus (California, Rim Fire 2013), Plumas County
  (California, Dixie Fire 2021) and the Okefenokee Swamp (Georgia, 2007 and 2011).

Users can also draw their own polygon or create a circle around a point; any area up to 100,000 km² is computed on
the fly.

## How it is built
A daily n8n pipeline downloads FIRMS data into a PostgreSQL/PostGIS database. SQL functions count hotspots per month
inside each polygon and apply the harmonization. A small Node.js server exposes the series to the web page, proxies
the forecast and runs Ember, the assistant: a LangChain agent on MiniMax that can use the page, with memory in
Postgres and document search over these files with OpenAI embeddings.
