#!/usr/bin/env python3
"""Mutation test for the Oura-SpO2 pipeline: applies one mutant at a time
in a DEDICATED WORKTREE (never the working tree, never committed) and
runs the Oura-SpO2 suites. A mutant that no test kills is a hole in the
suite: it gets a new killing test or a written equivalence proof.

Usage:  python3 tool/mutate.py [flutter_sdk_bin]
"""
import pathlib
import subprocess
import sys
import tempfile

FLUTTER = sys.argv[1] if len(sys.argv) > 1 else "flutter"
# Fast suites: run for every mutant (~6 s each). The 400-seed model run
# takes ~97 min, so it runs ONLY for mutants the fast suites cannot kill
# (and for the model-validity check via --validate-model).
FAST_TESTS = [
    "test/oura_spo2_backfill_lifecycle_test.dart",
    "test/oura_spo2_export_test.dart",
    "test/oura_spo2_storage_test.dart",
    "test/oura_spo2_sync_boundaries_test.dart",
]
MODEL_TEST = ["test/oura_spo2_model_based_test.dart"]
H = "lib/health/health_export.dart"
D = "lib/data/db.dart"

MUTANTS = [
    # --- the 19 named mutants (M01-M19), strings matched to the code ---
    ("M01", H,
     "if (attempts <= 1) return false;",
     "if (attempts <= 0) return false;"),
    ("M02", H,
     "return elapsed >= 0 && elapsed < minutes * 60000;",
     "return elapsed < minutes * 60000;"),
    ("M03", H,
     "flat ? (r.attempts > 1 ? r.attempts : 1) : r.attempts + 1;",
     "flat ? 1 : r.attempts + 1;"),
    ("M04", H,
     "o == OuraSpo2DayOutcome.exported || o == OuraSpo2DayOutcome.cleanedUp;",
     "o != OuraSpo2DayOutcome.failed;"),
    ("M05", H,
     "if (++streak >= maxConsecutiveFailures) {",
     "if (++streak > maxConsecutiveFailures) {"),
    ("M06", H,
     "if (done == fp) return OuraSpo2DayOutcome.unchanged;",
     ""),
    ("M07", H,
     "return apple ? percent / 100.0 : percent;",
     "return percent;"),
    ("M08", H,
     "if (!percent.isFinite || percent <= 0 || percent > 100) return null;",
     "if (!percent.isFinite || percent <= 0 || percent >= 100) return null;"),
    ("M09", H,
     "return; // keep ALL dirty days for the release",
     "continue; // keep ALL dirty days for the release"),
    ("M10", H,
     "if (attempts <= 0 || nowMs < lastAttemptMs) return true;",
     "if (attempts <= 0) return true;"),
    ("M11", H,
     "final minutes = (5 * (attempts - 1)).clamp(0, 60);",
     "final minutes = (5 * (attempts - 1)).clamp(0, 600);"),
    ("M12", D,
     "if (spo2Dates.isNotEmpty) await markOuraSpo2Dirty(txn, spo2Dates);",
     ""),
    ("M13", D,
     "(oldAdapter ?? '') != (newAdapter ?? '') &&",
     "true &&"),
    ("M14", D,
     "'ORDER BY n DESC, o.device_id ASC LIMIT 1',",
     "'ORDER BY n ASC, o.device_id ASC LIMIT 1',"),
    ("M15", D,
     "AND o.value >= 70 AND o.value <= 100 '",
     "AND o.value >= 0 AND o.value <= 100 '"),
    ("M16", D,
     "WHERE substr(name, 1, ?) = ? ORDER BY date DESC LIMIT ?',",
     "WHERE substr(name, 1, ?) = ? ORDER BY date ASC LIMIT ?',"),
    ("M17", H,
     "if (done == null) return OuraSpo2DayOutcome.nothingToDo;",
     ""),
    ("M18", H,
     "if (!await clear(dayStart, dayEnd)) {",
     "if (await clear(dayStart, dayEnd) && false) {"),
    ("M19", H,
     "await LocalDb.setCursor(doneKey, fp);",
     ""),
    # --- 12 further mutants from the phase-3 analysis ---
    # The new writeFailed marker-drop fix (phase 4).
    ("M20", H,
     "if (r == OuraSpo2ExportResult.writeFailed) {",
     "if (r == OuraSpo2ExportResult.writeFailed && false) {"),
    # The day window: dayEnd must be local midnight of the NEXT day.
    ("M21", H,
     "final dayEnd =\n          DateTime(dayStart.year, dayStart.month, dayStart.day + 1);",
     "final dayEnd =\n          dayStart.add(const Duration(hours: 24));"),
    # Retry stamp read-back (attempts parsing).
    ("M22", D,
     "final v = await getCursor('$kOuraSpo2RetryPrefix$date');",
     "final v = await getCursor('$kOuraSpo2RetryPrefix${date}x');"),
    # Restore: marker-drop must cover the done prefix.
    ("M23", D,
     "\"substr(name, 1, ?) = ? OR substr(name, 1, ?) = ? OR \"",
     "\"substr(name, 1, ?) = ? OR \""),
    # Fingerprint field: the count must be part of the fingerprint.
    ("M24", H,
     "'${c.count}|${c.firstTsMs}|${c.lastTsMs}';",
     "'${c.firstTsMs}|${c.lastTsMs}';"),
    # Sweep window: 14 days must stay 14.
    ("M25", D,
     "final from = dayLabelOf(DateTime(now.year, now.month, now.day - 14));",
     "final from = dayLabelOf(DateTime(now.year, now.month, now.day - 1));"),
    # maxDays budget of the pass.
    ("M26", H,
     "int maxDays = 30,",
     "int maxDays = 1,"),
    # clear-condition of the compare-and-clear: token must match.
    ("M27", D,
     "where: 'name = ? AND value = ?',",
     "where: 'name = ? OR value = ?',"),
    # The device-candidate JOIN: pairing contract (adapter_id = 'oura').
    ("M28", D,
     "\"JOIN device d ON d.id = o.device_id AND d.adapter_id = 'oura' \"",
     "\"JOIN device d ON d.id = o.device_id \""),
    # Bootstrap: the epoch gate must depend on the method version.
    ("M29", D,
     "if (await getCursor(kOuraSpo2EpochName) != exportMethodVersion) {",
     "if (false) {"),
    # Retry clear on store success (noteStoreSuccess must drop the retry).
    ("M30", H,
     "await LocalDb.deleteCursor('health_oura_spo2_global_fail');\n"
     "          await LocalDb.deleteCursor('$kOuraSpo2RetryPrefix$d');",
     "await LocalDb.deleteCursor('health_oura_spo2_global_fail');"),
    # Sweep must cover done-marker days too (vanished candidates).
    ("M31", D,
     "\"AND unit = '%' AND date >= ? \"\n        'UNION '",
     "\"AND unit = '%' AND date >= ? \"\n        'UNION SELECT 1 WHERE 1=0 '"),]


