# 72-hour forecast: reading it, accuracy and limits

## Why "29%" can be "Low risk"
The forecast card shows two different numbers. The big percentage is the chance that at least one hotspot appears
anywhere in the area in the next 72 hours: 1 minus the product of (1 minus p) over the 0.25° cells that touch the
area. The risk label comes from the riskiest single cell. So 29% with "Low risk" means no single cell is likely to
burn (the riskiest might be 11%), but across several cells the chance that one of them shows a hotspot adds up.

## Forecast risk levels
Each 0.25° cell (about 28 km) gets a probability of at least one VIIRS NOAA-20 vegetation hotspot in the next 72 hours.
Levels: Very high 80% or more, High 50% to 80%, Moderate 20% to 50%, Low under 20%. The area's level is the level of
its riskiest cell. The forecast is always for the next 72 hours from today, whatever month the timeline shows.

## How accurate the forecast is
FireCast was trained on 2024 and tested on all of 2025, 3.0 million cell-days it never saw (11% had fire). AUC 0.914,
versus 0.849 for climatology alone and 0.814 for "fire in the last 7 days". It is well calibrated: when it says 72%,
fire was detected 69% of the time; when it says 50% or more, about 3 times out of 4 (74.5%); under 5%, only 1.5%.

## What the forecast model uses
FireCast is a LightGBM model on a global 0.25° grid. Inputs: hotspots in the last 1, 3, 7 and 30 days, days with fire,
fire radiative power, days since the last fire, the same for neighbouring cells, the cell's usual activity for that
time of year (taken from a different year to avoid leakage), latitude, longitude and season. The strongest signals
are fire days in the last 30 days and days since the last fire. The live model is retrained on 2024 plus 2025.

## How the forecast is updated
The forecast service downloads the last 30 days of VIIRS NOAA-20 near-real-time detections from NASA FIRMS and is
refreshed every 3 hours. It is issued with data through yesterday (UTC) and covers the next three days. Known static
heat sources (gas flares, volcanoes, industry) are removed first. Its API documentation is at
http://31.170.165.34:8080/docs; the site calls it through /api/forecast/.

## Limits of the forecast
It learns from fire history and season only: no weather, wind, fuel moisture or land use. It cannot foresee a fire in
a place with no recent or seasonal fire activity. Satellites also miss fires under clouds or too small, and most fires
in Mexico are human burns whose timing depends on people. It is a statistical guide, not an official warning; use
CONAFOR and civil protection for decisions.
