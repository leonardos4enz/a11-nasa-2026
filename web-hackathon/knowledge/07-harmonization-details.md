# Harmonization: details, validation and limits

## Can I compare 2005 with 2025?
Yes. That is the purpose of the harmonization: every month since January 2001 is expressed in VIIRS NOAA-20-equivalent
hotspots, so a month in 2005 can be compared with a month in 2025 on the same scale. The difference is certainty:
months before April 2018 are estimates and carry a low-high range, while months from April 2018 on are NOAA-20
counts as observed. When citing an older month, give the range too.

## How to read the low-high range
Every month before April 2018 has a low-high range: the 10th to 90th percentile of past prediction errors. This
includes MODIS months (2001 to January 2012) and S-NPP months (February 2012 to March 2018). Example: Ocosingo,
Chiapas, April 2005 shows 2,045 hotspots, with a range of 1,602 to 2,440; say "about 2,045, most likely between 1,602
and 2,440". In validation the range contained the true value 80-84% of the time for MODIS months.

## Why 2001 to mid-2002 has its own factor
Aqua started in July 2002, so before that only Terra observed. Terra passes at about 10:30, before the afternoon fire
peak, and alone it sees roughly half of what Terra plus Aqua see. Applying the Terra plus Aqua factor to those months
would make 2001 and early 2002 about 50% too low. Ember Atlas uses a separate Terra-only factor for January 2001 to
June 2002 (national error 5.5%).

## Why MODIS is calibrated only with 2012-2023
Terra and Aqua are old and their orbits drift, so their overpass times change and so does how much fire they see. In
the database the Aqua/Terra ratio stays between 1.07 and 1.23 through 2023, then jumps to 1.35 in 2024, 1.39 in 2025
and 1.60 in 2026. Calibrating with those years would bias the factors, so MODIS is matched to S-NPP only on
February 2012 to December 2023.

## Why not use only Aqua as the MODIS reference
Aqua passes at about 13:30, the same time as VIIRS, so it looks like the natural match. It was tested with the same
leave-one-year-out check on 2012-2021: Aqua alone gave 4.2% monthly error for Mexico and 23.6% on 1° cells, versus
3.3% and 20.3% with Terra plus Aqua. Aqua alone has half the detections, so its factors are noisier.

## Validation against CONAFOR reported fires
The hotspot series was compared with the 77,420 wildfires reported by CONAFOR in Mexico from 2015 to 2025. The
monthly correlation is r = 0.83 (0.93 in log scale). CONAFOR peaks in April and the satellites in May, because CONAFOR
records forest fires only, while satellites also see the agricultural burns that peak in May. CONAFOR 2015 looks
incomplete (about 3,500 fires versus about 7,000 in other years).

## Validation by area
Leave-one-year-out monthly error (WAPE), MODIS to VIIRS, first method versus the current one: Mexico 5.4% to 3.6%,
1° cells 23.0% to 20.7%, Sierra de Arteaga 36.6% to 25.8%, Ocosingo 16.8% to 14.6%, Santiago 35.9% to 34.0%.
Small areas with few fires, like Santiago, have larger monthly errors; yearly totals are more accurate than single
months.

## Limits of the harmonization
The regional factors were calibrated in Mexico; outside Mexico the Mexican national factor for each calendar month
applies, plus each area's own local correction. The United States has no S-NPP data in the database, so US areas
calibrate MODIS straight to NOAA-20 for every month before April 2018. The Method tab shows a simpler check (one
NOAA-20/MODIS ratio per area); the calendar itself uses the full method.
