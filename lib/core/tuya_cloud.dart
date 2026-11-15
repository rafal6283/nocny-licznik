import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'bus.dart';
import 'db.dart';
import 'models.dart';
import 'room_sensor.dart';
import 'settings.dart';

class TuyaDevice {
  final String id, name, category, product;
  final bool online;
  const TuyaDevice(this.id, this.name, this.category, this.product, this.online);
}

class TuyaError implements Exception {
  final String msg;
  TuyaError(this.msg);
  @override
  String toString() => msg;
}

/// Czujniki ze Smart Life przez chmurę Tuya (Tuya IoT Platform, projekt chmurowy z połączonym kontem aplikacji).
/// Podpis: HMAC-SHA256(client_id [+ access_token] + t + nonce + stringToSign).
class TuyaCloud {
  static const _sec = FlutterSecureStorage();
  static const regions = <(String, String)>[
    ('https://openapi.tuyaeu.com', 'Europa Środkowa'),
    ('https://openapi-weaz.tuyaeu.com', 'Europa Zachodnia'),
    ('https://openapi.tuyaus.com', 'Ameryka Zachodnia'),
    ('https://openapi-ueaz.tuyaus.com', 'Ameryka Wschodnia'),
    ('https://openapi.tuyacn.com', 'Chiny'),
    ('https://openapi.tuyain.com', 'Indie'),
  ];

  static const tempCodes = ['va_temperature', 'temp_current', 'temp_indoor', 'temperature', 'temp_value', 'cur_temp'];
  static const humCodes = ['va_humidity', 'humidity_value', 'humidity_indoor', 'humidity', 'cur_humidity', 'humidity_current'];

  static String? _token;
  static DateTime _tokenExp = DateTime(2000);
  static final Map<String, Map<String, int>> _scales = {}; // urządzenie → kod → skala (10^n)

  static Future<String> accessId() async => await _sec.read(key: 'tuya_id') ?? '';
  static Future<String> secret() async => await _sec.read(key: 'tuya_secret') ?? '';
  static Future<void> setCredentials(String id, String secret) async {
    await _sec.write(key: 'tuya_id', value: id.trim());
    await _sec.write(key: 'tuya_secret', value: secret.trim());
    _token = null;
  }

  static String _sha256(String s) => sha256.convert(utf8.encode(s)).toString();

