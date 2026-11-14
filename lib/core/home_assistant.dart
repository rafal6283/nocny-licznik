import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'settings.dart';

/// Światła przez Home Assistant (REST API, token długoterminowy):
/// ściemnienie przy „Dobranoc” i świt przed budzikiem (jasność rośnie co minutę, z ciepłej barwy do neutralnej).
class HomeAssistant {
  static const _sec = FlutterSecureStorage();
  static const _tokenKey = 'ha_token';
  static Timer? _dimTimer;

  static Future<String> token() async => await _sec.read(key: _tokenKey) ?? '';
  static Future<void> setToken(String t) => _sec.write(key: _tokenKey, value: t.trim());

  static List<String> get lights =>
      Settings.instance.haLights.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  static bool get configured {
    final s = Settings.instance;
    return s.haOn && s.haUrl.trim().isNotEmpty && lights.isNotEmpty;
  }

  /// Wywołanie usługi HA; zwraca null przy sukcesie albo opis błędu.
  static Future<String?> call(String domain, String service, Map<String, Object?> data) async {
    final base = Settings.instance.haUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final tok = await token();
    if (base.isEmpty || tok.isEmpty) return 'Brak adresu lub tokenu Home Assistant';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.postUrl(Uri.parse('$base/api/services/$domain/$service'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $tok');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(data));
      final res = await req.close().timeout(const Duration(seconds: 10));
      await res.drain<void>();
      if (res.statusCode >= 200 && res.statusCode < 300) return null;
      return 'Home Assistant: HTTP ${res.statusCode}${res.statusCode == 401 ? ' (zły token)' : ''}';
    } catch (e) {
      return 'Home Assistant: $e';
    } finally {
      client.close(force: true);
    }
  }

  static Future<String?> setLights({required int brightnessPct, int? kelvin, int transitionSec = 2}) {
    if (brightnessPct <= 0) return call('light', 'turn_off', {'entity_id': lights, 'transition': transitionSec});
    return call('light', 'turn_on', {
      'entity_id': lights,
      'brightness_pct': brightnessPct.clamp(1, 100),
      if (kelvin != null) 'color_temp_kelvin': kelvin,
      'transition': transitionSec,
    });
  }

  /// „Dobranoc”: ciepłe, przygaszone światło, po 3 minutach powoli gaśnie.
  static Future<String?> eveningDim() async {
    if (!configured || !Settings.instance.haDimAtStart) return null;
    final r = await setLights(brightnessPct: 8, kelvin: 2200, transitionSec: 20);
    _dimTimer?.cancel();
    _dimTimer = Timer(const Duration(minutes: 3), () => setLights(brightnessPct: 0, transitionSec: 60));
    return r;
  }

  static int _lastSunrisePct = -1;

  /// Wołane co minutę w nocy z godziną budzika: w ostatnich N minutach przed budzikiem rozjaśnia.
  static Future<void> sunriseTick(DateTime? alarmAt) async {
    if (!configured || alarmAt == null) return;
    final n = Settings.instance.haSunriseMin;
    if (n <= 0) return;
    final left = alarmAt.difference(DateTime.now()).inSeconds / 60.0;
    if (left > n || left < -5) return;
    final p = (1 - max(0.0, left) / n).clamp(0.0, 1.0);
    // krzywa wolno startuje (oko czuje logarytmicznie)
    final pct = max(1, (100 * p * p).round());
    if (pct == _lastSunrisePct) return;
    _lastSunrisePct = pct;
    final kelvin = (2000 + 2500 * p).round();
    await setLights(brightnessPct: pct, kelvin: kelvin, transitionSec: 55);
  }

  static void resetNight() {
    _lastSunrisePct = -1;
    _dimTimer?.cancel();
  }

  /// Test z ustawień: krótko rozjaśnia i przygasza.
  static Future<String?> test() async {
    final a = await setLights(brightnessPct: 60, kelvin: 3000, transitionSec: 1);
    if (a != null) return a;
    await Future<void>.delayed(const Duration(seconds: 2));
    return setLights(brightnessPct: 10, kelvin: 2200, transitionSec: 1);
  }
}
