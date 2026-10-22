import 'package:flutter/services.dart';

/// Cienka warstwa nad natywnym kodem Androida (Java) i iOS (Swift).
class BakometrNative {
  static const MethodChannel _ch = MethodChannel('bakometr_native');

  /// Android: usługa pierwszoplanowa z mikrofonem + blokada uśpienia CPU.
  /// iOS: nic (działanie w tle zapewnia aktywne nagrywanie + tryb audio w tle).
  static Future<void> startTracking({required String title, required String text}) =>
      _safe(() => _ch.invokeMethod('startTracking', {'title': title, 'text': text}));

  static Future<void> updateTracking(String text) =>
      _safe(() => _ch.invokeMethod('updateTracking', {'text': text}));

  static Future<void> stopTracking() => _safe(() => _ch.invokeMethod('stopTracking'));

  /// Natężenie światła w luksach. Android: czujnik światła otoczenia.
  /// iOS: szacunek z ekspozycji przedniej kamery (tylko gdy aplikacja jest na
  /// pierwszym planie). Zwraca null, gdy pomiar jest niemożliwy.
  static Future<double?> measureLux() async {
    try {
      final v = await _ch.invokeMethod<num>('measureLux');
      return v?.toDouble();
    } catch (_) {
      return null;
    }
  }

  /// true = ciągły pomiar w tle jest możliwy (Android z czujnikiem światła).
  static Future<bool> canMeasureLuxInBackground() async {
    try {
      return await _ch.invokeMethod<bool>('canMeasureLuxInBackground') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> vibrate(int ms) => _safe(() => _ch.invokeMethod('vibrate', {'ms': ms}));

  static Future<void> scheduleNotification({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    bool daily = false,
  }) =>
      _safe(() => _ch.invokeMethod('scheduleNotification', {
            'id': id,
            'at': at.millisecondsSinceEpoch,
            'title': title,
            'body': body,
            'daily': daily,
          }));

  static Future<void> cancelNotification(int id) =>
      _safe(() => _ch.invokeMethod('cancelNotification', {'id': id}));

  /// Powiadomienie budzika (Android: pełnoekranowe, pokazuje aplikację na blokadzie).
  static Future<void> showAlarm({required String title, required String body}) =>
      _safe(() => _ch.invokeMethod('showAlarm', {'title': title, 'body': body}));

  static Future<void> cancelAlarm() => _safe(() => _ch.invokeMethod('cancelAlarm'));

  static Future<void> requestNotificationPermission() =>
      _safe(() => _ch.invokeMethod('requestNotificationPermission'));

  static Future<void> setKeepScreenOn(bool on) =>
      _safe(() => _ch.invokeMethod('setKeepScreenOn', {'on': on}));

  // --- Health Connect (tylko Android) ---

  /// 'available' | 'update' (trzeba zainstalować/zaktualizować Health Connect) | 'unavailable'
  static Future<String> healthConnectStatus() async {
    try {
      return await _ch.invokeMethod<String>('hcStatus') ?? 'unavailable';
    } catch (_) {
      return 'unavailable';
    }
  }

  static Future<bool> healthConnectHasPermission() async {
    try {
      return await _ch.invokeMethod<bool>('hcHasPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Prosi o zgodę na zapis snu; przy 'update' otwiera Sklep Play. true = zgoda jest.
  static Future<bool> healthConnectRequestPermission() async {
    try {
      return await _ch.invokeMethod<bool>('hcRequestPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Zapisuje noce jako sesje snu. Każda: id, start, end (ms), title, notes,
  /// stages: [{start, end, stage: wake|light|deep|rem}]. Zwraca liczbę zapisanych lub -1.
  static Future<int> healthConnectWriteSleep(List<Map<String, Object?>> nights) async {
    try {
      return await _ch.invokeMethod<int>('hcWriteSleep', {'nights': nights}) ?? -1;
    } catch (_) {
      return -1;
    }
  }

  static Future<void> _safe(Future<dynamic> Function() f) async {
    try {
      await f();
    } catch (_) {
      // Funkcje natywne są pomocnicze — brak ich nie może wywrócić nocy.
    }
  }
}
