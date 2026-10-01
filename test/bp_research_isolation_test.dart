// THE INVARIANT the BP research store exists to have.
//
// `bp_research_reference` / `bp_research_window` hold a cuff reading next to
// the band's own decoded data from the same instant. That pairing is exactly
// the input a cuffless-blood-pressure claim would be built from, which is
// the category that earned WHOOP an FDA Warning Letter in Jul 2025 — so the
// tables are fenced the same way `observation` is: nothing outside the
// allow-list may name either table, and the allow-list names the readers
// whose whole job is showing/exporting research data to the user.
//
// Layer 1 (structural source scan) reuses the mechanism
// observation_isolation_test.dart is built on. A violation is SILENT — no
// exception, just a wrist-vs-cuff regression one PR later — so the control
// is a test that goes red, not a comment that says don't.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The ONLY files allowed to name either BP research table.
///
/// Adding to this list is the deliberate act the invariant asks for. Before
/// you do: a READER for the dev screen or the CSV export is fine. Anything
/// in `lib/compute/`, anything that feeds `day_result`, `metric_series` or
/// a baseline, and anything that writes to HealthKit / Health Connect is
/// the thing this whole file exists to stop.
const _allowed = {
  'lib/data/db.dart',
  'lib/data/csv_export.dart',
  'lib/health/bp_research_capture.dart',
  'lib/ui2/profile/bp_research.dart',
};

void main() {
  test('no file outside the allow-list names a BP research table', () {
    final offenders = <String>[];
    final lib = Directory('lib');
    for (final f in lib.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final rel = p.normalize(f.path);
      final s = f.readAsStringSync();
      final hit = s.contains('bp_research_reference') ||
          s.contains('bp_research_window') ||
          s.contains('bp_research_snapshot') ||
          s.contains('bpResearchCaptures') ||
          s.contains('putBpResearchCapture') ||
          s.contains('deleteBpResearchCapture');
      if (hit && !_allowed.contains(rel)) offenders.add(rel);
    }
    expect(offenders, isEmpty,
        reason: 'files naming the BP research store must be on the allow-list '
            'in test/bp_research_isolation_test.dart');
  });

  test('the allow-list files themselves all exist', () {
    for (final rel in _allowed) {
      expect(File(rel).existsSync(), isTrue, reason: '$rel has vanished');
    }
  });
}
