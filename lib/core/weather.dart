import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'bus.dart';
import 'db.dart';
import 'models.dart';
import 'settings.dart';

/// Wynik wyszukiwania miejscowości.
class Place {
  final String name;
  final String detail;
  final double lat, lon;
  const Place(this.name, this.detail, this.lat, this.lon);
}

/// Pogoda dla nocy z Open-Meteo (bez klucza API). Wysyłane są tylko współrzędne
/// wybranej miejscowości i daty — żadne dane o śnie.
class WeatherService {
  static bool _busy = false;

  static Future<dynamic> _getJson(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 25));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }

  static Future<List<Place>> search(String query) async {
    final q = Uri.encodeQueryComponent(query.trim());
    final j = await _getJson('https://geocoding-api.open-meteo.com/v1/search?name=$q&count=8&language=pl&format=json');
    final res = (j is Map ? j['results'] as List? : null) ?? const [];
    return [
      for (final r in res.cast<Map>())
        Place(
          r['name'] as String? ?? '?',
          [r['admin1'], r['country']].whereType<String>().join(', '),
          (r['latitude'] as num).toDouble(),
          (r['longitude'] as num).toDouble(),
        )
    ];
  }

  static String _d(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  static const _vars = 'temperature_2m,relative_humidity_2m,surface_pressure,wind_speed_10m,precipitation,cloud_cover';

  /// Godzinowe dane dla zakresu dat (czas lokalny miejsca).
  static Future<Map<String, List<double?>>?> _hourly(double lat, double lon, DateTime from, DateTime to) async {
    final params = 'latitude=${lat.toStringAsFixed(3)}&longitude=${lon.toStringAsFixed(3)}'
        '&hourly=$_vars&start_date=${_d(from)}&end_date=${_d(to)}&timezone=auto';
    for (final base in [
      'https://historical-forecast-api.open-meteo.com/v1/forecast',
      'https://api.open-meteo.com/v1/forecast',
      'https://archive-api.open-meteo.com/v1/archive',
    ]) {
      try {
        final j = await _getJson('$base?$params');
        final h = j['hourly'] as Map?;
        if (h == null) continue;
        final out = <String, List<double?>>{};
        for (final k in _vars.split(',')) {
          out[k] = ((h[k] as List?) ?? const []).map((v) => (v as num?)?.toDouble()).toList();
        }
        final times = (h['time'] as List).cast<String>();
        _times = times.map(DateTime.parse).toList();
        // Dane bez wartości w końcówce (np. ostatnia noc w archiwum) — próbujemy kolejnego źródła.
        final temps = out['temperature_2m']!;
        if (temps.isEmpty || temps.where((v) => v != null).length < temps.length * 0.6) continue;
        return out;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  static List<DateTime> _times = const [];

  /// Pobiera pogodę dla jednej nocy i zapisuje ją. true = sukces.
  static Future<bool> fetchFor(Night n) async {
    final s = Settings.instance;
    n.moonPhase ??= moonPhase(n.start.add(Duration(minutes: max(0, n.inBedMin) ~/ 2)));
    if (!s.weatherReady || n.end == null) {
      await Db.instance.updateNight(n);
      return false;
    }
    final from = n.start.subtract(const Duration(days: 1));
    final h = await _hourly(s.weatherLat!, s.weatherLon!, from, n.end!);
    if (h == null) return false;
    final times = _times;

    List<double> inNight(String k) {
      final v = h[k]!;
      final out = <double>[];
      for (var i = 0; i < times.length && i < v.length; i++) {
        final t = times[i];
        if (!t.isBefore(DateTime(n.start.year, n.start.month, n.start.day, n.start.hour)) &&
            !t.isAfter(n.end!) &&
            v[i] != null) {
          out.add(v[i]!);
        }
      }
      return out;
    }

    double? at(String k, DateTime when) {
      final v = h[k]!;
      var best = -1;
      var bestDiff = 1 << 30;
      for (var i = 0; i < times.length && i < v.length; i++) {
        final d = times[i].difference(when).inMinutes.abs();
        if (v[i] != null && d < bestDiff) {
          best = i;
          bestDiff = d;
        }
      }
      return best >= 0 && bestDiff <= 90 ? v[best] : null;
    }

    double? mean(List<double> x) => x.isEmpty ? null : x.reduce((a, b) => a + b) / x.length;

    final temp = inNight('temperature_2m');
    if (temp.isEmpty) return false;
    n.wTemp = mean(temp);
    n.wHum = mean(inNight('relative_humidity_2m'));
    final press = inNight('surface_pressure');
    n.wPress = mean(press);
    final pNow = at('surface_pressure', n.start);
    final pBefore = at('surface_pressure', n.start.subtract(const Duration(hours: 24)));
    n.wPressTrend = pNow != null && pBefore != null ? pNow - pBefore : null;
    final wind = inNight('wind_speed_10m');
    n.wWind = wind.isEmpty ? null : wind.reduce(max);
    final rain = inNight('precipitation');
    n.wRain = rain.isEmpty ? null : rain.reduce((a, b) => a + b);
    n.wCloud = mean(inNight('cloud_cover'));
    await Db.instance.updateNight(n);
    return true;
  }

  /// Uzupełnia pogodę dla nocy, które jej nie mają (najnowsze najpierw). Zwraca liczbę uzupełnionych.
  static Future<int> backfill({int limit = 40}) async {
    if (_busy) return 0;
    _busy = true;
    var ok = 0;
    var touched = 0;
    try {
      final nights = await Db.instance.nights();
      for (final n in nights) {
        final needWeather = Settings.instance.weatherReady && n.wTemp == null;
        if (!needWeather && n.moonPhase != null) continue;
        if (ok >= limit) break;
        touched++;
        if (await fetchFor(n)) ok++;
      }
      if (touched > 0) dataChanged();
    } catch (_) {
      // brak internetu — spróbujemy następnym razem
    } finally {
      _busy = false;
    }
    return ok;
  }

  /// Faza Księżyca 0..1 (0 = nów, 0,5 = pełnia), dokładność ok. ±0,5 dnia.
  static double moonPhase(DateTime t) {
    final jd = t.toUtc().millisecondsSinceEpoch / 86400000.0 + 2440587.5;
    const synodic = 29.530588853;
    final p = ((jd - 2451550.1) / synodic) % 1.0;
    return p < 0 ? p + 1 : p;
  }

  /// Oświetlenie tarczy 0..1.
  static double illumination(double phase) => (1 - cos(2 * pi * phase)) / 2;

  static String moonEmoji(double phase) {
    const e = ['🌑', '🌒', '🌓', '🌔', '🌕', '🌖', '🌗', '🌘'];
    return e[((phase * 8) + 0.5).floor() % 8];
  }

  static String moonName(double phase) {
    final i = ((phase * 8) + 0.5).floor() % 8;
    return const ['nów', 'przybywa (sierp)', 'pierwsza kwadra', 'przybywa (garb)', 'pełnia', 'ubywa (garb)',
        'ostatnia kwadra', 'ubywa (sierp)'][i];
  }
}
