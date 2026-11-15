// TIER ENGINE — Layer 3 of the deviation pipeline (PURE, ISOLATE-SAFE).
//
// Layers 1–2 (context_model.dart) turn every signal into a RESIDUAL: actual
// minus the deviation context already explains (load, sleep debt, alcohol,
// vaccination, travel, cycle, self-report). What is left is deviation nothing
// explains. This module aggregates those residuals across signals and nights
// into conservative, tiered outcomes:
//
//   tier 0 — nothing (or still calibrating: stage 0, < 7 valid nights)
//   tier 1 — one signal off baseline (UI card only, never a push)
//   tier 2 — ≥2 signals off baseline for ≥2 consecutive nights (one
//            ask-first check-in push per night)
//   tier 3 — the fever-like constellation (skin temp↑ AND respiratory rate↑
//            AND resting HR↑) sustained ≥2 nights (push: rest, and if it
//            persists, check with a healthcare professional)
//
// HARD RULES: no tier ≥2 from a single night, ever (day-to-day HRV is noise,
// Plews et al. IJSPP 2013); the tier is clamped by the calibration stage
// (7–13 valid nights → tier 1 max, 14–29 → tier 2, ≥30 → tier 3); missing
// signals simply do not count (never "all green" — a night with no signal is
// tier 0, and the calibration block says which signals were unavailable).
//
// WORDING DISCIPLINE: everything here describes a deviation from the user's
// own baseline — never a condition, never a diagnosis. The check-in ASKS
// ("do you feel unusually tired or run down?") because self-report outperforms
// objective metrics for early detection (Saw et al., BJSM 2016); it never
// tells.

import 'dart:math' as math;

import '../data/day_label.dart' show calendarDaysBetween;
import 'findings.dart'
    show ExceptionNotice, Finding, FindingKind, isRecentFindingDate;

/// A signal counts as deviating when its residual robust-z reaches this.
const double kSignalZ = 1.5;

/// The tier-3 constellation needs a stronger per-signal deviation.
const double kConstellationZ = 2.0;

/// Consecutive nights (calendar gap ≤ this) that form a run.
const int kStreakMaxGapDays = 2;

/// Minimum baseline nights for a signal's residual z to mean anything.
const int kTierMinBaseline = 7;

/// Window, in calendar days, for a signal's trailing robust baseline.
const int kTierWindowDays = 60;

/// "I feel fine" damps the same detector family for this long (48 h).
const int kDampSeconds = 48 * 3600;

/// The illness state auto-expires after this many consecutive clean nights
/// back in baseline (or on user dismissal).
const int kIllnessAutoExpireNights = 3;

/// Signal names used in verdicts, notification copy and UI cards.
const List<String> kTierSignals = ['rhr', 'hrv', 'resp', 'temp'];

/// The verdict for the newest settled night.
class TierVerdict {
  const TierVerdict({
    required this.date,
    required this.tier,
    required this.signals,
    required this.streak,
    required this.constellation,
    required this.stage,
    required this.validNights,
    required this.z,
  });

  /// The night the verdict is ABOUT ('YYYY-MM-DD'), null when nothing settled.
  final String? date;

  /// 0–3, already clamped by the calibration stage.
  final int tier;

  /// Deviating signal names on that night (subset of [kTierSignals]).
  final List<String> signals;

  /// Consecutive nights ending at [date] with at least one deviating signal.
  final int streak;

  /// temp↑ AND resp↑ AND rhr↑ all present on [date].
  final bool constellation;

  /// Calibration stage (0–3) the verdict was gated by.
  final int stage;

  /// Valid nights behind the stage.
  final int validNights;

  /// Residual robust-z per signal on [date] (null when unavailable).
  final Map<String, double?> z;

  bool get anySignal => signals.isNotEmpty;
}

double? _median(List<double> xs) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2.0;
}

