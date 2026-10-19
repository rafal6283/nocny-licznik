import 'package:bakometr_native/bakometr_native.dart';

import 'settings.dart';

/// Codzienne przypomnienie o pójściu spać.
class Reminders {
  static const bedtimeId = 1;

  static Future<void> sync() async {
    final s = Settings.instance;
    await BakometrNative.cancelNotification(bedtimeId);
    if (!s.bedtimeReminder) return;
    await BakometrNative.requestNotificationPermission();
    final now = DateTime.now();
    var at = DateTime(now.year, now.month, now.day, s.bedtimeHour, s.bedtimeMinute);
    if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
    await BakometrNative.scheduleNotification(
      id: bedtimeId,
      at: at,
      title: 'Czas do łóżka 🌙',
      body: 'Odłóż telefon obok poduszki i uruchom Bąkometr.',
      daily: true,
    );
  }
}
