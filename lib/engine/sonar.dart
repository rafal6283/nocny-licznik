import 'dart:math';
import 'dart:typed_data';

/// Filtr dolnoprzepustowy (okno Blackmana) + decymacja 48 kHz → 16 kHz.
/// Usuwa ton sonaru (19 kHz), żeby nie zawyżał pomiaru hałasu i nie mylił YAMNet.
class Decimator3 {
  static const _taps = 63;
  static final Float64List _h = _design();
  final Float64List _buf = Float64List(_taps);
  int _pos = 0;
  int _phase = 0;

  static Float64List _design() {
    const fc = 7000 / 48000; // odcięcie znormalizowane
    final h = Float64List(_taps);
    const m = _taps - 1;
    var sum = 0.0;
    for (var n = 0; n < _taps; n++) {
      final k = n - m / 2;
      final sinc = k == 0 ? 2 * fc : sin(2 * pi * fc * k) / (pi * k);
      final w = 0.42 - 0.5 * cos(2 * pi * n / m) + 0.08 * cos(4 * pi * n / m);
      h[n] = sinc * w;
      sum += h[n];
    }
    for (var n = 0; n < _taps; n++) {
      h[n] /= sum;
    }
    return h;
  }

  /// Podaje próbkę 48 kHz; co trzecią zwraca próbkę 16 kHz (inaczej null).
  double? push(double x) {
    _buf[_pos] = x;
    _pos = (_pos + 1) % _taps;
    _phase = (_phase + 1) % 3;
    if (_phase != 0) return null;
    var acc = 0.0;
    var idx = _pos;
    for (var n = 0; n < _taps; n++) {
      acc += _h[n] * _buf[idx];
      idx++;
      if (idx == _taps) idx = 0;
    }
    return acc;
  }
}

/// Sekundowe podsumowanie sonaru.
class SonarSecond {
  final double amplitude; // amplituda ruchu oddechowego (jednostki względne)
  final double motion; // ruch ciała (względny)
  final bool moving;
  final double quality; // SNR tonu w dB
  const SonarSecond(this.amplitude, this.motion, this.moving, this.quality);
}

/// Zdarzenie oddechowe z sonaru.
class SonarEvent {
  final DateTime start;
  final int seconds;
  final double depth; // 1 - minimalny stosunek amplitudy do linii bazowej
  final bool apnea; // true = przerwa (<30% oddechu), false = spłycenie (30–50%)
  const SonarEvent(this.start, this.seconds, this.depth, this.apnea);
}

/// Sonar ciągłej fali (CW): głośnik nadaje ton f0, mikrofon odbiera echo.
/// Ruch klatki piersiowej zmienia fazę echa → po demodulacji I/Q widać oddech.
/// Podobne podejście (FMCW) stosował ApneaApp (Univ. of Washington, MobiSys 2015).
class SonarProcessor {
  static const fs = 48000;
  static const f0 = 19000; // 19/48 → okres dokładnie 48 próbek
  static const fRef = 17000; // pasmo odniesienia do oceny jakości (bez tonu)
  static const _per = 48;

  static final Float64List _cos0 = Float64List.fromList(List.generate(_per, (i) => cos(2 * pi * f0 * i / fs)));
  static final Float64List _sin0 = Float64List.fromList(List.generate(_per, (i) => sin(2 * pi * f0 * i / fs)));
  static final Float64List _cosR = Float64List.fromList(List.generate(_per, (i) => cos(2 * pi * fRef * i / fs)));
  static final Float64List _sinR = Float64List.fromList(List.generate(_per, (i) => sin(2 * pi * fRef * i / fs)));

  int _n = 0;
  // blok 480 próbek → 100 Hz
  double _bi = 0, _bq = 0, _ri = 0, _rq = 0;
  int _bn = 0;
  // 100 Hz
  double _prevI = 0, _prevQ = 0;
  bool _hasPrev = false;
  double _motAcc = 0, _magAcc = 0, _tonePow = 0, _refPow = 0;
  int _c100 = 0;
  // 10 Hz
  double _ai = 0, _aq = 0;
  int _a10 = 0;
  final List<double> _zi = []; // historia 10 Hz (do 90 s)
  final List<double> _zq = [];

