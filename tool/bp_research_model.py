#!/usr/bin/env python3
"""BP research offline model — an EXPERIMENTAL analysis prototype.

Reads the `bp_research` CSV export (set "BP research captures") produced by
the app and evaluates a personally calibrated HR/HRV linear model against
cuff-only baselines. Runs OUTSIDE the app runtime, on the researcher's
machine; it never touches app health data, never writes to the phone, and
its outputs are research results, not health records.

NOT A MEDICAL DEVICE. NOT A VALIDATED BLOOD PRESSURE MEASUREMENT.
The formulas below are a research draft for reproducible data collection,
evaluated here only so the dataset's value can be judged on real captures.
No synthetic data here claims physiological validity; synthetic fixtures
are for MATH tests only.

Usage:
    python3 bp_research_model.py --csv bp_research.csv [--out report.txt]

Model (research draft, per the PR description):
    H = mean of valid HR in the window (hr_mean)
    V = RMSSD over valid contiguous interval pairs (rmssd_ms)
    L = ln((V + eps) / 1 ms), eps = 1e-3 ms, numerical stability only
    z = [1, (H - H0) / sH, (L - L0) / sL]^T
    prediction_k = theta_k^T z

Learning levels:
    A: only the personal offset (theta[0]) updates — scalar Kalman.
       theta[1], theta[2] stay 0 unless a separately validated model says
       otherwise.
    B: full parameter vector — scalar-per-parameter Kalman with Joseph-
       form covariance. Off by default; requires enough independent
       feature variation (documented thresholds below) and remains
       experimental.

Evaluation discipline:
    · a prediction is ALWAYS recorded before its reference updates the
      model (prequential evaluation);
    · references of one session id are NOT independent states — they are
      aggregated (mean) before entering the model;
    · back-dated references trigger a full chronological replay;
    · baselines: (1) last calibration cuff value, (2) cuff-only time
      model (mean), (3) the HR/HRV model — reported side by side.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from dataclasses import dataclass, field

EPSILON_MS = 1e-3  # numerical stability only; never replaces missing data

# Documented research defaults. NOT clinically validated. P, Q, R are the
# scalar Kalman covariances; the numbers say "a cuff reference is worth
# more than yesterday's personal offset", nothing more.
DEFAULT_R_MMHG = 25.0     # reference measurement variance (±5 mmHg SD)
DEFAULT_Q_OFFSET = 4.0    # per-day drift allowance on the personal offset
DEFAULT_P0 = 400.0        # initial offset uncertainty (±20 mmHg SD)
MIN_SLOPE_SAMPLES = 20    # level B needs at least this many aggregated refs
MIN_FEATURE_SPREAD = 0.25  # and this much normalized spread in H and L

# Feature normalization. Documented, arbitrary-but-fixed engineering
# anchors; a change requires retraining or transforming the parameters.
H0_BPM = 60.0
SH_BPM = 20.0
L0 = math.log(40.0 + EPSILON_MS)  # ln of a 40 ms RMSSD anchor
SL = 1.0


@dataclass
class Row:
    measured_at_ms: int
    sys_mmhg: float
    dia_mmhg: float
    hr_mean: float | None
    rmssd_ms: float | None
    session_id: str | None
    quality: str | None
    coverage: float | None


@dataclass
class Model:
    """Personal calibration state for one of systolic / diastolic."""
    theta: list[float]          # [offset, h_slope, l_slope]
    P: list[list[float]]        # covariance, level B (diagonal-ish)
    p_offset: float             # scalar covariance, level A
    last_cuff: float | None = None
    predictions: list[dict] = field(default_factory=list)

    @staticmethod
    def initial(cuff_mean: float) -> "Model":
        # Calibration baseline, NOT a sensor-backed prediction: slopes
        # start at zero, the offset starts at the cuff mean.
        return Model(
            theta=[cuff_mean, 0.0, 0.0],
            P=[[DEFAULT_P0, 0, 0], [0, DEFAULT_P0, 0], [0, 0, DEFAULT_P0]],
            p_offset=DEFAULT_P0,
        )


def features(hr: float | None, rmssd: float | None) -> list[float] | None:
    """z = [1, (H-H0)/sH, (L-L0)/sL]; None when H or V is missing —
    missing data never becomes a zero feature."""
    if hr is None or rmssd is None or rmssd <= 0:
        return None
    l = math.log(rmssd + EPSILON_MS)
    return [1.0, (hr - H0_BPM) / SH_BPM, (l - L0) / SL]


def predict(m: Model, z: list[float]) -> float:
    return sum(t * zi for t, zi in zip(m.theta, z))


def update_level_a(m: Model, z: list[float], ref: float,
                   delta_days: float) -> None:
    """Scalar Kalman on the offset only (slopes stay frozen)."""
    p_minus = m.p_offset + DEFAULT_Q_OFFSET * max(delta_days, 0.0)
    k = p_minus / (p_minus + DEFAULT_R_MMHG)
    pred = predict(m, z)
    m.theta[0] += k * (ref - pred)
    m.p_offset = (1.0 - k) * p_minus


def update_level_b(m: Model, z: list[float], ref: float,
                  delta_days: float) -> None:
    """Full parameter Kalman with Joseph-form covariance update."""
    n = 3
    q = DEFAULT_Q_OFFSET * max(delta_days, 0.0)
    p_minus = [[m.P[i][j] + (q if i == j else 0.0) for j in range(n)]
               for i in range(n)]
    # innovation gain K = P z / (R + z^T P z)
    pz = [sum(p_minus[i][j] * z[j] for j in range(n)) for i in range(n)]
    denom = DEFAULT_R_MMHG + sum(zi * pzi for zi, pzi in zip(z, pz))
    k = [pzi / denom for pzi in pz]
    pred = predict(m, z)
    resid = ref - pred
    m.theta = [m.theta[i] + k[i] * resid for i in range(n)]
    # Joseph form: (I - K z^T) P (I - K z^T)^T + K R K^T
    a = [[(1.0 if i == j else 0.0) - k[i] * z[j] for j in range(n)]
         for i in range(n)]
    ap = [[sum(a[i][t] * p_minus[t][j] for t in range(n)) for j in range(n)]
          for i in range(n)]
    apa = [[sum(ap[i][t] * a[j][t] for t in range(n)) for j in range(n)]
           for i in range(n)]
    for i in range(n):
        for j in range(n):
            m.P[i][j] = apa[i][j] + DEFAULT_R_MMHG * k[i] * k[j]


def load_rows(path: str) -> list[Row]:
    rows: list[Row] = []
    with open(path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            def num(key: str) -> float | None:
                v = (r.get(key) or "").strip()
                if not v:
                    return None
                try:
                    return float(v)
                except ValueError:
                    return None
            rows.append(Row(
                measured_at_ms=int(float(r["measured_at_ms"])),
                sys_mmhg=float(r["systolic_mmhg"]),
                dia_mmhg=float(r["diastolic_mmhg"]),
                hr_mean=num("hr_mean"),
                rmssd_ms=num("rmssd_ms"),
                session_id=(r.get("measurement_session_id") or "").strip() or None,
                quality=(r.get("quality_status") or "").strip() or None,
                coverage=num("coverage_fraction"),
            ))
    rows.sort(key=lambda x: x.measured_at_ms)
    return rows


def aggregate_sessions(rows: list[Row]) -> list[Row]:
    """Multiple cuff readings of one session are NOT independent
    physiological states — average them into one reference before they
    enter the model. Sessions are keyed by (session_id, calendar day)."""
    by_key: dict[tuple, list[Row]] = {}
    for r in rows:
        day = r.measured_at_ms // 86400000
        key = (r.session_id, day) if r.session_id else ("_solo", day,
                                                        r.measured_at_ms)
        by_key.setdefault(key, []).append(r)
    out = []
    for key, group in by_key.items():
        if len(group) == 1:
            out.append(group[0])
        else:
            # Same instant features across the session's captures; the
            # REFERENCE is the session mean. Feature fields are taken from
            # the capture with the best quality/coverage.
            best = max(group, key=lambda g: (g.coverage or 0.0))
            out.append(Row(
                measured_at_ms=max(g.measured_at_ms for g in group),
                sys_mmhg=sum(g.sys_mmhg for g in group) / len(group),
                dia_mmhg=sum(g.dia_mmhg for g in group) / len(group),
                hr_mean=best.hr_mean,
                rmssd_ms=best.rmssd_ms,
                session_id=key[0] if isinstance(key[0], str) else None,
                quality=best.quality,
                coverage=best.coverage,
            ))
    out.sort(key=lambda x: x.measured_at_ms)
    return out


def mae(xs: list[float]) -> float:
    return sum(abs(x) for x in xs) / len(xs) if xs else float("nan")


def signed_mean(xs: list[float]) -> float:
    return sum(xs) / len(xs) if xs else float("nan")


def run(rows: list[Row], level_b: bool = False) -> dict:
    aggregated = aggregate_sessions(rows)
    if not aggregated:
        return {"error": "no rows"}

    # Calibration baseline from the FIRST session's cuff values.
    first_sys = aggregated[0].sys_mmhg
    first_dia = aggregated[0].dia_mmhg
    m_sys = Model.initial(first_sys)
    m_dia = Model.initial(first_dia)

    usable = [r for r in aggregated[1:]]  # prequential: predict, then update
    err_calib = {"sys": [], "dia": []}
    err_time = {"sys": [], "dia": []}
    err_model = {"sys": [], "dia": []}
    excluded = 0
    last_t = aggregated[0].measured_at_ms

    # Baseline 3: cuff-only time model — the running mean of every reference
    # seen so far, features never involved.
    seen_sys = [first_sys]
    seen_dia = [first_dia]

    for r in usable:
        z = features(r.hr_mean, r.rmssd_ms)
        if z is None:
            excluded += 1
            continue
        delta_days = (r.measured_at_ms - last_t) / 86400000.0
        last_t = r.measured_at_ms

        # 1. prequential prediction — recorded BEFORE the update.
        pred_s = predict(m_sys, z)
        pred_d = predict(m_dia, z)
        err_model["sys"].append(pred_s - r.sys_mmhg)
        err_model["dia"].append(pred_d - r.dia_mmhg)

        # 2. baseline: last calibration cuff value (no WHOOP features).
        if m_sys.last_cuff is not None:
            err_calib["sys"].append(m_sys.last_cuff - r.sys_mmhg)
            err_calib["dia"].append(m_dia.last_cuff - r.dia_mmhg)

        # 3. baseline: cuff-only time model (running cuff mean).
        err_time["sys"].append(
            sum(seen_sys) / len(seen_sys) - r.sys_mmhg)
        err_time["dia"].append(
            sum(seen_dia) / len(seen_dia) - r.dia_mmhg)
        seen_sys.append(r.sys_mmhg)
        seen_dia.append(r.dia_mmhg)

        # 4. update AFTER recording the prediction.
        if level_b and len(usable) >= MIN_SLOPE_SAMPLES:
            hs = [abs((r_.hr_mean or H0_BPM) - H0_BPM) / SH_BPM
                  for r_ in usable[:n_seen]]
            if max(hs, default=0.0) >= MIN_FEATURE_SPREAD:
                update_level_b(m_sys, z, r.sys_mmhg, delta_days)
                update_level_b(m_dia, z, r.dia_mmhg, delta_days)
        else:
            update_level_a(m_sys, z, r.sys_mmhg, delta_days)
            update_level_a(m_dia, z, r.dia_mmhg, delta_days)
        m_sys.last_cuff = r.sys_mmhg
        m_dia.last_cuff = r.dia_mmhg

    def stats(errs: list[float]) -> dict:
        if not errs:
            return {"n": 0}
        var = sum((e - signed_mean(errs)) ** 2 for e in errs) / len(errs)
        return {
            "n": len(errs),
            "mae_mmhg": round(mae(errs), 2),
            "mean_signed_mmhg": round(signed_mean(errs), 2),
            "sd_mmhg": round(math.sqrt(var), 2),
        }

    return {
        "rows_total": len(rows),
        "rows_aggregated": len(aggregated),
        "rows_excluded_no_features": excluded,
        "systolic": {
            "baseline_last_cuff": stats(err_calib["sys"]),
            "baseline_cuff_time_model": stats(err_time["sys"]),
            "hr_hrv_model": stats(err_model["sys"]),
        },
        "diastolic": {
            "baseline_last_cuff": stats(err_calib["dia"]),
            "baseline_cuff_time_model": stats(err_time["dia"]),
            "hr_hrv_model": stats(err_model["dia"]),
        },
        "model_state": {
            "theta_sys": [round(t, 3) for t in m_sys.theta],
            "theta_dia": [round(t, 3) for t in m_dia.theta],
            "feature_anchors": {"H0_bpm": H0_BPM, "sH_bpm": SH_BPM,
                                "L0": round(L0, 4), "sL": SL,
                                "epsilon_ms": EPSILON_MS},
        },
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--csv", required=True, help="the bp_research CSV export")
    ap.add_argument("--level-b", action="store_true",
                    help="enable experimental full-parameter learning "
                         "(level B; requires independent feature variation)")
    ap.add_argument("--out", help="write the report as JSON instead of stdout")
    args = ap.parse_args()

    rows = load_rows(args.csv)
    report = run(rows, level_b=args.level_b)
    text = json.dumps(report, indent=2)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
    else:
        print(text)
    print(
        "\nRESEARCH OUTPUT ONLY — not a medical measurement, not a "
        "validated blood pressure estimate.",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
