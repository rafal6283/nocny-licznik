import 'dart:math';

import 'accel_breath.dart';

/// Dane z opaski z jednej minuty – do faz snu i wykresów.
class StrapMinute {
  final double? hr; // średnie tętno
  final double? rmssd; // HRV: RMSSD odstępów RR [ms]
  final int? activeSec; // sekundy z ruchem tułowia (akcelerometr opaski)
  final double? breathRate; // oddechy/min z ruchu klatki
  final double? breathVar; // zmienność odstępów między oddechami (CV)
  final bool posChange; // zmiana pozycji ciała (obrót o ≥ 30°)
  final List<double>? gravity; // średni kierunek grawitacji w minucie (pozycja ciała)
  const StrapMinute({this.hr, this.rmssd, this.activeSec, this.breathRate, this.breathVar, this.posChange = false, this.gravity});
}

/// Zbiera dane opaski na bieżąco i co minutę oddaje [StrapMinute].
/// Tętno i RR – standardowa usługa Heart Rate (każdy pulsometr BLE); ruch, oddech i pozycja –
/// akcelerometr Polar H10 (25 Hz, mG), gdy dostępny.
class StrapMinuteProcessor {
  /// Ruch tułowia: ~0,35 m/s² w 200 ms (oddech poruszający klatką daje ~0,03).
  final _acc = AccelProcessor(thr: 0.35);
  static const _g = 0.00980665; // mG → m/s²

  final _bpm = <int>[];
  final _rr = <double>[];
  bool _accThisMinute = false;

  // ramki 5 Hz na osiach – do oddechu (ostatnie 90 s)
  final _ax = <double>[], _ay = <double>[], _az = <double>[];
  double _sx = 0, _sy = 0, _sz = 0;
  int _fn = 0, _fStart = 0, _frames = 0;

  // grawitacja (pozycja ciała)
  List<double>? _gravStart; // na początku minuty
  final _g10 = <List<double>>[]; // średnie 10 s z ostatniej minuty

  void addHr(int bpm, List<double> rrMs) {
    if (bpm > 25 && bpm < 230) _bpm.add(bpm);
    _rr.addAll(rrMs.where((r) => r >= 280 && r <= 3000));
  }

  /// [xyzMg] – przeplatane próbki x,y,z; [nowMs] – chwila odebrania (czas ostatniej próbki).
  void addAcc(List<int> xyzMg, int nowMs, {int periodMs = 40}) {
    final n = xyzMg.length ~/ 3;
    if (n == 0) return;
    _accThisMinute = true;
    for (var i = 0; i < n; i++) {
      final t = nowMs - (n - 1 - i) * periodMs;
      final x = xyzMg[3 * i] * _g, y = xyzMg[3 * i + 1] * _g, z = xyzMg[3 * i + 2] * _g;
      _acc.add(x, y, z, t);
      if (_fStart == 0) _fStart = t;
      _sx += x;
      _sy += y;
      _sz += z;
      _fn++;
      if (t - _fStart >= 200) {
        _ax.add(_sx / _fn);
        _ay.add(_sy / _fn);
        _az.add(_sz / _fn);
        if (_ax.length > 450) {
          _ax.removeAt(0);
          _ay.removeAt(0);
          _az.removeAt(0);
        }
        if (++_frames % 50 == 0) _g10.add([_ax.last, _ay.last, _az.last]);
        _sx = _sy = _sz = 0;
        _fn = 0;
        _fStart = t;
      }
    }
  }

  static double? rmssd(List<double> rr) {
    final d = <double>[];
    for (var i = 1; i < rr.length; i++) {
      final a = rr[i - 1], b = rr[i];
      if ((b - a).abs() <= 0.2 * a) d.add(b - a); // pobudzenia dodatkowe i artefakty poza
    }
    if (d.length < 20) return null;
    return sqrt(d.map((x) => x * x).reduce((a, b) => a + b) / d.length);
  }

  static double _angle(List<double> a, List<double> b) {
    final na = sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
    final nb = sqrt(b[0] * b[0] + b[1] * b[1] + b[2] * b[2]);
    if (na < 1e-6 || nb < 1e-6) return 0;
    final c = ((a[0] * b[0] + a[1] * b[1] + a[2] * b[2]) / (na * nb)).clamp(-1.0, 1.0);
    return acos(c) * 180 / pi;
  }

  /// Oddech z osi, na której ruch klatki jest najsilniejszy.
  (double, double)? _breath() {
    if (_ax.length < 300) return null;
    double varHp(List<double> v) {
      final m = v.reduce((a, b) => a + b) / v.length;
      return v.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b);
    }

    final axes = [_ax, _ay, _az];
    axes.sort((a, b) => varHp(b).compareTo(varHp(a)));
    // oś z największą zmiennością to często ruch ciała – sprawdzamy dwie najsilniejsze
    for (final v in axes.take(2)) {
      final r = AccelProcessor.analyzeBreath(List<double>.from(v));
      if (r != null && r.$1 >= 6 && r.$1 <= 35) return r;
    }
    return null;
  }

  /// Dane minuty (i zerowanie); null, gdy opaska nic nie przysłała.
  StrapMinute? take() {
    final hasHr = _bpm.isNotEmpty || _rr.length >= 10;
    // Bez tętna opaska nie jest na ciele (zdjęta, leży obok, sucha elektroda): ruch z jej
    // akcelerometru oznaczałby „bezruch” i fałszywy sen głęboki, więc minutę pomijamy —
    // fazy liczą się wtedy z telefonu/sonaru jak bez opaski.
    if (!hasHr) {
      if (_accThisMinute) _acc.takeActiveSeconds();
      _g10.clear();
      _gravStart = null;
      _accThisMinute = false;
      _bpm.clear();
      _rr.clear();
      return null;
    }
    final act = _accThisMinute ? _acc.takeActiveSeconds() : null;
    double? hr;
    if (_rr.length >= 10) {
      hr = 60000 / (_rr.reduce((a, b) => a + b) / _rr.length);
    } else if (_bpm.isNotEmpty) {
      hr = _bpm.reduce((a, b) => a + b) / _bpm.length;
    }
    final br = (act != null && act <= 3) ? _breath() : null;
    var pos = false;
    List<double>? grav;
    if (_g10.isNotEmpty) {
      grav = [
        for (var k = 0; k < 3; k++) _g10.map((v) => v[k]).reduce((a, b) => a + b) / _g10.length,
      ];
      final first = _gravStart ?? _g10.first;
      pos = _angle(first, _g10.last) >= 30;
      _gravStart = _g10.last;
      _g10.clear();
    }
    final out = StrapMinute(
      hr: hr,
      rmssd: rmssd(_rr),
      activeSec: act,
      breathRate: br?.$1,
      breathVar: br?.$2,
      posChange: pos,
      gravity: grav,
    );
    _bpm.clear();
    _rr.clear();
    _accThisMinute = false;
    return out;
  }
}
