# How the counts are harmonized

## Goal
Every month from January 2001 to today is expressed in the same unit: VIIRS NOAA-20-equivalent vegetation-fire
hotspots. NOAA-20 is the reference because it is the current, long-lived VIIRS sensor.

## Chain of calibrations
Each link is calibrated where two real sensors overlap:
- April 2018 to now: NOAA-20 as it is.
- February 2012 to March 2018: S-NPP, scaled by the NOAA-20/S-NPP factor (about 1.00, by calendar month).
- July 2002 to January 2012: MODIS Terra+Aqua, scaled to S-NPP and then to NOAA-20.
- January 2001 to June 2002: Terra alone (Aqua was not flying yet), with its own factor.

## Factors by region and month
Factors are estimated for each 1° region and calendar month. Regions with few fires borrow strength from the national
value through hierarchical shrinkage, so a handful of detections cannot produce a wild factor. Inside each area there
is also a local correction: areas with many fires use their own observed ratio, areas with few keep the regional one.
This is what fixed Sierra de Arteaga, a mountain range with large forest fires whose ratio differs from the farmland
around it.

## Uncertainty
Months before April 2018 (MODIS, and S-NPP scaled to NOAA-20) carry a low-high range (10th-90th percentile of past
prediction errors). NOAA-20 months (April 2018 on) are observed and have no range. The timeline marks the "MODIS era" so users know which years are estimated.

## Validation
Each overlap year was hidden in turn, the factors were fitted on the other years, and the hidden year was predicted
from MODIS and compared with what VIIRS really saw. Monthly error (WAPE) for Mexico fell from 5.4% with a simple
single ratio to 3.6% with this method, and from 23.0% to 20.7% on 1° cells. The 10-90% range covered the true value
about 80% of the time, as intended. The Method tab of the calendar repeats a simpler version of this check for the
area on screen and shows the MODIS/VIIRS ratio and how well the two agree month by month.
