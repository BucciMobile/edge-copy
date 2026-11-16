//
// workout_signals.dart — PR 4 of the deviation pipeline: WORKOUT-DERIVED
// signals. Pure and isolate-safe; the per-day aggregates are read on the
// DB-owning isolate (sessions + workout_split + strength_set) and handed to
// buildCrossDayBundle as plain data.
//
// What is derived, and what it is FOR:
//   * HRR — `sessions.hrr_bpm` (the 60 s post-session drop) already exists
//     per session; here it is aggregated per day and used as CONTEXT for the
//     next night (a session followed by a poor HRR is expected to suppress
//     HRV — that is load recovery, not an illness signal).
//   * HR drift — during a STEADY session (per-km pace within ±10% of its
//     median, ≥6 splits), the mean HR of the second half minus the first.
//     A positive drift at constant pace is cardiovascular drift; it feeds the
//     recovery trend as a performance-decrement pattern, never the illness
//     tiers.
//   * Pace-vs-HR economy — mean speed per bpm over the steady splits
//     (m/s per bpm). Compared with the user's own trailing baseline, a
//     declining index is the same performance-decrement pattern.
//   * Strength volume — Σ reps × load_kg per day (bodyweight sets count
//     reps only). Adds to the load context.
//
// Nothing here is ever fed to the illness tiers as EVIDENCE; it only ever
// MASKS (context) or feeds the recovery trend. All thresholds are named
// constants, reviewable in this diff. Missing data is null, never zero.

import 'dart:math' as math;

/// A split counts as "steady" when its pace is within this fraction of the
/// session's median pace.
const double kSteadyPaceTolerance = 0.10;

/// Minimum splits with an avg HR before drift/economy are computed.
const int kMinSplitsForDrift = 6;
const int kMinSplitsForEconomy = 4;

/// HRR this far (bpm) below the personal median counts as "poor recovery"
/// for the next night's context.
const double kHrrPoorDeltaBpm = 5.0;

/// Context weights (per unit), capped — see context_model.dart for the caps.
const double kLnHrvPerHrrPoorBpm = 0.008; // ln-RMSSD per bpm of HRR shortfall
const double kRhrBpmPerHrrPoorBpm = 0.15; // bpm RHR per bpm of HRR shortfall
const double kLnHrvPerVolumeKg = 0.00002; // ln-RMSSD per kg of strength volume
const double kRhrBpmPerVolumeKg = 0.0006; // bpm RHR per kg of strength volume

/// Caps so one big session cannot manufacture a big mask.
const double kHrrLnCap = 0.10;
const double kHrrRhrCapBpm = 3.0;
const double kVolumeLnCap = 0.08;
const double kVolumeRhrCapBpm = 2.0;

/// Economy decline (fraction of the baseline median) that counts as a
/// performance decrement in the recovery trend.
const double kEconomyDeclinePct = 0.05;

/// Minimum days with an economy reading inside the trend window.
const int kTrendMinEconomyDays = 5;

double? _median(List<double> xs) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2.0;
}

/// The steady splits of a session: rows with an avg HR whose pace
/// (meters / duration_sec) is within [kSteadyPaceTolerance] of the median
/// pace. Null (not empty) when there are too few to judge.
List<Map<String, dynamic>>? _steadySplits(List<Map<String, dynamic>> splits) {
  final withHr = <Map<String, dynamic>>[];
  final paces = <double>[];
  for (final s in splits) {
    final m = (s['meters'] as num?)?.toDouble();
    final dur = (s['duration_sec'] as num?)?.toDouble();
    final hr = (s['avg_hr'] as num?)?.toDouble();
    if (m == null || dur == null || dur <= 0 || hr == null || hr <= 0) {
      continue;
    }
    final row = <String, dynamic>{'pace': m / dur, 'hr': hr};
    withHr.add(row);
    paces.add(row['pace'] as double);
  }
  if (withHr.length < kMinSplitsForEconomy) return null;
  final med = _median(paces)!;
  final steady = [
    for (final r in withHr)
      if ((r['pace'] as double) >= med * (1 - kSteadyPaceTolerance) &&
          (r['pace'] as double) <= med * (1 + kSteadyPaceTolerance))
        r,
  ];
  return steady.isEmpty ? null : steady;
}

