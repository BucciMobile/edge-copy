import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/state/locale_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OS notification copy follows the app language', () {
    late LocaleController controller;

    tearDown(() => controller.dispose());

    test('russian UI gets russian titles and bodies', () {
      controller = LocaleController.seed('ru')..useForPresentation();
      final t = NotificationService.osText;

      expect(t('Your recovery is ready'), 'Оценка восстановления готова');
      expect(t('Low battery'), 'Низкий заряд');
      expect(t('Step goal reached'), 'Цель по шагам достигнута');
      expect(t('Alarm not confirmed'), 'Будильник не подтверждён');

      // Bodies exactly as the producers interpolate them.
      expect(t('Recovery 64, slept 7h 5m.'), 'Восстановление 64, сон 7 ч 5 мин.');
      expect(t('Recovery 64.'), 'Восстановление 64.');
      expect(t('You hit about 10234 steps — at or above your 10000 goal.'),
          'Вы прошли около 10234 шагов — не меньше цели в 10000.');
      expect(t('Your band is at 12%. Charge it soon.'),
          'Заряд браслета 12%. Скоро зарядите его.');
    });

    test('english UI and unknown copy pass through unchanged', () {
      controller = LocaleController.seed('en')..useForPresentation();
      expect(NotificationService.osText('Recovery 64, slept 7h 5m.'),
          'Recovery 64, slept 7h 5m.');
      controller.dispose();
      controller = LocaleController.seed('ru')..useForPresentation();
      expect(NotificationService.osText('Some unmapped reminder'),
          'Some unmapped reminder');
    });
  });
}
