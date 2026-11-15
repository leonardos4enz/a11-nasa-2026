"""MODIS / VIIRS harmonization: regional calibration factors and validation.

    python analysis/harmonization/pull.py         # once: extracts the counts from a11-db
    python analysis/harmonization/calibrate.py    # factors + validation

Reference: VIIRS NOAA-20 (its counts are used as-is from 2018-04).

Calibration chain (each link is calibrated with two REAL sensors that overlap):
    S-NPP  -> NOAA-20   k_s[cell, month] overlap 2018-04 .. 2025-12
    MODIS  -> S-NPP     k_m[cell, month] overlap 2012-02 .. 2023-12    (Terra + Aqua)
    Terra  -> S-NPP     k_t[cell, month] same overlap                  (Terra only: 2000-11 .. 2002-06)
    => MODIS in NOAA-20 units = k_m * k_s ;  Terra = k_t * k_s

MODIS is calibrated only through 2023 because from 2024 Terra's orbit drifts (Aqua/Terra goes from ~1.2 to 1.6).

Estimator with hierarchical shrinkage (so regions with few fires do not produce noisy factors):
    K_nac[m]     = ΣV / ΣM at national level for calendar month m
    K_c          = (ΣV_c + α·K_nac) / (ΣM_c + α)                  cell level, shrunk to the national one
    prior_c,m    = K_c · K_nac[m] / K_nac                         national seasonal shape, cell level
    K_c,m        = (ΣV_c,m + α·prior_c,m) / (ΣM_c,m + α)          final factor
α is chosen by minimizing the leave-one-year-out validation error.

Output in data/harmonization/: factors.parquet, bins.parquet, validation.json
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pandas as pd

DIR = Path(__file__).resolve().parents[2] / "data" / "harmonization"
REGION_DEG = 1                       # region size (the pull's cells are 1°)
ALPHAS = [0, 10, 30, 100, 300, 1000, None]   # None = national factor per month only
N20_START = pd.Timestamp("2018-04-01")
SNPP_START = pd.Timestamp("2012-02-01")      # first full month of S-NPP
AQUA_START = pd.Timestamp("2002-07-01")
LINKS = {
    # name: (numerator, denominator, first month, last month of the overlap)
    "SNPP": ("NOAA20", "SNPP", "2018-04-01", "2025-12-01"),
    "MODIS": ("SNPP", "MODIS", "2012-02-01", "2023-12-01"),
    "TERRA": ("SNPP", "Terra", "2012-02-01", "2023-12-01"),
}
BIN_EDGES = [0, 1, 3, 10, 30, 100, 300, 1000, np.inf]
# Local polygon correction: c = (ΣV_pol + β) / (Σpred_pol + β) over the overlap. β is in reference-sensor
# detections: an area with few fires keeps the regional factor; one with many gets its own.
BETA = {"SNPP": 100, "MODIS": 100, "TERRA": 30}


# ------------------------------------------------------------------ data
def load(name: str) -> pd.DataFrame:
    d = pd.read_parquet(DIR / f"{name}.parquet")
    keys = [c for c in ("area", "cy", "cx", "month") if c in d]
    w = d.pivot_table(index=keys, columns="satellite", values="n", aggfunc="sum", fill_value=0).reset_index()
    for s in ("Terra", "Aqua", "SNPP", "NOAA20"):
        if s not in w:
            w[s] = 0
    w["MODIS"] = w["Terra"] + w["Aqua"]
    w["ry"] = np.floor(w["cy"] / REGION_DEG).astype(int)
    w["rx"] = np.floor(w["cx"] / REGION_DEG).astype(int)
    w["m"] = w["month"].dt.month
    w["year"] = w["month"].dt.year
    return w


# -------------------------------------------------------------- estimator
def fit(df: pd.DataFrame, num: str, den: str, alpha) -> tuple[pd.Series, pd.Series]:
    """Returns (K per region and month, national K per month)."""
    nat = df.groupby("m")[[num, den]].sum()
    k_nat_m = (nat[num] / nat[den].where(nat[den] > 0)).reindex(range(1, 13))
    k_all = df[num].sum() / df[den].sum()
    k_nat_m = k_nat_m.fillna(k_all)
    if alpha is None:
        return pd.Series(dtype=float), k_nat_m
    g = df.groupby(["ry", "rx", "m"])[[num, den]].sum()
    gc = df.groupby(["ry", "rx"])[[num, den]].sum()
    k_c = (gc[num] + alpha * k_all) / (gc[den] + alpha) if alpha > 0 else gc[num] / gc[den].where(gc[den] > 0)
    k_c = k_c.fillna(k_all)
    prior = k_c.reindex(g.index.droplevel("m")).to_numpy() * k_nat_m.reindex(g.index.get_level_values("m")).to_numpy() / k_all
    if alpha > 0:
        k = (g[num] + alpha * prior) / (g[den] + alpha)
    else:
        k = (g[num] / g[den].where(g[den] > 0)).fillna(pd.Series(prior, index=g.index))
    return k, k_nat_m


def apply(df: pd.DataFrame, den: str, k: pd.Series, k_nat_m: pd.Series) -> np.ndarray:
    idx = pd.MultiIndex.from_frame(df[["ry", "rx", "m"]])
    kk = k.reindex(idx).to_numpy() if len(k) else np.full(len(df), np.nan)
    kk = np.where(np.isnan(kk), k_nat_m.reindex(df["m"]).to_numpy(), kk)
    return kk * df[den].to_numpy()


def current_method(cal: pd.DataFrame, test: pd.DataFrame, num: str, den: str, unit: list[str]) -> np.ndarray:
    """Current provisional method: median of the unit's annual ratios, fallback = global ratio."""
    yr = cal.groupby(unit + ["year"])[[num, den]].sum()
    yr = yr[yr[den] >= 5]
    med = (yr[num] / yr[den]).groupby(level=unit).median()
    k_glob = cal[num].sum() / cal[den].sum()
    k = med.reindex(pd.MultiIndex.from_frame(test[unit]) if len(unit) > 1 else test[unit[0]]).to_numpy()
    return np.where(np.isnan(k), k_glob, k) * test[den].to_numpy()


