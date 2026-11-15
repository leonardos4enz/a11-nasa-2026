# Satellites, hotspots and FIRMS

## What a hotspot is
A hotspot (active-fire detection) is a satellite pixel whose thermal-infrared signal is much hotter than its
surroundings at the moment the satellite passes. It is evidence of something burning in that pixel, not a confirmed
fire: one large fire produces many hotspots, a small or short fire between overpasses may produce none, and clouds,
smoke or tree canopy can hide fires. Hotspot counts are an index of burning activity, not a count of fires.

## MODIS
MODIS flies on Terra (morning and evening overpasses, since 2000) and Aqua (afternoon and night, since mid-2002). Its
fire pixels are about 1 km at nadir. MODIS is the long record that makes 25-year baselines possible, but Terra's
and Aqua's orbits have been drifting, which changes their overpass times; Ember Atlas stops calibrating MODIS against VIIRS after
2023 for that reason.

## VIIRS
VIIRS flies on Suomi NPP (2012 until it stopped delivering data on 2 November 2026), NOAA-20 (since 2018) and NOAA-21
(since 2023). Its 375 m fire product sees smaller fires and splits large fires into more pixels. On Mexico 2019-2024
NOAA-20 recorded about 4.3 times more hotspots than MODIS Terra+Aqua, yet the monthly series of both sensors correlate
at r = 0.995: the timing of the fire season is the same, the difference is mostly scale. The ratio changes with the
month (from about 3.2x to 5.9x), so a single global factor is not enough.

## FIRMS
NASA's Fire Information for Resource Management System (FIRMS) distributes both products. Standard Processing (SP)
data are the consistent archive, downloadable per country and year. Near Real-Time (NRT) data arrive within about
3 hours and are later replaced by SP. Ember Atlas loads the SP archive and refreshes NRT every day at 06:00.

## Fire type, confidence and FRP
- Fire type (SP only): 0 = presumed vegetation fire, 1 = active volcano, 2 = other static land source (industry, gas
  flares, mines), 3 = offshore. The calendar counts vegetation fires only. NRT rows have no type, so Ember Atlas
  removes NRT detections on known static-source cells (in testing this removed about 96% of static detections and
  only 1.5% of vegetation ones).
- Confidence: VIIRS gives low, nominal or high; MODIS gives 0-100. The series uses nominal and high confidence.
- FRP (fire radiative power, in megawatts) measures how intensely a pixel is burning. The map filter groups it into
  low (under 10 MW), moderate (10-50 MW) and high (50 MW or more).
