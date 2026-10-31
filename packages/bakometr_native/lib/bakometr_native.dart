import 'dart:io';

import 'package:flutter/services.dart';

/// Cienka warstwa nad natywnym kodem Androida (Java) i iOS (Swift).
class BakometrNative {
  static const MethodChannel _ch = MethodChannel('bakometr_native');

  /// Android: usługa pierwszoplanowa z mikrofonem + blokada uśpienia CPU.
  /// iOS: nic (działanie w tle zapewnia aktywne nagrywanie + tryb audio w tle).
  /// Zwraca null, gdy usługa wystartowała, albo opis błędu.
  static Future<String?> startTracking({required String title, required String text}) async {
    try {
      return await _ch.invokeMethod<String>('startTracking', {'title': title, 'text': text});
    } catch (e) {
      return 'startTracking: $e';
    }
  }

  /// Powody zakończenia procesu (Android 11+): [{ts, reason, description, importance, status, pss}].
  static Future<List<Map<String, dynamic>>> exitReasons() async {
    try {
      final r = await _ch.invokeMethod<List<dynamic>>('exitReasons');
      return [for (final e in r ?? const []) Map<String, dynamic>.from(e as Map)];
    } catch (_) {
      return const [];
    }
  }

  /// true = system ogranicza aplikację w tle (optymalizacja baterii włączona).
  static Future<bool?> batteryOptimized() async {
    try {
      return await _ch.invokeMethod<bool>('batteryOptimized');
    } catch (_) {
      return null;
    }
  }

  static Future<void> requestIgnoreBatteryOptimizations() =>
      _safe(() => _ch.invokeMethod('requestIgnoreBatteryOptimizations'));

  static Future<void> openAppSettings() => _safe(() => _ch.invokeMethod('openAppSettings'));

  static Future<Map<String, dynamic>> deviceInfo() async {
    try {
      final r = await _ch.invokeMethod<Map<dynamic, dynamic>>('deviceInfo');
      return Map<String, dynamic>.from(r ?? const {});
    } catch (_) {
      return const {};
    }
  }

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

  /// Zgoda na odczyt danych z zegarka (tętno, SpO₂, sen). true = jest.
  static Future<bool> healthConnectHasReadPermission() async {
    try {
      return await _ch.invokeMethod<bool>('hcHasReadPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> healthConnectRequestReadPermission() async {
    try {
      return await _ch.invokeMethod<bool>('hcRequestReadPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Dane innych aplikacji (zegarka) z przedziału nocy:
  /// {hr: [[ms, bpm]], spo2: [[ms, %]], stages: [[start, end, stage]], sources: [pakiety]} albo null.
  static Future<Map<String, Object?>?> healthConnectReadNight(int startMs, int endMs) async {
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('hcReadNight', {'start': startMs, 'end': endMs});
      return r?.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
    }
  }

  /// Android: wybór karty SD aparatu ResMed; kopiuje STR.edf i *_EVE/*_PLD.edf z dni [from, to]
  /// (RRRRMMDD) do pamięci podręcznej. Zwraca ścieżki albo null (anulowano).
  /// Włączenia ekranu (1), wyłączenia (0) i odblokowania (2) od [since] — tylko Android, w czasie nocy.
  static Future<List<(DateTime, int)>> screenEvents(DateTime since) async {
    if (!Platform.isAndroid) return const [];
    try {
      final r = await _ch.invokeMethod<List<dynamic>>('screenEvents', {'since': since.millisecondsSinceEpoch});
      return [
        for (final e in r ?? const [])
          if (e is List && e.length >= 2)
            (DateTime.fromMillisecondsSinceEpoch((e[0] as num).toInt()), (e[1] as num).toInt())
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<List<String>?> pickCpapCard({required String from, required String to}) async {
    final r = await _ch.invokeMethod<List<dynamic>>('pickCpapCard', {'from': from, 'to': to});
    return r?.map((e) => e.toString()).toList();
  }

  static Future<void> _safe(Future<dynamic> Function() f) async {
    try {
      await f();
    } catch (_) {
      // Funkcje natywne są pomocnicze — brak ich nie może wywrócić nocy.
    }
  }
}