# ------------------------------------------------------------- metrics
def metrics(pred, true, unit_year=None) -> dict:
    pred, true = np.asarray(pred, float), np.asarray(true, float)
    out = {
        "error_mensual_wape": round(float(np.abs(pred - true).sum() / true.sum()), 3),
        "sesgo_total": round(float(pred.sum() / true.sum() - 1), 3),
        "r_log_mensual": round(float(np.corrcoef(np.log1p(pred), np.log1p(true))[0, 1]), 3),
    }
    if unit_year is not None:
        a = pd.DataFrame({"g": unit_year, "p": pred, "t": true}).groupby("g")[["p", "t"]].sum()
        out["error_anual_wape"] = round(float(np.abs(a.p - a.t).sum() / a.t.sum()), 3)
    return out


def window(df: pd.DataFrame, a: str, b: str, den: str) -> pd.DataFrame:
    w = df[(df["month"] >= a) & (df["month"] <= b)]
    return w[w[den] > 0] if den == "SNPP" else w


def loyo(cells: pd.DataFrame, areas: pd.DataFrame, link: str, alpha):
    """Leave-one-year-out validation. Returns predictions per cell-month and area-month."""
    num, den, a, b = LINKS[link]
    cw, aw = window(cells, a, b, "x"), window(areas, a, b, "x")
    years = sorted(cw["year"].unique())
    rows_c, rows_a = [], []
    for y in years:
        cal, tc, ta = cw[cw.year != y], cw[cw.year == y], aw[aw.year == y]
        k, kn = fit(cal, num, den, alpha)
        rows_c.append(tc.assign(pred=apply(tc, den, k, kn),
                                pred_actual=current_method(cal, tc, num, den, ["ry", "rx"])))
        # Areas: new method = per-cell factors applied to the counts of each cell in the polygon
        pa = ta.assign(pred=apply(ta, den, k, kn)).groupby(["area", "month", "year"])[["pred", num, den]].sum().reset_index()
        ca = aw[aw.year != y]
        cal_a = ca.assign(pred=apply(ca, den, k, kn)).groupby(["area", "month", "year"])[["pred", num, den]].sum().reset_index()
        pa["pred_actual"] = current_method(cal_a, pa, num, den, ["area"])
        # Local polygon correction (calibration years only)
        s = cal_a.groupby("area")[[num, "pred"]].sum()
        c = (s[num] + BETA[link]) / (s["pred"] + BETA[link])
        pa["pred_regional"] = pa["pred"]
        pa["pred"] = pa["pred"] * c.reindex(pa["area"]).fillna(1.0).to_numpy()
        rows_c[-1]["true"] = tc[num].to_numpy()
        pa["true"] = pa[num]
        rows_a.append(pa)
    return pd.concat(rows_c, ignore_index=True), pd.concat(rows_a, ignore_index=True)