double? _robustScale(List<double> xs) {
  if (xs.isEmpty) return null;
  final m = _median(xs)!;
  final mad = _median([for (final x in xs) (x - m).abs()]) ?? 0;
  if (mad > 0) return 1.4826 * mad;
  if (xs.length < 2) return null;
  final mean = xs.reduce((a, b) => a + b) / xs.length;
  var acc = 0.0;
  for (final x in xs) {
    acc += (x - mean) * (x - mean);
  }
  final sd = math.sqrt(acc / (xs.length - 1));
  return sd > 0 ? sd : null;
}

DateTime? _day(String s) {
  if (s.isEmpty) return null;
  return DateTime.tryParse('${s}T00:00:00Z');
}

/// Residual robust-z of [series] at index [i], against the trailing settled
/// window (strictly before i, ≤ [kTierWindowDays] calendar days). Null when
/// there is no value tonight or no usable baseline — never fabricated.
double? _residualZ(
  List<String> dates,
  List<bool> unsettled,
  List<double?> series,
  int i,
) {
  final v = series[i];
  if (v == null || !v.isFinite || unsettled[i]) return null;
  final d = _day(dates[i]);
  if (d == null) return null;
  final window = <double>[];
  for (var j = 0; j < i; j++) {
    final x = series[j];
    if (x == null || !x.isFinite || unsettled[j]) continue;
    final dj = _day(dates[j]);
    if (dj == null || calendarDaysBetween(dj, d) > kTierWindowDays) continue;
    window.add(x);
  }
  if (window.length < kTierMinBaseline) return null;
  final scale = _robustScale(window);
  if (scale == null || scale <= 0) return null;
  return (v - _median(window)!) / scale;
}

/// Compute the tier verdict for the newest settled night from parallel
/// per-day series (oldest first), exactly as the cross-day bundle carries them.
TierVerdict? computeTierVerdict({
  required List<String> dates,
  required List<bool> unsettled,
  required List<double?> rhrResid,
  required List<double?> hrvResid,
  required List<double?> respResid,
  required List<double?> tempResid,
  required int stage,
  required int validNights,
}) {
  final n = dates.length;
  if (n == 0) return null;
  // The newest SETTLED night is the verdict's night — an unsettled today must
  // not be read as a clean one.
  var newest = -1;
  for (var i = n - 1; i >= 0; i--) {
    if (!unsettled[i]) {
      newest = i;
      break;
    }
  }
  if (newest < 0) return null;

  bool dev(String signal, double? z, {required bool up}) {
    if (z == null || !z.isFinite) return false;
    return up ? z >= kSignalZ : z <= -kSignalZ;
  }

  final zRhr = _residualZ(dates, unsettled, rhrResid, newest);
  final zHrv = _residualZ(dates, unsettled, hrvResid, newest);
  final zResp = _residualZ(dates, unsettled, respResid, newest);
  final zTemp = _residualZ(dates, unsettled, tempResid, newest);

  bool constellationAt(int i) {
    bool up(String name, List<double?> s) {
      final z = _residualZ(dates, unsettled, s, i);
      return z != null && z.isFinite && z >= kConstellationZ;
    }

    return up('rhr', rhrResid) && up('resp', respResid) && up('temp', tempResid);
  }

  bool anySignalAt(int i) {
    double? z(List<double?> s) => _residualZ(dates, unsettled, s, i);
    return dev('rhr', z(rhrResid), up: true) ||
        dev('hrv', z(hrvResid), up: false) ||
        dev('resp', z(respResid), up: true) ||
        dev('temp', z(tempResid), up: true);
  }

  final signals = <String>[
    if (dev('rhr', zRhr, up: true)) 'rhr',
    if (dev('hrv', zHrv, up: false)) 'hrv',
    if (dev('resp', zResp, up: true)) 'resp',
    if (dev('temp', zTemp, up: true)) 'temp',
  ];

  // The run of consecutive signal-nights ending at the newest settled night.
  // A calendar gap longer than [kStreakMaxGapDays] breaks it; a settled night
  // with no signal ends it.
  var streak = 0;
  var prevDay = _day(dates[newest]);
  for (var i = newest; i >= 0; i--) {
    if (unsettled[i]) continue;
    final d = _day(dates[i]);
    if (d == null) break;
    if (prevDay != null && calendarDaysBetween(d, prevDay) > kStreakMaxGapDays) {
      break;
    }
    if (!anySignalAt(i)) break;
    streak++;
    prevDay = d;
  }

  final constellation = constellationAt(newest);
  var raw = 0;
  if (signals.isNotEmpty) raw = 1;
  if (signals.length >= 2 && streak >= 2) raw = 2;
  if (constellation && streak >= 2) raw = 3;
  // The calibration stage caps the tier: 7–13 nights → tier 1 max,
  // 14–29 → tier 2, ≥30 → tier 3; below 7 → nothing at all.
  final tier = raw.clamp(0, stage).toInt();

  return TierVerdict(
    date: dates[newest],
    tier: tier,
    signals: signals,
    streak: streak,
    constellation: constellation,
    stage: stage,
    validNights: validNights,
    z: {'rhr': zRhr, 'hrv': zHrv, 'resp': zResp, 'temp': zTemp},
  );
}

