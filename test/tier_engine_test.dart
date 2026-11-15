// Tier engine (lib/compute/tier_engine.dart): the layer-3 aggregation over the
// residuals — tier rules (persistence, consensus, calibration-stage cap), the
// ask-first check-in decision (planCheckIn), the illness state machine, the
// notice gating, and the wording discipline (mechanism, never a condition).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/crossday_pipeline.dart';
import 'package:openstrap_edge/compute/findings.dart';
import 'package:openstrap_edge/compute/tier_engine.dart';
import 'package:openstrap_edge/notify/checkin.dart';

String _d(int i) {
  final dt = DateTime(2024, 1, 1 + i);
  return '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
}

/// n days from 2024-01-01. Baseline wobble ±2 (rhr) / ±3 (rmssd) / ±0.6 (resp)
/// / ±16 ADC (temp) so the MAD scale is small and a spike is a large z.
List<String> _dates(int n) => [for (var i = 0; i < n; i++) _d(i)];

List<double?> _flat(int n, double? v) => [for (var i = 0; i < n; i++) v];

List<double?> _wobble(int n, double base, double amp) => [
      for (var i = 0; i < n; i++) base + ((i % 5) - 2) * amp,
    ];

/// A bundle-shaped map as the stored cross-day artifact carries it.
Map<String, dynamic> _bundle(
  List<String> dates, {
  required List<double?> rhr,
  required List<double?> hrv,
  required List<double?> resp,
  required List<double?> temp,
  List<bool>? unsettled,
  int stage = 3,
  int valid = 40,
}) =>
    {
      'recent': [
        for (var i = 0; i < dates.length; i++)
          {
            'date': dates[i],
            'unsettled': unsettled?[i] == true,
            'rhr_residual': rhr[i],
            'hrv_residual': hrv[i],
            'resp_residual': resp[i],
            'temp_residual': temp[i],
          },
      ],
      'calibration': {'stage': stage, 'valid_nights': valid},
    };

