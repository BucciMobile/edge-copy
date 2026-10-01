#!/usr/bin/env python3
"""Math-only tests for tool/bp_research_model.py.

Synthetic data here verifies MATHEMATICS (Kalman recursion, feature math,
session aggregation, prequential discipline) — it claims NO physiological
validity and is never used as evidence of medical accuracy.

Run:  python3 tool/test_bp_research_model.py
"""
import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
import bp_research_model as m


def approx(a, b, tol=1e-9):
    assert abs(a - b) <= tol, f"{a} != {b}"


def test_features():
    # z = [1, (H-60)/20, (ln(V+eps) - ln(40+eps))]
    z = m.features(80.0, 40.0)
    approx(z[0], 1.0)
    approx(z[1], 1.0)
    approx(z[2], 0.0, 1e-6)
    # Missing data never becomes a zero feature.
    assert m.features(None, 40.0) is None
    assert m.features(80.0, None) is None
    assert m.features(80.0, 0.0) is None  # RMSSD 0 = absent, not ln(0)


def test_level_a_converges():
    mdl = m.Model.initial(120.0)
    z = m.features(70.0, 40.0)
    # Feed the same reference repeatedly: the offset must converge to it.
    for _ in range(200):
        m.update_level_a(mdl, z, 130.0, delta_days=0.01)
    approx(mdl.theta[0], 130.0, 0.5)
    # Slopes stay frozen at zero in level A.
    approx(mdl.theta[1], 0.0)
    approx(mdl.theta[2], 0.0)
    # The covariance shrinks: repeated references increase certainty.
    assert mdl.p_offset < m.DEFAULT_P0


def test_level_b_joseph():
    mdl = m.Model.initial(120.0)
    z = m.features(70.0, 35.0)
    p_before = [row[:] for row in mdl.P]
    m.update_level_b(mdl, z, 125.0, delta_days=0.1)
    # P stays symmetric positive-definite-ish under the Joseph form.
    for i in range(3):
        for j in range(3):
            approx(mdl.P[i][j], mdl.P[j][i], 1e-12)
    assert all(mdl.P[i][i] >= 0 for i in range(3))
    assert mdl.P != p_before


def test_prediction_is_recorded_before_update():
    # Prequential discipline: with ONE usable reference after calibration,
    # the recorded prediction must equal the initial calibration baseline
    # (no feature influence yet — slopes are zero at start).
    rows = [m.Row(0, 120.0, 80.0, 70.0, 40.0, None, "ok", 1.0),
            m.Row(86_400_000, 122.0, 82.0, 70.0, 40.0, None, "ok", 1.0)]
    rep = m.run(rows)
    # First usable row: prediction = theta^T z = 120 + 0 + 0 = 120.
    approx(rep["systolic"]["hr_hrv_model"]["mae_mmhg"], 2.0, 0.01)


def test_session_aggregation():
    # Three readings of one session are NOT three independent states.
    rows = [
        m.Row(1000, 120.0, 80.0, 70.0, 40.0, "s1", "ok", 1.0),
        m.Row(60_000, 124.0, 84.0, 70.0, 40.0, "s1", "ok", 1.0),
        m.Row(120_000, 122.0, 82.0, 70.0, 40.0, "s1", "ok", 1.0),
    ]
    agg = m.aggregate_sessions(rows)
    assert len(agg) == 1
    approx(agg[0].sys_mmhg, 122.0)
    approx(agg[0].dia_mmhg, 82.0)


def test_missing_features_excluded_not_zeroed():
    rows = [m.Row(0, 120.0, 80.0, 70.0, 40.0, None, "ok", 1.0),
            # No band data: excluded, never treated as HR 0.
            m.Row(86_400_000, 121.0, 81.0, None, None, None, "no_data", None)]
    rep = m.run(rows)
    assert rep["rows_excluded_no_features"] == 1


def test_chronological_replay():
    # Back-dated rows: the CSV order must not matter, only measured_at_ms.
    r1 = m.Row(86_400_000, 122.0, 82.0, 70.0, 40.0, None, "ok", 1.0)
    r0 = m.Row(0, 120.0, 80.0, 70.0, 40.0, None, "ok", 1.0)
    a = m.run([r1, r0])
    b = m.run([r0, r1])
    assert a["systolic"]["hr_hrv_model"]["mae_mmhg"] == \
           b["systolic"]["hr_hrv_model"]["mae_mmhg"]


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"PASS {name}")
    print("ALL MATH TESTS PASSED")