/// The same verdict read back out of a stored cross-day bundle (`recent[]` +
/// `calibration`), for the notification pass and the UI — one shape, one
/// place, so the push, the card and the log cannot disagree.
TierVerdict? tierVerdictOfBundle(Map<String, dynamic> cd) {
  final recent = cd['recent'];
  final cal = cd['calibration'];
  if (recent is! List) return null;
  final dates = <String>[];
  final unsettled = <bool>[];
  final rhr = <double?>[];
  final hrv = <double?>[];
  final resp = <double?>[];
  final temp = <double?>[];
  for (final r in recent) {
    if (r is! Map || r['date'] is! String) continue;
    double? nn(Object? v) => v is num ? v.toDouble() : null;
    dates.add(r['date'] as String);
    unsettled.add(r['unsettled'] == true);
    rhr.add(nn(r['rhr_residual']));
    hrv.add(nn(r['hrv_residual']));
    resp.add(nn(r['resp_residual']));
    temp.add(nn(r['temp_residual']));
  }
  final stage = (cal is Map ? (cal['stage'] as num?)?.toInt() : null) ?? 0;
  final valid = (cal is Map ? (cal['valid_nights'] as num?)?.toInt() : null) ?? 0;
  return computeTierVerdict(
    dates: dates,
    unsettled: unsettled,
    rhrResid: rhr,
    hrvResid: hrv,
    respResid: resp,
    tempResid: temp,
    stage: stage,
    validNights: valid,
  );
}

/// The persisted illness state (the user told us they are unwell): while
/// active, the illness-signature deviations are EXPECTED, so tier ≥2 pushes
/// stand down and the card shows a gentle note instead. Auto-expires after
/// [kIllnessAutoExpireNights] clean nights or on dismissal.
class IllnessState {
  const IllnessState({required this.active, this.since, this.cleanNights = 0});

  final bool active;

  /// The day the state was activated ('YYYY-MM-DD'), for display only.
  final String? since;

  /// Consecutive nights back in baseline since activation.
  final int cleanNights;

  Map<String, dynamic> toJson() => {
        'active': active,
        if (since != null) 'since': since,
        'clean_nights': cleanNights,
      };

