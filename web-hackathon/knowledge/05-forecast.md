# The 72-hour fire forecast

## What it is
FireCast is the team's forecast model. It estimates, for each 0.25° grid cell, the probability of at least one VIIRS
hotspot in the next 72 hours. It is a LightGBM model trained on the NOAA-20 detection history and runs on the team
server, refreshed every 3 hours from the latest FIRMS NOAA-20 near-real-time detections.

## Where it appears
A dashed block after the current month on the timeline shows the chance of any hotspot in the area in the next
72 hours, coloured by risk. The Overview tab has a "Next 72 hours" forecast card, and the map layer "72 h forecast"
colours each cell by risk, with the probability and the hotspots of the last 7 days in its tooltip.

## How to read it
The area's chance combines its cells (the chance that at least one of them has a hotspot), so large areas get higher
numbers than small ones for the same local risk. The riskiest cell tells where to look first. It is a statistical
forecast based on recent fire activity and seasonality; it does not use weather forecasts and is not an official
warning. "What usually comes next" in the Overview is a different thing: the historical pattern of the next month.