def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def main():
    wt = tempfile.mkdtemp(prefix="spo2_mut_")
    subprocess.check_call(["git", "worktree", "add", "-q", wt, "HEAD"])
    killed, survived, invalid, apply_failed = [], [], [], []
    try:
        r = run([FLUTTER, "pub", "get"], wt)
        if r.returncode != 0:
            print("PUB GET FAILED", r.stdout[-2000:], r.stderr[-2000:])
            return 1
        for mid, f, orig, repl in MUTANTS:
            p = pathlib.Path(wt) / f
            src = p.read_text()
            n = src.count(orig)
            if n != 1:
                print(f"{mid} APPLY-FAILED (occurrences: {n})", flush=True)
                apply_failed.append(mid)
                continue
            p.write_text(src.replace(orig, repl))
            res = run([FLUTTER, "test", "--concurrency=1", *FAST_TESTS], wt)
            out = res.stdout + res.stderr
            if "Compilation failed" in out or "Error:" in out:
                invalid.append(mid)
                status = "INVALID (does not compile)"
            elif res.returncode == 0:
                # The fast suites did not catch it — the model decides.
                res = run([FLUTTER, "test", "--concurrency=1", *MODEL_TEST], wt)
                if res.returncode == 0:
                    survived.append(mid)
                    status = "SURVIVED"
                else:
                    killed.append(mid)
                    status = "killed (by model)"
            else:
                killed.append(mid)
                status = "killed"
            print(f"{mid} {status}", flush=True)
            p.write_text(src)
    finally:
        subprocess.call(["git", "worktree", "remove", "--force", wt])
    valid = len(killed) + len(survived)
    print("---")
    print(f"valid: {valid}, killed: {len(killed)}, survived: {len(survived)}, "
          f"invalid: {len(invalid)}, apply-failed: {len(apply_failed)}")
    if valid:
        print(f"mutation ratio: {len(killed)}/{valid} = "
              f"{len(killed) / valid:.2%}")
    if survived:
        print("SURVIVED:", ", ".join(survived))
    return 0


if __name__ == "__main__":
    sys.exit(main())
