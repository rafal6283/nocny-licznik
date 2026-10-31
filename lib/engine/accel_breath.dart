import 'dart:math';

/// Analiza akcelerometru telefonu leżącego na materacu:
/// • ruch w stylu dotychczasowym (różnice co ~200 ms),
/// • aktygrafia — liczba sekund z ruchem w minucie (odporniejsza niż suma siły ruchu),
/// • oddech — mikroruchy materaca w kierunku grawitacji (0,1–0,6 Hz), tempo i regularność.
class AccelProcessor {
  static const frameMs = 200; // 5 Hz
  static const motionThr = 0.08; // m/s² — jak dotychczas

  // ruch co ~200 ms
  double? _rx, _ry, _rz;
  int _refMs = 0;
  final Set<int> _activeSec = {};

  // grawitacja (wolna średnia) i ramki 5 Hz
  double _gx = 0, _gy = 0, _gz = 0;
  bool _gInit = false;
  int _frameStart = 0;
  double _frameSum = 0;
  int _frameN = 0;
  final List<double> _vert = []; // 5 Hz, ostatnie 90 s

  /// Zwraca różnicę z ostatnią ramką ~200 ms (do sumy ruchu), albo null, gdy jeszcze za wcześnie.
  double? add(double x, double y, double z, int nowMs, {bool count = true}) {
    // grawitacja: EMA ~8 s przy ~50 Hz
    if (!_gInit) {
      _gx = x;
      _gy = y;
      _gz = z;
      _gInit = true;
    } else {
      const a = 0.0025;
      _gx += (x - _gx) * a;
      _gy += (y - _gy) * a;
      _gz += (z - _gz) * a;
    }
    final gn = sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
    final proj = gn > 1e-6 ? (x * _gx + y * _gy + z * _gz) / gn : 0.0;
    if (_frameStart == 0) _frameStart = nowMs;
    _frameSum += proj;
    _frameN++;
    if (nowMs - _frameStart >= frameMs) {
      _vert.add(_frameSum / _frameN);
      if (_vert.length > 450) _vert.removeAt(0);
      _frameSum = 0;
      _frameN = 0;
      _frameStart = nowMs;
    }

    if (_rx == null) {
      _rx = x;
      _ry = y;
      _rz = z;
      _refMs = nowMs;
      return null;
    }
    if (nowMs - _refMs < frameMs - 10) return null;
    final d = sqrt(pow(x - _rx!, 2) + pow(y - _ry!, 2) + pow(z - _rz!, 2));
    _rx = x;
    _ry = y;
    _rz = z;
    _refMs = nowMs;
    if (count && d > motionThr) _activeSec.add(nowMs ~/ 1000);
    return d;
  }

  /// Sekundy z ruchem od ostatniego wywołania (i zerowanie).
  int takeActiveSeconds() {
    final n = _activeSec.length;
    _activeSec.clear();
    return min(60, n);
  }

  /// Oddech z ostatnich ~60–90 s: (oddechy/min, zmienność odstępów CV) albo null,
  /// gdy w danych nie widać wyraźnego, okresowego oddechu (telefon nie na materacu, ruch, szum).
  (double, double)? breath({int minFrames = 300}) {
    if (_vert.length < minFrames) return null;
    return analyzeBreath(List<double>.from(_vert));
  }

  /// Wydzielone do testów: sygnał 5 Hz → tempo i regularność oddechu.
  static (double, double)? analyzeBreath(List<double> v) {
    final n = v.length;
    if (n < 150) return null;
    // górnoprzepustowo: odjęcie średniej ruchomej 10 s
    const w = 25;
    final hp = List<double>.filled(n, 0);
    var acc = 0.0;
    final cs = List<double>.filled(n + 1, 0);
    for (var i = 0; i < n; i++) {
      acc += v[i];
      cs[i + 1] = acc;
    }
    for (var i = 0; i < n; i++) {
      final a = max(0, i - w), b = min(n, i + w + 1);
      hp[i] = v[i] - (cs[b] - cs[a]) / (b - a);
    }
    // wygładzenie 3-punktowe
    final x = [for (var i = 0; i < n; i++) (hp[max(0, i - 1)] + hp[i] + hp[min(n - 1, i + 1)]) / 3];
    // autokorelacja dla okresów 1,6–10 s (6–37 oddechów/min)
    double r(int lag) {
      var s = 0.0, a = 0.0, b = 0.0;
      for (var i = 0; i + lag < n; i++) {
        s += x[i] * x[i + lag];
        a += x[i] * x[i];
        b += x[i + lag] * x[i + lag];
      }
      return (a <= 0 || b <= 0) ? 0 : s / sqrt(a * b);
    }

    var best = 0.0;
    var bestLag = 0;
    for (var lag = 8; lag <= 50; lag++) {
      final c = r(lag);
      // pierwsze lokalne maksimum o wystarczającej sile (unikamy wielokrotności okresu)
      if (c > best) {
        best = c;
        bestLag = lag;
      }
    }
    if (bestLag == 0 || best < 0.35) return null;
    // poprawka: jeśli połowa okresu też daje silny szczyt, to on jest właściwy
    final half = bestLag ~/ 2;
    if (half >= 8 && r(half) > 0.8 * best) bestLag = half;
    final rate = 60 / (bestLag * frameMs / 1000);

    // odstępy między oddechami: przejścia przez zero w górę, min. 0,6 okresu
    // przed szukaniem przejść mocniej wygładzamy (okno ~1/3 okresu), żeby szum nie dawał fałszywych przejść
    final k = max(1, bestLag ~/ 6);
    final y = List<double>.generate(n, (i) {
      final a = max(0, i - k), b = min(n, i + k + 1);
      var s = 0.0;
      for (var j = a; j < b; j++) {
        s += x[j];
      }
      return s / (b - a);
    });
    final minGap = (bestLag * 0.6).round();
    final ups = <int>[];
    for (var i = 1; i < n; i++) {
      if (y[i - 1] < 0 && y[i] >= 0 && (ups.isEmpty || i - ups.last >= minGap)) ups.add(i);
    }
    if (ups.length < 4) return null;
    final gaps = [for (var i = 1; i < ups.length; i++) (ups[i] - ups[i - 1]).toDouble()];
    final m = gaps.reduce((a, b) => a + b) / gaps.length;
    final sd = sqrt(gaps.map((g) => (g - m) * (g - m)).reduce((a, b) => a + b) / gaps.length);
    return (rate, m > 0 ? sd / m : 1.0);
  }
}