void main() {
  group('tier rules (computeTierVerdict)', () {
    test('single bad night after a clean month -> tier 1, never tier 2', () {
      final n = 40;
      final dates = _dates(n);
      final rhr = _wobble(n, 55, 1); // MAD 1 -> scale ~1.48
      final hrv = _wobble(n, 45, 1.5);
      final resp = _wobble(n, 14, 0.3);
      final temp = _wobble(n, 3000, 8);
      rhr[n - 1] = 62; // +7 -> z ~ +4.7
      hrv[n - 1] = 36; // -9 -> z ~ -4
      final v = computeTierVerdict(
        dates: dates,
        unsettled: List.filled(n, false),
        rhrResid: rhr,
        hrvResid: hrv,
        respResid: resp,
        tempResid: temp,
        stage: 3,
        validNights: 40,
      )!;
      expect(v.tier, 1, reason: 'persistence: one night is noise (Plews 2013)');
      expect(v.streak, 1);
      expect(v.signals, containsAll(['rhr', 'hrv']));
      expect(v.constellation, isFalse);
    });

    test('two signals for two nights -> tier 2', () {
      final n = 40;
      final dates = _dates(n);
      final rhr = _wobble(n, 55, 1);
      final hrv = _wobble(n, 45, 1.5);
      final resp = _wobble(n, 14, 0.3);
      final temp = _wobble(n, 3000, 8);
      for (var i = n - 2; i < n; i++) {
        rhr[i] = 62;
        hrv[i] = 36;
      }
      final v = computeTierVerdict(
        dates: dates,
        unsettled: List.filled(n, false),
        rhrResid: rhr,
        hrvResid: hrv,
        respResid: resp,
        tempResid: temp,
        stage: 3,
        validNights: 40,
      )!;
      expect(v.tier, 2);
      expect(v.streak, 2);
      expect(v.signals.length, 2);
    });

    test('one signal for five nights stays tier 1 (consensus needs >=2)', () {
      final n = 40;
      final dates = _dates(n);
      final rhr = _wobble(n, 55, 1);
      final hrv = _wobble(n, 45, 1.5);
      final resp = _wobble(n, 14, 0.3);
      final temp = _wobble(n, 3000, 8);
      for (var i = n - 5; i < n; i++) {
        rhr[i] = 62;
      }
      final v = computeTierVerdict(
        dates: dates,
        unsettled: List.filled(n, false),
        rhrResid: rhr,
        hrvResid: hrv,
        respResid: resp,
        tempResid: temp,
        stage: 3,
        validNights: 40,
      )!;
      expect(v.streak, 5);
      expect(v.tier, 1, reason: 'a single signal never reaches tier 2');
    });

    test('fever-like constellation (temp+resp+rhr up) for 2 nights -> tier 3',
        () {
      final n = 40;
      final dates = _dates(n);
      final rhr = _wobble(n, 55, 1);
      final hrv = _wobble(n, 45, 1.5);
      final resp = _wobble(n, 14, 0.3);
      final temp = _wobble(n, 3000, 8);
      for (var i = n - 2; i < n; i++) {
        rhr[i] = 62; // z ~ +4.7
        resp[i] = 17; // z ~ +6.8
        temp[i] = 3048; // z ~ +4
      }
      final v = computeTierVerdict(
        dates: dates,
        unsettled: List.filled(n, false),
        rhrResid: rhr,
        hrvResid: hrv,
        respResid: resp,
        tempResid: temp,
        stage: 3,
        validNights: 40,
      )!;
      expect(v.constellation, isTrue);
      expect(v.tier, 3);
    });

    test('constellation on a single night -> tier 1 (no tier 3 from one night)',
        () {
      final n = 40;
      final dates = _dates(n);
      final rhr = _wobble(n, 55, 1);
      final hrv = _wobble(n, 45, 1.5);
      final resp = _wobble(n, 14, 0.3);
      final temp = _wobble(n, 3000, 8);
      rhr[n - 1] = 62;
      resp[n - 1] = 17;
      temp[n - 1] = 3048;
      final v = computeTierVerdict(
        dates: dates,
        unsettled: List.filled(n, false),
        rhrResid: rhr,
        hrvResid: hrv,
        respResid: resp,
        tempResid: temp,
        stage: 3,
        validNights: 40,
      )!;
      expect(v.constellation, isTrue);
      expect(v.streak, 1);
      expect(v.tier, 1);
    });

    test('a 3-day calendar gap breaks the streak', () {
      final dates = [..._dates(37), _d(40), _d(41)]; // gap of 3 days
      final n = dates.length;
      final rhr = _wobble(n, 55, 1);
      final hrv = _wobble(n, 45, 1.5);
      final resp = _wobble(n, 14, 0.3);
      final temp = _wobble(n, 3000, 8);
      for (var i = n - 2; i < n; i++) {
        rhr[i] = 62;
        hrv[i] = 36;
      }
      rhr[36] = 62; // a deviating night before the gap does not extend the run
      hrv[36] = 36;
      final v = computeTierVerdict(
        dates: dates,
        unsettled: List.filled(n, false),
        rhrResid: rhr,
        hrvResid: hrv,
        respResid: resp,
        tempResid: temp,
        stage: 3,
        validNights: 40,
      )!;
      expect(v.streak, 2, reason: 'the run ends at the gap, not before it');
    });

    test('missing signal does not count and is honestly null, never green', () {
      final n = 40;
      final dates = _dates(n);
      final rhr = _wobble(n, 55, 1);
      final hrv = _wobble(n, 45, 1.5);
      final resp = _wobble(n, 14, 0.3);
      final temp = _flat(n, null); // sensor withheld
      for (var i = n - 2; i < n; i++) {
        rhr[i] = 62;
        resp[i] = 17;
      }
      final v = computeTierVerdict(
        dates: dates,
        unsettled: List.filled(n, false),
        rhrResid: rhr,
        hrvResid: hrv,
        respResid: resp,
        tempResid: temp,
        stage: 3,
        validNights: 40,
      )!;
      expect(v.z['temp'], isNull);
      expect(v.signals, isNot(contains('temp')));
      expect(v.constellation, isFalse,
          reason: 'the constellation needs all three; missing is not normal');
      expect(v.tier, 2, reason: 'rhr+resp consensus still reaches tier 2');
    });

    test('unsettled newest night: the verdict is about the newest SETTLED one',
        () {
      final n = 40;
      final dates = _dates(n);
      final rhr = _wobble(n, 55, 1);
      final hrv = _wobble(n, 45, 1.5);
      final resp = _wobble(n, 14, 0.3);
      final temp = _wobble(n, 3000, 8);
      rhr[n - 2] = 62;
      hrv[n - 2] = 36;
      rhr[n - 1] = 70; // unsettled today: must not be read as a clean OR bad night
      final unsettled = List<bool>.filled(n, false)..[n - 1] = true;
      final v = computeTierVerdict(
        dates: dates,
        unsettled: unsettled,
        rhrResid: rhr,
        hrvResid: hrv,
        respResid: resp,
        tempResid: temp,
        stage: 3,
        validNights: 39,
      )!;
      expect(v.date, dates[n - 2]);
      expect(v.tier, 1);
    });

    test('all nights unsettled -> null, not a clean verdict', () {
      final n = 10;
      final v = computeTierVerdict(
        dates: _dates(n),
        unsettled: List.filled(n, true),
        rhrResid: _flat(n, 55),
        hrvResid: _flat(n, 45),
        respResid: _flat(n, 14),
        tempResid: _flat(n, 3000),
        stage: 3,
        validNights: 10,
      );
      expect(v, isNull);
    });
  });

  group('calibration stage caps the tier', () {
    TierVerdict verdictAtStage(int stage, int valid) {
      final n = 40;
      final dates = _dates(n);
      final rhr = _wobble(n, 55, 1);
      final hrv = _wobble(n, 45, 1.5);
      final resp = _wobble(n, 14, 0.3);
      final temp = _wobble(n, 3000, 8);
      for (var i = n - 2; i < n; i++) {
        rhr[i] = 62;
        resp[i] = 17;
        temp[i] = 3048;
      }
      return computeTierVerdict(
        dates: dates,
        unsettled: List.filled(n, false),
        rhrResid: rhr,
        hrvResid: hrv,
        respResid: resp,
        tempResid: temp,
        stage: stage,
        validNights: valid,
      )!;
    }

    test('stage 0 (<7 valid nights): calibrating, tier 0, no signals counted', () {
      final v = verdictAtStage(0, 5);
      expect(v.tier, 0);
      expect(v.stage, 0);
      expect(v.validNights, 5);
    });

    test('stage 1 (7-13 nights): tier 1 max even for a constellation', () {
      expect(verdictAtStage(1, 10).tier, 1);
    });

    test('stage 2 (14-29 nights): tier 2 max even for a constellation', () {
      expect(verdictAtStage(2, 20).tier, 2);
    });

    test('stage 3 (>=30 nights): full sensitivity, tier 3', () {
      expect(verdictAtStage(3, 40).tier, 3);
    });
  });

  group('planCheckIn (the push decision)', () {
    Map<String, dynamic> spikeBundle({int spikeFrom = 38, int n = 41}) {
      final dates = _dates(n);
      final rhr = _wobble(n, 55, 1);
      final hrv = _wobble(n, 45, 1.5);
      final resp = _wobble(n, 14, 0.3);
      final temp = _wobble(n, 3000, 8);
      for (var i = spikeFrom; i < n; i++) {
        rhr[i] = 62;
        resp[i] = 17;
        temp[i] = 3048;
      }
      return _bundle(dates,
          rhr: rhr, hrv: hrv, resp: resp, temp: temp, stage: 3, valid: 41);
    }

    test('tier 3 constellation about today -> one notice, medical dedupe key', () {
      final cd = spikeBundle();
      final notice = planCheckIn(cd, today: _d(40), nowSec: 1000);
      expect(notice, isNotNull);
      expect(notice!.tier, 3);
      expect(notice.streak, 3);
      expect(notice.dedupeKey, '${_d(40)}:checkin:medical');
      expect(notice.route, '/checkin?date=${_d(40)}&tier=3');
    });

    test('tier 2 -> plain checkin key; tier 1 -> quiet (card only)', () {
      final cd = spikeBundle();
      // Only rhr+hrv deviate -> tier 2 shape: rebuild with just those two.
      final dates = _dates(41);
      final rhr = _wobble(41, 55, 1);
      final hrv = _wobble(41, 45, 1.5);
      final resp = _wobble(41, 14, 0.3);
      final temp = _wobble(41, 3000, 8);
      for (var i = 39; i < 41; i++) {
        rhr[i] = 62;
        hrv[i] = 36;
      }
      final tier2 = _bundle(dates,
          rhr: rhr, hrv: hrv, resp: resp, temp: temp, stage: 3, valid: 41);
      final n2 = planCheckIn(tier2, today: _d(40), nowSec: 1000)!;
      expect(n2.tier, 2);
      expect(n2.dedupeKey, '${_d(40)}:checkin');

      final rhr1 = _wobble(41, 55, 1);
      final hrv1 = _wobble(41, 45, 1.5);
      rhr1[40] = 62; // one signal, one night
      final tier1 = _bundle(dates,
          rhr: rhr1, hrv: hrv1, resp: resp, temp: temp, stage: 3, valid: 41);
      expect(planCheckIn(tier1, today: _d(40), nowSec: 1000), isNull,
          reason: 'tier 1 never pushes');
      expect(cd, isNotNull);
    });

    test('verdict older than yesterday -> quiet (calendar gate, DST-safe)', () {
      final cd = spikeBundle();
      expect(planCheckIn(cd, today: _d(40), nowSec: 1000), isNotNull);
      expect(planCheckIn(cd, today: _d(41), nowSec: 1000),
          isNotNull); // yesterday is still fresh
      expect(planCheckIn(cd, today: _d(42), nowSec: 1000), isNull,
          reason: 'two days old: lives in Observations, not on a push');
    });

    test('illness state active -> masked, no re-warning', () {
      final cd = spikeBundle();
      expect(
          planCheckIn(cd, today: _d(40), nowSec: 1000, illnessActive: true),
          isNull);
    });

    test('48 h damping after "I feel fine" -> quiet; expired damping -> fires',
        () {
      final cd = spikeBundle();
      expect(planCheckIn(cd, today: _d(40), nowSec: 1000, dampUntilSec: 2000),
          isNull);
      expect(planCheckIn(cd, today: _d(40), nowSec: 3000, dampUntilSec: 2000),
          isNotNull);
    });
  });

  group('illness state machine', () {
    test('activate, count clean nights, auto-expire after 3', () {
      var s = const IllnessState(active: false);
      expect(s.next(anySignal: true), same(const IllnessState(active: false)),
          reason: 'only the user reply activates');
      s = s.activate('2024-02-08');
      expect(s.active, isTrue);
      expect(s.since, '2024-02-08');
      s = s.next(anySignal: true);
      expect(s.cleanNights, 0, reason: 'a deviating night resets the count');
      s = s.next(anySignal: false);
      expect(s.cleanNights, 1);
      s = s.next(anySignal: false);
      expect(s.active, isTrue);
      expect(s.cleanNights, 2);
      s = s.next(anySignal: false);
      expect(s.active, isFalse, reason: '3 clean nights back in baseline end it');
    });

    test('json round-trip', () {
      const s = IllnessState(active: true, since: '2024-02-08', cleanNights: 2);
      expect(IllnessState.fromJson(s.toJson()), s);
      expect(IllnessState.fromJson(null).active, isFalse);
      expect(IllnessState.fromJson('garbage').active, isFalse);
    });
  });

  group('gateExceptionNotices', () {
    final illness = Finding(FindingKind.illness, '2024-02-10');
    final anomaly = Finding(FindingKind.anomaly, '2024-02-09');
    final temp = Finding(FindingKind.tempElevated, '2024-02-10');
    final lowRec = Finding(FindingKind.lowReadiness, '2024-02-10', score: 3);
    final rhythm =
        Finding(FindingKind.irregularRhythm, '2024-02-09');

    test('deviation findings never push on their own; other kinds keep theirs',
        () {
      final out = gateExceptionNotices([
        ExceptionNotice('2024-02-10', [illness, temp, lowRec]),
        ExceptionNotice('2024-02-09', [anomaly, rhythm]),
      ]);
      expect(out.length, 2);
      expect(out[0].date, '2024-02-10');
      expect(out[0].findings.map((f) => f.kind), [FindingKind.lowReadiness]);
      expect(out[1].findings.map((f) => f.kind),
          [FindingKind.irregularRhythm]);
    });

    test('when the check-in fired for a night, that night stays at one push',
        () {
      final out = gateExceptionNotices(
        [ExceptionNotice('2024-02-10', [lowRec])],
        checkInDate: '2024-02-10',
      );
      expect(out, isEmpty);
    });
  });

  group('wording discipline (no diagnosis, ever)', () {
    final banned = RegExp(
        r'\b(flu|cold|infection|infected|diagnos\w+|hypertension|overtrain\w*|sick with)\b',
        caseSensitive: false);

    test('check-in titles and bodies describe mechanism, never a condition', () {
      for (final tier in [2, 3]) {
        final n = CheckInNotice(
            date: '2024-02-10', tier: tier, streak: 3, signals: const ['rhr']);
        expect(banned.hasMatch(n.title), isFalse, reason: n.title);
        expect(banned.hasMatch(n.body), isFalse, reason: n.body);
      }
      final t2 = CheckInNotice(
          date: '2024-02-10', tier: 2, streak: 3, signals: const ['rhr']);
      expect(t2.body, contains('your usual'), reason: 'names the mechanism');
      expect(t2.body, contains('?'), reason: 'tier 2 ASKS (Saw 2016)');
      final t3 = CheckInNotice(
          date: '2024-02-10', tier: 3, streak: 3, signals: const ['rhr']);
      expect(t3.body, contains('your usual'));
      expect(t3.body, contains('healthcare professional'));
    });
  });

  group('check-in action ids', () {
    test('round-trip and rejects foreign ids', () {
      // ignore: avoid_redundant_argument_values
      final id = checkInActionId(CheckInReply.sick, '2024-02-10');
      expect(id, 'checkin:sick:2024-02-10');
      final parsed = parseCheckInActionId(id)!;
      expect(parsed.reply, CheckInReply.sick);
      expect(parsed.date, '2024-02-10');
      expect(parseCheckInActionId('checkin:nope:2024-02-10'), isNull);
      expect(parseCheckInActionId('other:fine:2024-02-10'), isNull);
      expect(parseCheckInActionId('checkin:fine:'), isNull);
    });
  });

  group('pipeline integration (buildCrossDayBundle carries the tiers block)', () {
    List<Map<String, dynamic>> days(int n) => [
          for (var i = 0; i < n; i++)
            {
              'date': _d(i),
              'rhr': 55.0 + ((i % 5) - 2),
              'rmssd': 45.0 + ((i % 5) - 2) * 1.5,
              'readiness': 70.0,
              'resp_rate': 14.0 + ((i % 5) - 2) * 0.3,
              'skin_temp_z': ((i % 5) - 2) * 0.4,
              'skin_temp_adc': 3000.0 + ((i % 5) - 2) * 8.0,
              'skin_temp_family': 'gen4',
              'trimp': 80.0,
              'strain': 6.0 + (i % 3),
              'tst_min': 450,
              'onset_sec': 23 * 3600,
              'wake_sec': 31 * 3600,
            },
        ];

    test('fixture 8 at the tier layer: unexplained 3-night constellation -> tier 3 push',
        () {
      final ds = days(41);
      for (var i = 38; i <= 40; i++) {
        ds[i]['rhr'] = 62.0;
        ds[i]['resp_rate'] = 17.0;
        ds[i]['skin_temp_adc'] = 3040.0;
        ds[i]['rmssd'] = 36.0;
      }
      final b = buildCrossDayBundle(ds, const {});
      final tiers = b['tiers'] as Map;
      expect(tiers['date'], _d(40));
      expect(tiers['tier'], 3);
      expect(tiers['streak'], 3);
      expect(tiers['constellation'], isTrue);
      expect(tiers['signals'], containsAll(['rhr', 'resp', 'temp']));
      final notice = planCheckIn(b, today: _d(40), nowSec: 1000);
      expect(notice, isNotNull);
      expect(notice!.tier, 3);
      expect(notice.dedupeKey, '${_d(40)}:checkin:medical');
    });

    test('fixture 6 at the tier layer: one bad night after a clean month -> no push',
        () {
      final ds = days(41);
      ds[40]['rhr'] = 62.0;
      ds[40]['rmssd'] = 36.0;
      final b = buildCrossDayBundle(ds, const {});
      expect((b['tiers'] as Map)['tier'], 1);
      expect(planCheckIn(b, today: _d(40), nowSec: 1000), isNull);
    });

    test('fixture 11 at the tier layer: <7 valid nights -> tier 0, calibrating, no push',
        () {
      final ds = days(5);
      ds[4]['rhr'] = 70.0;
      ds[4]['rmssd'] = 30.0;
      final b = buildCrossDayBundle(ds, const {});
      expect((b['calibration'] as Map)['stage'], 0);
      expect((b['tiers'] as Map)['tier'], 0);
      expect(planCheckIn(b, today: _d(4), nowSec: 1000), isNull);
    });

    test('fixture 12 at the tier layer: a 21-day wear gap caps the tier at stage 2',
        () {
      final ds = [
        ...days(35),
        for (var k = 0; k < 3; k++)
          {
            ...days(1).first,
            'date': _d(35 + 21 + k), // 2024-02-25..27, after a 21-day gap
          },
      ];
      // spike the last two nights of the post-gap run
      ds[36]['rhr'] = 62.0;
      ds[36]['resp_rate'] = 17.0;
      ds[36]['skin_temp_adc'] = 3048.0;
      ds[37]['rhr'] = 62.0;
      ds[37]['resp_rate'] = 17.0;
      ds[37]['skin_temp_adc'] = 3048.0;
      final b = buildCrossDayBundle(ds, const {});
      expect((b['calibration'] as Map)['stage'], 2);
      expect((b['tiers'] as Map)['tier'], 2,
          reason: 'the gap drops one stage, so a constellation caps at tier 2');
    });
  });
}
