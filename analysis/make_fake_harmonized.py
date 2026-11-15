"""
Write FAKE harmonized data for the Burning Activity Calendar (web-hackathon/public/).

The site reads harmonized monthly counts from web-hackathon/public/data/harmonized/ using the contract in
web-hackathon/DATA_CONTRACT.md. Until the real harmonization exists, this script fills those files with a
synthetic series (seasonal profile x random year factor) so the page already runs on the real format.

When the real data is ready, write an exporter (e.g. analysis/export_harmonized.py, reading a11-db) that
produces the same files with "synthetic": false. The page does not need to change.

Usage:
  python analysis/make_fake_harmonized.py                  # data_through = today (UTC)
  python analysis/make_fake_harmonized.py --through 2026-11-14
"""
import argparse
import calendar
import datetime as dt
import json
import math
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "web-hackathon" / "public" / "data" / "harmonized"
FIRST_YEAR = 2001
BASELINE_LAST = 2025
LAST_MODIS_ONLY_YEAR = 2011  # months up to here are MODIS converted to VIIRS-equivalent

# Seasonal shape per area (typical monthly counts) and fixed values for some months of the current year.
AREAS = [
    {
        "id": "stgo", "name": "Santiago, Nuevo León", "kind": "municipality",
        "polygon": [[25.52, -100.28], [25.53, -100.05], [25.30, -99.98], [25.20, -100.18], [25.33, -100.33]],
        "prof": [18, 42, 150, 118, 62, 22, 7, 5, 3, 4, 7, 11], "current": {0: 30, 1: 96, 2: 412, 3: 265, 10: 9},
    },
    {
        "id": "arteaga", "name": "Sierra de Arteaga", "kind": "drawn area · NL–Coahuila",
        "polygon": [[25.48, -100.85], [25.45, -100.35], [25.15, -100.30], [25.10, -100.80]],
        "prof": [10, 25, 95, 110, 70, 30, 6, 4, 2, 2, 4, 6], "current": {2: 180, 3: 240},
    },
    {
        "id": "ocos", "name": "Ocosingo, Chiapas", "kind": "municipality",
        "polygon": [[17.35, -92.30], [17.20, -91.30], [16.45, -90.95], [16.55, -91.95]],
        "prof": [40, 160, 620, 1450, 980, 120, 15, 8, 6, 8, 12, 20], "current": {3: 2410, 4: 1900},
    },
]


def mulberry32(seed):
    """Deterministic PRNG (same as the original in-page generator), so every run gives the same series."""
    s = seed & 0xFFFFFFFF

    def imul(a, b):
        return (a * b) & 0xFFFFFFFF

    def nxt():
        nonlocal s
        s = (s + 0x6D2B79F5) & 0xFFFFFFFF
        t = imul(s ^ (s >> 15), 1 | s)
        t = ((t + imul(t ^ (t >> 7), 61 | t)) & 0xFFFFFFFF) ^ t
        return ((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296

    return nxt


def js_round(x):
    return math.floor(x + 0.5)


def series(area, seed, through):
    r, months = mulberry32(seed), []
    for y in range(FIRST_YEAR, through.year + 1):
        yf = math.exp((r() - 0.5) * 1.1) * (1 + (y - FIRST_YEAR) * 0.008)
        for m0 in range(12):
            full = max(0, js_round(area["prof"][m0] * yf * math.exp((r() - 0.5) * 0.9)))
            if y == through.year and m0 in area["current"]:
                full = area["current"][m0]
            if y == through.year and m0 + 1 > through.month:
                continue  # future month
            partial = y == through.year and m0 + 1 == through.month
            count = js_round(full * through.day / calendar.monthrange(y, m0 + 1)[1]) if partial else full
            modis = y <= LAST_MODIS_ONLY_YEAR
            row = {
                "month": f"{y}-{m0 + 1:02d}",
                "count": count,
                "low": js_round(count * 0.82) if modis else count,
                "high": js_round(count * 1.2) if modis else count,
                "source": "MODIS_calibrated" if modis else "VIIRS",
            }
            if partial:
                row["partial"] = True
            months.append(row)
    return months


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--through", help="last day with data, YYYY-MM-DD (default: today UTC)")
    args = ap.parse_args()
    through = dt.date.fromisoformat(args.through) if args.through else dt.datetime.now(dt.timezone.utc).date()

    (OUT / "areas").mkdir(parents=True, exist_ok=True)
    index = {
        "schema_version": 1,
        "synthetic": True,
        "generated_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "data_through": through.isoformat(),
        "baseline": {"first_year": FIRST_YEAR, "normal_first_year": max(FIRST_YEAR, 2003), "last_year": BASELINE_LAST},
        "units": "VIIRS-equivalent vegetation-fire hotspots per month",
        "reference": "VIIRS (NOAA-20)",
        "method": "FAKE: seasonal profile x random year factor. Replace with overlap calibration (docs/research/04).",
        "areas": [{"id": a["id"], "name": a["name"], "kind": a["kind"], "file": f"areas/{a['id']}.json"} for a in AREAS],
    }
    (OUT / "index.json").write_text(json.dumps(index, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    for i, a in enumerate(AREAS):
        months = series(a, 1234 + i * 97, through)
        head = ",\n".join(f'  "{k}": {json.dumps(a[k], ensure_ascii=False)}' for k in ("id", "name", "kind", "polygon"))
        lines = ",\n".join("    " + json.dumps(m, ensure_ascii=False) for m in months)  # one month per line
        (OUT / "areas" / f"{a['id']}.json").write_text(f'{{\n{head},\n  "months": [\n{lines}\n  ]\n}}\n', encoding="utf-8")

    print(f"Wrote {len(AREAS)} areas through {through} to {OUT}")


if __name__ == "__main__":
    main()
