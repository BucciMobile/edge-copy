import 'package:flutter_test/flutter_test.dart';

import '../tool/update_wger_exercises.dart';
import '../tool/wger_weightlifting_selection.dart';

List<Map<String, Object?>> _reviewedRows() => [
  for (final id in wgerWeightliftingSelection.keys)
    {
      'uuid': id,
      'category': {'name': 'Arms'},
    },
];

void main() {
  test('refresh ignores unreviewed entries even in a lifting category', () {
    final reviewed = _reviewedRows();
    final selected = selectWeightliftingExercises([
      ...reviewed,
      {
        'uuid': 'unreviewed-cardio',
        'category': {'name': 'Cardio'},
      },
      {
        'uuid': 'unreviewed-breathing',
        'category': {'name': 'Abs'},
      },
      {
        'uuid': 'unreviewed-stretch',
        'category': {'name': 'Legs'},
      },
      {
        'uuid': 'unreviewed-lift',
        'category': {'name': 'Arms'},
      },
    ]);
    expect(selected, reviewed);
  });

  test('refresh refuses to silently drop a reviewed exercise', () {
    final rows = _reviewedRows()..removeLast();
    expect(() => selectWeightliftingExercises(rows), throwsStateError);
  });

  test('refresh refuses duplicate reviewed UUIDs', () {
    final rows = _reviewedRows();
    rows.add(rows.first);
    expect(() => selectWeightliftingExercises(rows), throwsStateError);
  });

  test('reviewed UUIDs cannot turn into cardio or an unknown category', () {
    for (final category in ['Cardio', 'Yoga', '']) {
      final rows = _reviewedRows();
      rows.first['category'] = {'name': category};
      expect(
        () => selectWeightliftingExercises(rows),
        throwsStateError,
        reason: category,
      );
    }
  });
}
