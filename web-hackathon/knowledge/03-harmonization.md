# How the counts are harmonized

## Goal
Every month from January 2001 to today is expressed in the same unit: VIIRS-equivalent vegetation-fire hotspots.
VIIRS is the reference because it is the sensor that keeps flying after MODIS is switched off, so the series can keep
growing with new data without recalculating anything.

## The problem
Joined as they are, the records lie. VIIRS (375 m pixels) sees smaller fires than MODIS (1 km pixels) and separates
fires that MODIS lumps into one pixel, so it counts many more hotspots for the same fires. In Mexico, VIIRS counts
about 8 times more hotspots than Aqua in the same place and month. Without harmonization the series would seem to
jump when VIIRS starts: that jump is the sensor, not the fire.

## One reference satellite per sensor
Following the INPE (Brazil) rule, each sensor is represented by one satellite and satellites are never added up,
because adding a newly launched satellite creates a false jump.
- MODIS side: Aqua, which passes at about 13:30 like VIIRS. Terra passes at 10:30, sees fewer fires and its orbit is
  drifting.
- VIIRS side: S-NPP until March 2018, NOAA-20 from April 2018. In 2019-2021, with both in orbit, S-NPP counted
  1.01 times what NOAA-20 counted, so they can be chained without a factor.

## The method in five steps
1. Divide: for each month, VIIRS hotspots divided by Aqua hotspots over Mexico, with exactly the same filters
   (Standard Processing, vegetation fires, nominal/high confidence).
2. Median: repeat for every year of the clean overlap, 2012-2021, and take the median. 2022 on is left out because
   the MODIS orbits drift. The middle half of the years (interquartile range) is the uncertainty.
3. Per month: twelve factors k, one per calendar month, because the gap changes with the season (June needs about
   ×10.7 and January about ×5.9 in the method study).
4. Translate: July 2002 to January 2012 = Aqua × k. Before July 2002 only Terra flew: Terra × an Aqua/Terra factor
   (learned in 2003-2011) × k. From February 2012 on, VIIRS as observed.
5. Compare: each month against the median of the same calendar month in past years, which colours the calendar.

## Uncertainty
MODIS-era months (before February 2012) carry a low-high range: the interquartile range of the yearly VIIRS/Aqua
ratios for that calendar month. VIIRS months are observed and have no range. The timeline marks the "MODIS era" so
users know which years are estimated.

## Validation
Each year of 2012-2021 was hidden in turn, k was computed with the other nine years, and the hidden year was
predicted from Aqua and compared with what VIIRS really counted. In the method study the typical error on the yearly
total for Mexico was 3.7% (worst year 2015, +11.5%), and 6.5% for a single month. Quiet months with a few hundred
hotspots can be off much more (January 2012 came out about double). The Method tab of the calendar repeats this check
for the area on screen.