/// HR drift during a steady session: mean HR of the second half of the
/// steady splits minus the first half, in bpm. Positive = cardiovascular
/// drift at constant pace. Null when the session is not steady or too short.
double? hrDriftBpm(List<Map<String, dynamic>> splits) {
  final steady = _steadySplits(splits);
  if (steady == null || steady.length < kMinSplitsForDrift) return null;
  final half = steady.length ~/ 2;
  final first = steady.sublist(0, half);
  final second = steady.sublist(steady.length - half);
  double mean(List<Map<String, dynamic>> xs) =>
      xs.map((r) => r['hr'] as double).reduce((a, b) => a + b) / xs.length;
  return mean(second) - mean(first);
}

/// Pace-vs-HR economy over the steady splits: mean speed per bpm (m/s per
/// bpm). Higher = more distance per heartbeat. Null when not computable.
double? paceHrEconomy(List<Map<String, dynamic>> splits) {
  final steady = _steadySplits(splits);
  if (steady == null || steady.length < kMinSplitsForEconomy) return null;
  final ratios = [for (final r in steady) (r['pace'] as double) / (r['hr'] as double)];
  return ratios.reduce((a, b) => a + b) / ratios.length;
}

/// Strength volume for a list of sets: Σ reps × load_kg (kg), plus a separate
/// bodyweight-rep count for sets with no load — never a fabricated kg figure.
({double volumeKg, int bodyweightReps}) strengthVolume(
    List<Map<String, dynamic>> sets) {
  var kg = 0.0;
  var bw = 0;
  for (final s in sets) {
    final reps = (s['reps'] as num?)?.toInt() ?? 0;
    final load = (s['load_kg'] as num?)?.toDouble();
    if (reps <= 0) continue;
    if (load != null && load > 0) {
      kg += reps * load;
    } else {
      bw += reps;
    }
  }
  return (volumeKg: kg, bodyweightReps: bw);
}

/// Per-day workout signals from the day's finished sessions and strength
/// sets. [sessions] rows carry id/type/strain/hrr_bpm/duration_min;
/// [splitsBySession] maps session id → its workout_split rows;
/// [strengthSets] are the day's strength_set rows.
///
/// All outputs are null when the inputs are absent — never zero.
Map<String, dynamic> dailyWorkoutSignals({
  required List<Map<String, dynamic>> sessions,
  Map<String, List<Map<String, dynamic>>> splitsBySession = const {},
  List<Map<String, dynamic>> strengthSets = const [],
}) {
  final hrrVals = <double>[
    for (final s in sessions)
      if ((s['hrr_bpm'] as num?)?.toDouble() case final v?)
        if (v > 0) v,
  ];
  var drift = <double>[];
  var economy = <double>[];
  var maxStrain = 0.0;
  for (final s in sessions) {
    final id = s['id']?.toString();
    final splits = id == null ? null : splitsBySession[id];
    if (splits != null && splits.isNotEmpty) {
      final dr = hrDriftBpm(splits);
      if (dr != null) drift.add(dr);
      final ec = paceHrEconomy(splits);
      if (ec != null && ec > 0) economy.add(ec);
    }
    final st = (s['strain'] as num?)?.toDouble() ?? 0.0;
    if (st > maxStrain) maxStrain = st;
  }
  final vol = strengthVolume(strengthSets);
  return {
    'n_sessions': sessions.length,
    'hrr_bpm': hrrVals.isEmpty
        ? null
        : hrrVals.reduce((a, b) => a + b) / hrrVals.length,
    'hr_drift_bpm': drift.isEmpty ? null : drift.reduce(math.max),
    'economy': economy.isEmpty ? null : economy.reduce(math.max),
    'volume_kg': vol.volumeKg,
    'bodyweight_reps': vol.bodyweightReps,
    'max_strain': sessions.isEmpty ? null : maxStrain,
  };
}
