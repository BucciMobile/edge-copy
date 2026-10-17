import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/l10n/decimal_text.dart';
import 'package:openstrap_edge/state/locale_controller.dart';
import 'package:openstrap_edge/ui2/profile/wearable_numbers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The strain trend screen formats through displayFixed; every other place
  // that prints the same strain number has to use the same separator, or a
  // German user sees "12.3" on one screen and "12,3" on the next.
  test('strain cells use the display locale decimal separator', () {
    SharedPreferences.setMockInitialValues({});
    final controller = LocaleController.seed('de')..useForPresentation();
    addTearDown(controller.dispose);
    final de = lookupAppLocalizations(const Locale('de'));

    expect(displayFixed(12.3, 1), '12,3');
    expect(formatCell(de, 'strain', 12.3).$1, displayFixed(12.3, 1));
  });
}