  // sekundy
  final List<double> _ampHist = []; // amplitudy (do 180 s)
  final List<bool> _movHist = [];
  final List<double> _motionHist = [];
  final List<double> _rates = [];
  double quality = -99;
  double? breathRate; // oddechy/min (ostatnie 30 s)
  double? breathVar; // zmienność odstępów między oddechami (CV)
  double lastAmplitude = 0;
  bool moving = false;

  // detektor zdarzeń
  int _lowSec = 0;
  double _minRatio = 1;
  DateTime? _lowStart;

  void Function(SonarSecond s)? onSecond;
  void Function(SonarEvent e)? onEvent;

  /// Ostatnie 30 s przebiegu oddechu (10 Hz) do wykresu.
  List<double> waveform() {
    final n = _zi.length;
    if (n < 50) return const [];
    final from = max(0, n - 300);
    final i = _zi.sublist(from), q = _zq.sublist(from);
    final p = _project(i, q);
    return p;
  }

  void feed(Float32List x) {
    for (var k = 0; k < x.length; k++) {
      final v = x[k];
      final ph = _n % _per;
      _bi += v * _cos0[ph];
      _bq -= v * _sin0[ph];
      _ri += v * _cosR[ph];
      _rq -= v * _sinR[ph];
      _n++;
      if (++_bn == 480) {
        _on100(_bi / 480, _bq / 480, _ri / 480, _rq / 480);
        _bi = _bq = _ri = _rq = 0;
        _bn = 0;
      }
    }
  }

  void _on100(double i, double q, double ri, double rq) {
    _tonePow += i * i + q * q;
    _refPow += ri * ri + rq * rq;
    _magAcc += sqrt(i * i + q * q);
    if (_hasPrev) {
      final di = i - _prevI, dq = q - _prevQ;
      _motAcc += di * di + dq * dq;
    }
    _prevI = i;
    _prevQ = q;
    _hasPrev = true;

    _ai += i;
    _aq += q;
    if (++_a10 == 10) {
      _zi.add(_ai / 10);
      _zq.add(_aq / 10);
      if (_zi.length > 900) {
        _zi.removeRange(0, _zi.length - 900);
        _zq.removeRange(0, _zq.length - 900);
      }
      _ai = _aq = 0;
      _a10 = 0;
    }

    if (++_c100 == 100) {
      _onSecond();
      _c100 = 0;
      _motAcc = _magAcc = _tonePow = _refPow = 0;
    }
  }

  void _onSecond() {
    quality = 10 * log((_tonePow + 1e-20) / (_refPow + 1e-20)) / ln10;
    final mag = _magAcc / 100 + 1e-12;
    final motion = _motAcc / (mag * mag); // względny ruch (niezależny od głośności tonu)
    _motionHist.add(motion);
    if (_motionHist.length > 300) _motionHist.removeAt(0);
    final med = _median(_motionHist);
    moving = _motionHist.length > 20 && motion > max(med * 8, 1e-6);

    // Amplituda oddechu: długość drogi echa na płaszczyźnie I/Q w oknie 6 s (względem siły tonu).
    // Rośnie liniowo z wychyleniem klatki piersiowej, także przy dużych zmianach fazy.
    double amp = 0;
    final n = _zi.length;
    if (n >= 61) {
      var path = 0.0;
      for (var k = n - 60; k < n; k++) {
        final di = _zi[k] - _zi[k - 1], dq = _zq[k] - _zq[k - 1];
        path += sqrt(di * di + dq * dq);
      }
      amp = path / mag;
    }
    lastAmplitude = amp;
    _ampHist.add(amp);
    _movHist.add(moving);
    if (_ampHist.length > 180) {
      _ampHist.removeAt(0);
      _movHist.removeAt(0);
    }

    if (_n % (fs * 5) < fs) {
      // przy wyraźnie słabszym ruchu (przerwa/spłycenie) estymacja częstości byłaby szumem
      final typical = _ampHist.length > 30 ? _median(_ampHist) : 0.0;
      if (typical == 0 || amp >= 0.5 * typical) {
        _estimateRate();
      } else {
        breathRate = null;
      }
    }

    onSecond?.call(SonarSecond(amp, motion, moving, quality));
    _detect(amp);
  }