def interval_bins(pred: np.ndarray, true: np.ndarray) -> pd.DataFrame:
    """10-90 % range of the ratio (true+1)/(pred+1), by prediction size."""
    lr = np.log((true + 1) / (pred + 1))
    b = np.digitize(pred, BIN_EDGES) - 1
    out = []
    for i in range(len(BIN_EDGES) - 1):
        sel = b == i
        if sel.sum() < 30:
            continue
        out.append({"pred_min": BIN_EDGES[i], "pred_max": BIN_EDGES[i + 1] if np.isfinite(BIN_EDGES[i + 1]) else 1e12,
                    "q_lo": float(np.quantile(lr[sel], 0.10)), "q_hi": float(np.quantile(lr[sel], 0.90)),
                    "n": int(sel.sum())})
    return pd.DataFrame(out)


def coverage(pred, true, bins: pd.DataFrame) -> float:
    pred, true = np.asarray(pred, float), np.asarray(true, float)
    idx = np.clip(np.searchsorted(bins["pred_max"].to_numpy(), pred, side="right"), 0, len(bins) - 1)
    lo = (pred + 1) * np.exp(bins["q_lo"].to_numpy()[idx]) - 1
    hi = (pred + 1) * np.exp(bins["q_hi"].to_numpy()[idx]) - 1
    return round(float(((true >= np.floor(lo)) & (true <= np.ceil(hi))).mean()), 3)


# ------------------------------------------------------------------ main
def main() -> None:
    cells, areas = load("cells"), load("areas")
    report = {"region_deg": REGION_DEG, "links": {}, "datos": "a11-db, Mexico, SP, fire_type=0, confidence n/h"}
    factors, bins_all = [], []

    for link in ("SNPP", "MODIS", "TERRA"):
        num, den, a, b = LINKS[link]
        # 1) choose α by monthly error at cell level
        scores = {}
        for al in ALPHAS:
            pc, _ = loyo(cells, areas, link, al)
            scores["nacional" if al is None else al] = metrics(pc["pred"], pc["true"])["error_mensual_wape"]
        best_key = min(scores, key=scores.get)
        best = None if best_key == "nacional" else best_key
        pc, pa = loyo(cells, areas, link, best)
        nat = pc.groupby("month")[["pred", "pred_actual", "true"]].sum()

        bins = interval_bins(pc["pred"].to_numpy(), pc["true"].to_numpy())
        bins_all.append(bins.assign(link=link))
        res = {
            "calibracion": f"{num} / {den}, {a[:7]} to {b[:7]}",
            "alpha_por_error": scores, "alpha_elegido": best_key,
            "celdas_1grado": {"nuevo": metrics(pc.pred, pc.true, pc.ry.astype(str) + pc.rx.astype(str) + pc.year.astype(str)),
                              "actual": metrics(pc.pred_actual, pc.true, pc.ry.astype(str) + pc.rx.astype(str) + pc.year.astype(str))},
            "nacional": {"nuevo": metrics(nat.pred, nat.true, nat.index.year),
                         "actual": metrics(nat.pred_actual, nat.true, nat.index.year)},
            "areas": {},
            "cobertura_rango_10_90": {"celdas": coverage(pc.pred, pc.true, bins), "areas": coverage(pa.pred, pa.true, bins)},
        }
        res["beta"] = BETA[link]
        for ar, g in pa.groupby("area"):
            res["areas"][ar] = {"nuevo": metrics(g.pred, g.true, g.year),
                                "nuevo_sin_correccion_local": metrics(g.pred_regional, g.true, g.year),
                                "actual": metrics(g.pred_actual, g.true, g.year)}
        report["links"][link] = res
        print(f"\n=== {link}: {res['calibracion']}  alpha={best_key}")
        print(json.dumps({k: res[k] for k in ("celdas_1grado", "nacional", "areas", "cobertura_rango_10_90")}, ensure_ascii=False))

        # 2) final factors using the whole overlap
        k, kn = fit(window(cells, a, b, "x"), num, den, best)
        if len(k):
            f = k.rename("k").reset_index()
            f["link"] = link
            factors.append(f)
        factors.append(pd.DataFrame({"ry": -999, "rx": -999, "m": kn.index, "k": kn.to_numpy(), "link": link}))

    fac = pd.concat(factors, ignore_index=True)
    fac.to_parquet(DIR / "factors.parquet", index=False)
    pd.concat(bins_all, ignore_index=True).to_parquet(DIR / "bins.parquet", index=False)
    (DIR / "validation.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"\nfactors: {len(fac)} rows -> {DIR / 'factors.parquet'}")


if __name__ == "__main__":
    main()