  static String _sign(String clientId, String secret, String token, String t, String method, String pathQuery, String body) {
    final stringToSign = '$method\n${_sha256(body)}\n\n$pathQuery';
    final str = '$clientId$token$t$stringToSign';
    return Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(str)).toString().toUpperCase();
  }

  /// Ścieżka z posortowanymi parametrami (wymóg podpisu).
  static String _pq(String path, Map<String, String> q) {
    if (q.isEmpty) return path;
    final keys = q.keys.toList()..sort();
    return '$path?${keys.map((k) => '$k=${q[k]}').join('&')}';
  }

  static Future<Map<String, dynamic>> _get(String path, {Map<String, String> q = const {}, bool auth = true}) async {
    final id = await accessId(), sec = await secret();
    if (id.isEmpty || sec.isEmpty) throw TuyaError('Brak Access ID / Access Secret');
    final token = auth ? await _ensureToken() : '';
    final pq = _pq(path, q);
    final t = '${DateTime.now().millisecondsSinceEpoch}';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse('${Settings.instance.tuyaHost}$pq'));
      req.headers
        ..set('client_id', id)
        ..set('t', t)
        ..set('sign_method', 'HMAC-SHA256')
        ..set('sign', _sign(id, sec, token, t, 'GET', pq, ''));
      if (auth) req.headers.set('access_token', token);
      final res = await req.close().timeout(const Duration(seconds: 15));
      final body = await res.transform(utf8.decoder).join();
      final m = jsonDecode(body) as Map<String, dynamic>;
      if (m['success'] != true) {
        final code = m['code'];
        if (auth && (code == 1010 || code == 1011)) _token = null; // token wygasł
        throw TuyaError(_explain(code, m['msg']?.toString() ?? body));
      }
      return m;
    } on SocketException catch (e) {
      throw TuyaError('Brak połączenia z chmurą Tuya (${e.message})');
    } finally {
      client.close(force: true);
    }
  }

  static String _explain(Object? code, String msg) => switch (code) {
        1004 => 'Zły podpis — sprawdź Access Secret',
        1005 || 2009 => 'Zły Access ID albo inny region (centrum danych) projektu',
        1106 => 'Brak uprawnień — połącz konto Smart Life z projektem (Devices → Link App Account)',
        28841002 || 28841101 => 'Wygasł okres próbny „IoT Core” — przedłuż go w projekcie Tuya (Service API)',
        _ => 'Tuya: $msg${code == null ? '' : ' ($code)'}',
      };

  static Future<String> _ensureToken() async {
    if (_token != null && DateTime.now().isBefore(_tokenExp)) return _token!;
    final m = await _get('/v1.0/token', q: {'grant_type': '1'}, auth: false);
    final r = m['result'] as Map<String, dynamic>;
    _token = r['access_token'] as String;
    _tokenExp = DateTime.now().add(Duration(seconds: max(60, ((r['expire_time'] as num?)?.toInt() ?? 7200) - 120)));
    return _token!;
  }

  /// Urządzenia z kont Smart Life połączonych z projektem.
  static Future<List<TuyaDevice>> devices() async {
    final out = <TuyaDevice>[];
    TuyaDevice dev(Map<String, dynamic> d) => TuyaDevice(
          '${d['id']}',
          '${d['name'] ?? d['id']}',
          '${d['category'] ?? ''}',
          '${d['product_name'] ?? ''}',
          d['online'] == true || d['is_online'] == true,
        );
    try {
      String? lastRow;
      for (var page = 0; page < 10; page++) {
        final m = await _get('/v1.0/iot-01/associated-users/devices',
            q: {'size': '50', if (lastRow != null && lastRow.isNotEmpty) 'last_row_key': lastRow});
        final r = m['result'] as Map<String, dynamic>;
        for (final d in (r['devices'] as List? ?? const [])) {
          out.add(dev(d as Map<String, dynamic>));
        }
        if (r['has_more'] != true) break;
        lastRow = r['last_row_key']?.toString();
      }
      return out;
    } on TuyaError catch (e) {
      if (e.msg.contains('podpis') || e.msg.contains('Access ID')) rethrow;
    }
    final m = await _get('/v2.0/cloud/thing/device', q: {'page_size': '20'});
    for (final d in (m['result'] as List? ?? const [])) {
      out.add(dev(d as Map<String, dynamic>));
    }
    return out;
  }

  static Future<Map<String, int>> _scale(String id) async {
    final c = _scales[id];
    if (c != null) return c;
    final out = <String, int>{};
    try {
      final m = await _get('/v1.0/devices/$id/specifications');
      for (final st in ((m['result'] as Map<String, dynamic>)['status'] as List? ?? const [])) {
        final code = st['code']?.toString() ?? '';
        try {
          final v = jsonDecode(st['values']?.toString() ?? '{}') as Map<String, dynamic>;
          out[code] = (v['scale'] as num?)?.toInt() ?? 0;
        } catch (_) {}
      }
    } catch (_) {}
    return _scales[id] = out;
  }

  static double? _val(String code, Object? raw, Map<String, int> sc) {
    if (raw is! num) return null;
    final s = sc[code];
    if (s != null) return raw / pow(10, s);
    // brak specyfikacji: temperatury Tuya zwykle ×10
    if (tempCodes.contains(code) && raw.abs() > 60) return raw / 10;
    if (humCodes.contains(code) && raw > 100) return raw / 10;
    return raw.toDouble();
  }

  /// Bieżący odczyt czujnika.
  static Future<RoomReading?> read(String id) async {
    final sc = await _scale(id);
    final m = await _get('/v1.0/devices/$id/status');
    double? t, h;
    for (final st in (m['result'] as List? ?? const [])) {
      final code = st['code']?.toString() ?? '';
      if (t == null && tempCodes.contains(code)) t = _val(code, st['value'], sc);
      if (h == null && humCodes.contains(code)) h = _val(code, st['value'], sc);
    }
    if (t == null && h == null) return null;
    return RoomReading(t ?? double.nan, h ?? double.nan, DateTime.now());
  }

  /// Historia raportów czujnika z przedziału (czas, temperatura?, wilgotność?).
  static Future<List<(DateTime, double?, double?)>> history(String id, DateTime from, DateTime to) async {
    final sc = await _scale(id);
    final out = <(DateTime, double?, double?)>[];
    void add(Object? code, Object? value, Object? time) {
      final c = code?.toString() ?? '';
      final ts = time is num ? time.toInt() : int.tryParse('$time');
      if (ts == null) return;
      final v = _val(c, value is String ? num.tryParse(value) : value, sc);
      if (v == null) return;
      final at = DateTime.fromMillisecondsSinceEpoch(ts < 1e12 ? ts * 1000 : ts);
      if (tempCodes.contains(c)) out.add((at, v, null));
      if (humCodes.contains(c)) out.add((at, null, v));
    }

    try {
      String? next;
      for (var page = 0; page < 20; page++) {
        final m = await _get('/v1.0/devices/$id/logs', q: {
          'type': '7',
          'start_time': '${from.millisecondsSinceEpoch}',
          'end_time': '${to.millisecondsSinceEpoch}',
          'size': '100',
          if (next != null && next.isNotEmpty) 'start_row_key': next,
        });
        final r = m['result'] as Map<String, dynamic>;
        for (final l in (r['logs'] as List? ?? const [])) {
          add(l['code'], l['value'], l['event_time']);
        }
        if (r['has_next'] != true) break;
        next = r['next_row_key']?.toString();
      }
    } on TuyaError {
      // starsze/nowsze projekty: dzienniki w API v2
      final m = await _get('/v2.0/cloud/thing/$id/report-logs', q: {
        'codes': [...tempCodes, ...humCodes].join(','),
        'start_time': '${from.millisecondsSinceEpoch}',
        'end_time': '${to.millisecondsSinceEpoch}',
        'size': '100',
      });
      final r = m['result'] as Map<String, dynamic>;
      for (final l in (r['logs'] as List? ?? const [])) {
        add(l['code'], l['value'], l['event_time']);
      }
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  /// Po nocy: uzupełnia minuty z historii czujnika (czujniki na baterie raportują rzadko —
  /// ostatnia znana wartość obowiązuje do następnego raportu).
  static Future<void> applyToNight(Night n) async {
    final s = Settings.instance;
    if (n.id == null || n.end == null || s.roomSource != 'tuya' || s.tuyaDevice.isEmpty || !s.roomSensorOn) return;
    final hist = await history(s.tuyaDevice, n.start.subtract(const Duration(hours: 6)), n.end!);
    if (hist.isEmpty) return;
    final ms = await Db.instance.minutes(n.id!);
    double? t, h;
    var j = 0;
    final upd = <int, (double?, double?)>{};
    final ts = <double>[], hs = <double>[];
    for (var i = 0; i < ms.length; i++) {
      final mid = ms[i].ts.subtract(const Duration(seconds: 30));
      while (j < hist.length && !hist[j].$1.isAfter(mid)) {
        t = hist[j].$2 ?? t;
        h = hist[j].$3 ?? h;
        j++;
      }
      if (t == null && h == null) continue;
      upd[i] = (t, h);
      if (t != null) ts.add(t);
      if (h != null) hs.add(h);
    }
    if (upd.isEmpty) return;
    await Db.instance.setMinuteRoom(n.id!, upd);
    if (ts.isNotEmpty) n.roomTemp = ts.reduce((a, b) => a + b) / ts.length;
    if (hs.isNotEmpty) n.roomHum = hs.reduce((a, b) => a + b) / hs.length;
    await Db.instance.updateNight(n);
    dataChanged();
  }
}