  static IllnessState fromJson(Object? v) {
    if (v is! Map) return const IllnessState(active: false);
    return IllnessState(
      active: v['active'] == true,
      since: v['since'] is String ? v['since'] as String : null,
      cleanNights: (v['clean_nights'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is IllnessState &&
      other.active == active &&
      other.since == since &&
      other.cleanNights == cleanNights;

  @override
  int get hashCode => Object.hash(active, since, cleanNights);

  /// Pure transition: [anySignal] is whether the newest settled night showed
  /// any residual signal deviation. An active state counts clean nights and
  /// expires after [kIllnessAutoExpireNights]; an inactive state only ever
  /// changes through the user's reply ([activate]).
  IllnessState next({required bool anySignal}) {
    if (!active) return this;
    if (anySignal) return IllnessState(active: true, since: since, cleanNights: 0);
    final clean = cleanNights + 1;
    if (clean >= kIllnessAutoExpireNights) {
      return const IllnessState(active: false);
    }
    return IllnessState(active: true, since: since, cleanNights: clean);
  }

  IllnessState activate(String date) =>
      IllnessState(active: true, since: date, cleanNights: 0);
}

/// One ask-first check-in push about a night. Tier 2 and tier 3 only — tier 1
/// never interrupts.
class CheckInNotice {
  const CheckInNotice({
    required this.date,
    required this.tier,
    required this.streak,
    required this.signals,
  });

  /// The night the check-in is ABOUT ('YYYY-MM-DD').
  final String date;

  /// 2 or 3.
  final int tier;

  /// Consecutive deviating nights behind the tier.
  final int streak;

  final List<String> signals;

  /// Same grammar as the exception notices ('$date:…'), keyed on the night it
  /// is about — so a night buzzes at most once — with the medical tier marked.
  String get dedupeKey => tier >= 3 ? '$date:checkin:medical' : '$date:checkin';

  /// Tap-through target (iOS has no push actions): the in-app check-in sheet.
  String get route => '/checkin?date=$date&tier=$tier';

  // Wording: English source here, localized at OS-present time through
  // localizedNotificationText. Mechanism, never condition.
  String get title =>
      tier >= 3 ? 'Values above your usual for several nights' : 'Off your usual lately';

  String get body => tier >= 3
      ? 'Across skin temperature, breathing rate and resting heart rate, your values have been above your usual for the last $streak nights. Consider rest, and if this persists, consider checking with a healthcare professional.'
      : 'Your values have deviated from your baseline for the last $streak nights. Do you feel unusually tired or run down?';
}

/// The whole tier-2/3 decision the notification pass makes, minus the I/O.
///
/// Returns null (quiet, never a push) when: nothing settled; tier < 2 (single
/// signal or a single night — persistence requirement); the verdict is not
/// about today/yesterday (calendar gate, DST-safe); the illness state is
/// active (the deviations are expected — masked, not re-warned); or the 48 h
/// damping after an "I feel fine" reply is still in force.
CheckInNotice? planCheckIn(
  Map<String, dynamic> cd, {
  required String today,
  required int nowSec,
  bool illnessActive = false,
  int dampUntilSec = 0,
}) {
  final v = tierVerdictOfBundle(cd);
  if (v == null || v.date == null) return null;
  if (v.tier < 2) return null;
  if (!isRecentFindingDate(v.date!, today: today)) return null;
  if (illnessActive) return null;
  if (dampUntilSec > nowSec) return null;
  return CheckInNotice(
    date: v.date!,
    tier: v.tier,
    streak: v.streak,
    signals: v.signals,
  );
}

/// Gate the aggregated exception notices for the tier system.
///
/// The overnight DEVIATION findings (illness CUSUM / overnight anomaly /
/// skin-temp flag) no longer push on their own: tier ≥2 pushes as the
/// ask-first check-in ([planCheckIn]) and tier 1 is card-only. When a
/// check-in fired for a night, the whole aggregated notice for that night
/// stands down, so a night still buzzes at most once. The other kinds — the
/// irregular-rhythm screen, low readiness, the RHR trend shift — are not part
/// of the deviation tiers and keep their existing push behaviour.
List<ExceptionNotice> gateExceptionNotices(
  List<ExceptionNotice> notices, {
  String? checkInDate,
}) {
  final out = <ExceptionNotice>[];
  for (final n in notices) {
    if (checkInDate != null && n.date == checkInDate) continue;
    final kept = <Finding>[
      for (final f in n.findings)
        if (f.kind != FindingKind.illness &&
            f.kind != FindingKind.anomaly &&
            f.kind != FindingKind.tempElevated)
          f,
    ];
    if (kept.isEmpty) continue;
    out.add(ExceptionNotice(n.date, kept));
  }
  return out;
}
