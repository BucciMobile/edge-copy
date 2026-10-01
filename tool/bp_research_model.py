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
       theta[1], theta[2] stay 0, so level A is NOT a sensor model in any
       predictive sense; it is reported as 'adaptive_cuff_offset_baseline'.
    B: full parameter vector — scalar-per-parameter Kalman with Joseph-
       form covariance. Off by default and EXPERIMENTAL. Enabled per
       reference ONLY from causal, already-processed history: at least
       MIN_SLOPE_SAMPLES previously updated aggregated references with
       finite features and sufficient spread in BOTH H and L. Before the
       gate opens (and on any gate failure) the run falls back to level A
       and the report says so. The transition A->B is a documented
       covariance hand-over: p_offset seeds the offset diagonal of P and
       the level-A theta carries over unchanged (both tested).

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
# Quality admission (documented research rule, NOT a validated criterion):
# a capture enters the model only with usable features and a quality
# status the rule accepts. 'pending' (window not final), 'no_data' and
# missing features are excluded; 'gappy' is admitted — it is usable data
# with an honest warning flag, and excluding it would bias the dataset
# toward clean, unrepresentative windows.
ADMITTED_QUALITY = frozenset({"ok", "gappy", ""})
# Session aggregation span: members of one explicit session id are only
# aggregated when they lie within this span (engineering default, 30 min —
# a few cuff readings of one sitting). Same label, farther apart: NOT one
# session; each reference stays independent.
MAX_SESSION_SPAN_MS = 30 * 60 * 1000

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
    def hand_over_to_level_b(m: "Model") -> "Model":
        """Documented A->B transition: theta carries over unchanged, the
        offset variance p_offset seeds the offset diagonal of P, and the
        slope variances start from DEFAULT_P0 (nothing about them was ever
        learned in level A)."""
        return Model(
            theta=list(m.theta),
            P=[[m.p_offset, 0, 0], [0, DEFAULT_P0, 0], [0, 0, DEFAULT_P0]],
            p_offset=m.p_offset,
            last_cuff=m.last_cuff,
        )

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
    missing data never becomes a zero feature. NaN and infinities are
    rejected like any other unusable input, never laundered into a
    feature value."""
    if hr is None or rmssd is None:
        return None
    if not (math.isfinite(hr) and math.isfinite(rmssd) and hr > 0 and rmssd > 0):
        return None
    l = math.log(rmssd + EPSILON_MS)
    return [1.0, (hr - H0_BPM) / SH_BPM, (l - L0) / SL]


def predict(m: Model, z: list[float]) -> float:
    return sum(t * zi for t, zi in zip(m.theta, z))


def update_level_a(m: Model, z: list[float], ref: float,
                   delta_days: float) -> None:
    """Scalar Kalman on the offset only (slopes stay frozen).

    The A->B hand-over is explicit: when a later run switches this model
    to level B, [Model.hand_over_to_level_b] seeds the offset diagonal of
    P from p_offset and carries theta over unchanged — no undocumented
    mixing of the scalar and matrix covariances."""
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
    """Multiple cuff readings of one sitting are NOT independent
    physiological states — average them into one reference before they
    enter the model.

    Session identity is EXPLICIT: only rows sharing a measurement_session_id
    can be aggregated, and only when they lie within MAX_SESSION_SPAN_MS of
    each other (chained: consecutive members, not min-to-max of an
    arbitrarily long chain). No implicit calendar-day aggregation — the
    same label hours apart stays separate references, and rows without a
    session id never merge with anything.

    Within one aggregated session the REFERENCE values are the session
    mean; the FEATURES are the coverage-weighted mean of the members'
    features (they all describe the same few minutes of the same sitting —
    a 'best member's features' pick would silently borrow a different
    member's window instead of representing the session).
    """
    explicit: list[Row] = []
    solo: list[Row] = []
    for r in rows:
        (explicit if r.session_id else solo).append(r)
    out: list[Row] = list(solo)
    by_label: dict[str, list[Row]] = {}
    for r in explicit:
        by_label.setdefault(r.session_id, []).append(r)
    for label, group in by_label.items():
        group.sort(key=lambda g: g.measured_at_ms)
        cluster = [group[0]]
        clusters: list[list[Row]] = []
        for g in group[1:]:
            if g.measured_at_ms - cluster[-1].measured_at_ms <= MAX_SESSION_SPAN_MS:
                cluster.append(g)
            else:
                clusters.append(cluster)
                cluster = [g]
        clusters.append(cluster)
        for members in clusters:
            if len(members) == 1:
                out.append(members[0])
                continue
            n = len(members)
            weights = [(m.coverage or 0.0) for m in members]
            def wmean(vals: list[float | None]) -> float | None:
                pairs = [(v, w) for v, w in zip(vals, weights)
                         if v is not None and w > 0]
                if not pairs:
                    return None
                tw = sum(w for _, w in pairs)
                return sum(v * w for v, w in pairs) / tw
            out.append(Row(
                measured_at_ms=sum(m.measured_at_ms for m in members) / n,
                sys_mmhg=sum(m.sys_mmhg for m in members) / n,
                dia_mmhg=sum(m.dia_mmhg for m in members) / n,
                hr_mean=wmean([m.hr_mean for m in members]),
                rmssd_ms=wmean([m.rmssd_ms for m in members]),
                session_id=label,
                quality=(members[0].quality if all(
                    m.quality == members[0].quality for m in members) else None),
                coverage=(sum(weights) / n if all(
                    m.coverage is not None for m in members) else None),
            ))
    out.sort(key=lambda x: x.measured_at_ms)
    return out


def mae(xs: list[float]) -> float:
    return sum(abs(x) for x in xs) / len(xs) if xs else float("nan")


def signed_mean(xs: list[float]) -> float:
    return sum(xs) / len(xs) if xs else float("nan")


def run(rows: list[Row], level_b: bool = False) -> dict:
    """Chronological prequential replay.

    FAIR COMPARISON: all three models are evaluated on the EXACT SAME
    target set — the admitted aggregated references AFTER the calibration
    row. A reference without usable features updates NO model (features
    would be fabricated for the sensor model alone), so all three n's are
    identical by construction.

    Level B is enabled causally, per reference, from ALREADY-PROCESSED
    history only: at least MIN_SLOPE_SAMPLES previously UPDATED references
    with finite features and spread in BOTH H and L among them. No future
    row of the CSV is inspected. When the gate has not opened (or the run
    did not ask for level B), the update falls back to level A and the
    report says so.
    """
    aggregated = aggregate_sessions(rows)
    if not aggregated:
        return {"error": "no rows"}

    # Quality admission (documented research rule, see ADMITTED_QUALITY).
    admitted = [r for r in aggregated
                if (r.quality or "") in ADMITTED_QUALITY]
    excluded_quality = len(aggregated) - len(admitted)

    # Calibration row: the first admitted reference seeds the models.
    # Baselines start from it too, so all models see the same history.
    first = admitted[0]
    m_sys = Model.initial(first.sys_mmhg)
    m_dia = Model.initial(first.dia_mmhg)

    usable = admitted[1:]  # prequential: predict, then update
    targets: list[Row] = []
    excluded_no_features = 0
    last_t = first.measured_at_ms

    # Baseline 2: last calibration cuff value — defined from the FIRST
    # admitted row on, so its n matches everyone else's.
    last_cuff_sys = first.sys_mmhg
    last_cuff_dia = first.dia_mmhg
    # Baseline 3: cuff-only time model — the running mean of every admitted
    # reference seen so far, features never involved.
    seen_sys = [first.sys_mmhg]
    seen_dia = [first.dia_mmhg]

    # Causal level-B gate state: history of the FEATURE VECTORS of the
    # references that were actually processed (updated on), never future
    # rows.
    processed_z: list[list[float]] = []
    level_b_updates = 0
    level_a_updates = 0

    per_target: list[dict] = []

    for r in usable:
        z = features(r.hr_mean, r.rmssd_ms)
        if z is None:
            excluded_no_features += 1
            continue
        delta_days = (r.measured_at_ms - last_t) / 86400000.0
        last_t = r.measured_at_ms
        targets.append(r)

        # 1. prequential predictions — recorded BEFORE any update.
        pred_s = predict(m_sys, z)
        pred_d = predict(m_dia, z)

        # 2. baseline: last cuff value, no WHOOP features.
        # 3. baseline: running cuff mean, no WHOOP features.
        # Both are evaluated on the same target as the model.
        per_target.append({
            "measured_at_ms": r.measured_at_ms,
            "model_mode": ("level_b" if (level_b and _b_gate(processed_z))
                            else "level_a"),
            "pred_model_sys": pred_s,
            "pred_model_dia": pred_d,
            "pred_last_cuff_sys": last_cuff_sys,
            "pred_last_cuff_dia": last_cuff_dia,
            "pred_cuff_mean_sys": sum(seen_sys) / len(seen_sys),
            "pred_cuff_mean_dia": sum(seen_dia) / len(seen_dia),
            "ref_sys": r.sys_mmhg,
            "ref_dia": r.dia_mmhg,
        })

        # 4. update AFTER recording the predictions. The mode decision uses
        # ONLY processed history (no future rows, no len(usable)).
        use_b = level_b and _b_gate(processed_z)
        if use_b:
            update_level_b(m_sys, z, r.sys_mmhg, delta_days)
            update_level_b(m_dia, z, r.dia_mmhg, delta_days)
            level_b_updates += 1
        else:
            update_level_a(m_sys, z, r.sys_mmhg, delta_days)
            update_level_a(m_dia, z, r.dia_mmhg, delta_days)
            level_a_updates += 1
        processed_z.append(z)
        last_cuff_sys = r.sys_mmhg
        last_cuff_dia = r.dia_mmhg
        seen_sys.append(r.sys_mmhg)
        seen_dia.append(r.dia_mmhg)

    def stats(pred_key: str, ref_key: str) -> dict:
        errs = [t[pred_key] - t[ref_key] for t in per_target]
        if not errs:
            return {"n": 0}
        mean = signed_mean(errs)
        var = sum((e - mean) ** 2 for e in errs) / len(errs)
        return {
            "n": len(errs),
            "mae_mmhg": round(mae(errs), 2),
            "mean_signed_mmhg": round(mean, 2),
            "sd_mmhg": round(math.sqrt(var), 2),
        }

    return {
        "rows_total": len(rows),
        "rows_aggregated": len(aggregated),
        "rows_excluded_quality": excluded_quality,
        "rows_excluded_no_features": excluded_no_features,
        "admission_rule": {
            "admitted_quality": sorted(ADMITTED_QUALITY),
            "max_session_span_ms": MAX_SESSION_SPAN_MS,
        },
        "updates": {
            "level_a": level_a_updates,
            "level_b": level_b_updates,
            "level_b_requested": level_b,
            "level_b_gate": {
                "min_processed_refs": MIN_SLOPE_SAMPLES,
                "min_feature_spread_h_and_l": MIN_FEATURE_SPREAD,
            },
        },
        "systolic": {
            "baseline_last_cuff": stats("pred_last_cuff_sys", "ref_sys"),
            "baseline_cuff_time_model": stats("pred_cuff_mean_sys", "ref_sys"),
            # Level A holds sensor slopes at zero: an offset tracker, not a
            # sensor model. Named for what it is.
            "adaptive_cuff_offset_baseline": stats("pred_model_sys", "ref_sys"),
        },
        "diastolic": {
            "baseline_last_cuff": stats("pred_last_cuff_dia", "ref_dia"),
            "baseline_cuff_time_model": stats("pred_cuff_mean_dia", "ref_dia"),
            "adaptive_cuff_offset_baseline": stats("pred_model_dia", "ref_dia"),
        },
        "model_state": {
            "theta_sys": [round(t, 3) for t in m_sys.theta],
            "theta_dia": [round(t, 3) for t in m_dia.theta],
            "p_offset_sys": round(m_sys.p_offset, 3),
            "p_offset_dia": round(m_dia.p_offset, 3),
            "feature_anchors": {"H0_bpm": H0_BPM, "sH_bpm": SH_BPM,
                                "L0": round(L0, 4), "sL": SL,
                                "epsilon_ms": EPSILON_MS},
        },
    }


def _b_gate(processed_z: list[list[float]]) -> bool:
    """Level-B admission from CAUSAL history only: enough processed
    references, finite features, and spread in BOTH H and L. Falls back to
    level A on any failure (the caller reports the fallback)."""
    if len(processed_z) < MIN_SLOPE_SAMPLES:
        return False
    hs = [z[1] for z in processed_z]
    ls = [z[2] for z in processed_z]
    if any(not math.isfinite(v) for v in hs + ls):
        return False
    return (max(hs) - min(hs) >= MIN_FEATURE_SPREAD
            and max(ls) - min(ls) >= MIN_FEATURE_SPREAD)


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
