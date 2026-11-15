# Regional harmonization (v2) — improved method, not implemented

These scripts build the **regional** MODIS → VIIRS harmonization described in
[docs/research/13-harmonization-v2.md](../../docs/research/13-harmonization-v2.md): factors per 1° cell and calendar
month with hierarchical shrinkage, a local correction per polygon and a 10-90 % error range.

**The app does not use them.** The app uses the simple method of
[docs/research/14-harmonization-simple.md](../../docs/research/14-harmonization-simple.md), which lives entirely in
[`analysis/db/harmonization.sql`](../db/harmonization.sql) (one national factor per calendar month, computed inside
the database; no Python).

To bring v2 back:

```bash
python analysis/harmonization/pull.py        # DATABASE_URL (read-only is enough) in .env
python analysis/harmonization/calibrate.py
python analysis/harmonization/build_sql.py   # writes analysis/db/harmonization_v2.sql
python analysis/harmonization/test_sql.py    # optional: check against the DB without writing
```

then apply `analysis/db/harmonization_v2.sql` instead of `harmonization.sql`.
