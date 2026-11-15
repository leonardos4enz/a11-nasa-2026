# Harmonization: details, validation and limits

## Can I compare 2005 with 2025?
Yes. That is the purpose of the harmonization: every month since January 2001 is expressed in VIIRS-equivalent
hotspots, so a month in 2005 can be compared with a month in 2025 on the same scale. The difference is certainty:
months before February 2012 are MODIS estimates and carry a low-high range, while months from February 2012 on are
VIIRS counts as observed. When citing an older month, give the range too.

## How to read the low-high range
Every MODIS-era month has a low-high range: the interquartile range (middle half) of the yearly VIIRS/Aqua ratios for
that calendar month in 2012-2021. Say "about N, most likely between low and high". For January 2001 to June 2002 the
range is wider, because it combines the Terra-to-Aqua factor and the Aqua-to-VIIRS factor.

## Why 2001 to mid-2002 has its own factor
Aqua started in July 2002, so before that only Terra observed. Terra passes at about 10:30, before the afternoon fire
peak, and sees fewer fires than Aqua. Those months are first moved to the "Aqua scale" with an Aqua/Terra factor per
calendar month learned in 2003-2011 (between about 1.08 in September and 1.65 in January), and
then multiplied by k. They are the least certain months of the series.

## Why the calibration uses only 2012-2021
Terra and Aqua are old and their orbits drift, so their overpass times change and so does how much fire they see.
Terra left its orbit in 2022 and NASA reports that the drift of Terra and Aqua got sharply worse at the end of 2024.
In Mexico the yearly VIIRS/Aqua ratio shows no clear trend after 2022 (predicting 2022-2025 with the 2012-2021 factors
gives errors between -8.7% and +7.0%), but the effect is still being studied, so those years are kept out.

## Why Aqua and not Terra + Aqua
Aqua passes at the same time as VIIRS (about 13:30), so comparing one satellite with one satellite at the same hour
gives a cleaner factor. Terra/Aqua fell from 0.85 in 2021 to 0.73 in 2025: Terra's overpass time is moving, which is
why it is not used for the calibration.

## Validation against CONAFOR reported fires
The hotspot series was compared with the 77,420 wildfires reported by CONAFOR in Mexico from 2015 to 2025. The
monthly correlation is r = 0.83 (0.93 in log scale). CONAFOR peaks in April and the satellites in May, because CONAFOR
records forest fires only, while satellites also see the agricultural burns that peak in May. CONAFOR 2015 looks
incomplete (about 3,500 fires versus about 7,000 in other years).

## Limits of the harmonization
- It assumes a fixed proportion per calendar month. If one year has a very different mix of fires (smaller or larger),
  its real factor can differ.
- The factors are national (Mexico) and apply to every area, including the United States. Small areas have few fires
  and their own ratio can differ from the country's: their numbers are noisier, so read the range.
- Zero does not mean no fire: clouds and smoke hide fires, and FIRMS does not say when a satellite could not see.
- Day and night detections are mixed (Aqua sees 6% of its hotspots at night, VIIRS 24%), and hotspots are counted,
  not fires, so one large fire can count several times.
- The United States has no S-NPP data in the database, so US areas use Aqua × k until NOAA-20 starts in April 2018.
- Recent near-real-time months have no fire type, so gas flares, refineries and volcanoes are removed with a map of
  known static sources built from the archive.

## A more detailed method that is not used yet
The team also designed and tested a regional version (factors per 1° cell and month, a local correction for each area
and a 10-90% range), which lowered the error in small mountain areas such as Sierra de Arteaga. It was left out of the
app to keep the method simple and easy to explain; it is documented as a future improvement.