  /// Częstość oddechu z rzutu I/Q na główną składową (ostatnie 30 s).
  void _estimateRate() {
    final n = _zi.length;
    if (n < 300) return;
    final p = _project(_zi.sublist(n - 300), _zq.sublist(n - 300));
    // wygładzenie 0,5 s
    final s = List<double>.generate(p.length, (k) {
      var a = 0.0, c = 0;
      for (var j = max(0, k - 2); j <= min(p.length - 1, k + 2); j++) {
        a += p[j];
        c++;
      }
      return a / c;
    });
    final sd = sqrt(s.map((v) => v * v).reduce((a, b) => a + b) / s.length);
    if (sd <= 0) return;
    final th = 0.3 * sd;
    var state = 0;
    final ups = <int>[];
    for (var k = 0; k < s.length; k++) {
      if (state <= 0 && s[k] > th) {
        state = 1;
        ups.add(k);
      } else if (state >= 0 && s[k] < -th) {
        state = -1;
      }
    }
    if (ups.length < 3) {
      breathRate = null;
      return;
    }
    final intervals = [for (var k = 1; k < ups.length; k++) (ups[k] - ups[k - 1]) / 10.0];
    final mean = intervals.reduce((a, b) => a + b) / intervals.length;
    final rate = 60 / mean;
    if (rate < 4 || rate > 40) {
      breathRate = null;
      return;
    }
    breathRate = rate;
    final varr = intervals.map((d) => (d - mean) * (d - mean)).reduce((a, b) => a + b) / intervals.length;
    breathVar = sqrt(varr) / mean;
    _rates.add(rate);
    if (_rates.length > 20) _rates.removeAt(0);
  }

  void _detect(double amp) {
    if (_ampHist.length < 90) return;
    // linia bazowa: mediana amplitudy z poprzednich 2 min, bez sekund z ruchem
    final base = <double>[];
    for (var k = 0; k < _ampHist.length - 1; k++) {
      if (!_movHist[k]) base.add(_ampHist[k]);
    }
    if (base.length < 60) return;
    final b = _median(base);
    if (b < 1e-4 || quality < 6) return; // za słaby sygnał
    final ratio = amp / b;

    if (moving) {
      // Koniec przerwy często łączy się z wybudzeniem i ruchem — wtedy też zamykamy zdarzenie.
      _finish(_lowSec);
      return;
    }
    if (ratio < 0.6) {
      if (_lowSec == 0) _lowStart = DateTime.now();
      _lowSec++;
      _minRatio = min(_minRatio, ratio);
      if (_lowSec > 120) {
        // zbyt długo — raczej zmiana pozycji/odejście od łóżka, nie bezdech
        _lowSec = 0;
        _minRatio = 1;
        _lowStart = null;
      }
    } else if (ratio >= 0.75 && _lowSec > 0) {
      _finish(_lowSec);
    }
  }

  /// Przerwa: spadek ≥70% (stosunek <0,3); spłycenie: spadek ≥50%; oba ≥10 s.
  void _finish(int dur) {
    if (dur >= 10 && _lowStart != null && _minRatio < 0.5) {
      onEvent?.call(SonarEvent(_lowStart!.subtract(const Duration(seconds: 2)), dur, 1 - _minRatio, _minRatio < 0.3));
    }
    _lowSec = 0;
    _minRatio = 1;
    _lowStart = null;
  }

  /// Średnia częstość z ostatnich pomiarów (do zapisu minuty).
  double? minuteRate() {
    if (_rates.isEmpty) return null;
    final r = _median(_rates.length > 12 ? _rates.sublist(_rates.length - 12) : _rates);
    return r;
  }

  void clearMinute() => _rates.clear();

  static List<double> _project(List<double> i, List<double> q) {
    final n = i.length;
    var mi = 0.0, mq = 0.0;
    for (var k = 0; k < n; k++) {
      mi += i[k];
      mq += q[k];
    }
    mi /= n;
    mq /= n;
    var sii = 0.0, sqq = 0.0, siq = 0.0;
    for (var k = 0; k < n; k++) {
      final a = i[k] - mi, b = q[k] - mq;
      sii += a * a;
      sqq += b * b;
      siq += a * b;
    }
    // główny wektor własny macierzy kowariancji 2×2
    final theta = 0.5 * atan2(2 * siq, sii - sqq);
    final c = cos(theta), s = sin(theta);
    return List<double>.generate(n, (k) => (i[k] - mi) * c + (q[k] - mq) * s);
  }

  static double _median(List<double> v) {
    if (v.isEmpty) return 0;
    final s = [...v]..sort();
    return s[s.length ~/ 2];
  }
}
