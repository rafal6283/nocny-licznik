import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Zapis WAV (PCM 16-bit mono) i synteza dźwięków bez plików z zewnątrz:
/// szumy do kołysanek oraz melodia budzika.
class AudioSynth {
  static Uint8List wav(Int16List pcm, int sampleRate) {
    final dataLen = pcm.length * 2;
    final b = ByteData(44 + dataLen);
    void str(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        b.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    b.setUint32(4, 36 + dataLen, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, 1, Endian.little); // mono
    b.setUint32(24, sampleRate, Endian.little);
    b.setUint32(28, sampleRate * 2, Endian.little);
    b.setUint16(32, 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    str(36, 'data');
    b.setUint32(40, dataLen, Endian.little);
    for (var i = 0; i < pcm.length; i++) {
      b.setInt16(44 + i * 2, pcm[i], Endian.little);
    }
    return b.buffer.asUint8List();
  }

  static Int16List toPcm(Float64List x, {double gain = 1.0}) {
    var peak = 1e-9;
    for (final v in x) {
      if (v.abs() > peak) peak = v.abs();
    }
    final out = Int16List(x.length);
    final k = 32000 * gain / peak;
    for (var i = 0; i < x.length; i++) {
      out[i] = (x[i] * k).round().clamp(-32767, 32767);
    }
    return out;
  }

  static Future<Directory> _cacheDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'sounds'));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// Zwraca ścieżkę do zapętlanego (bez trzasku na łączeniu) pliku szumu.
  static Future<String> noiseFile(String kind) async {
    final dir = await _cacheDir();
    final f = File(p.join(dir.path, 'noise_${kind}_v1.wav'));
    if (f.existsSync()) return f.path;
    const sr = 22050;
    const seconds = 40;
    final x = _makeLoopable(_noise(kind, sr * seconds, sr), sr * 2);
    await f.writeAsBytes(wav(toPcm(x, gain: 0.9), sr), flush: true);
    return f.path;
  }

  /// Melodia budzika: łagodne „dzwoneczki”, zapętlana.
  static Future<String> alarmFile() async {
    final dir = await _cacheDir();
    final f = File(p.join(dir.path, 'alarm_v1.wav'));
    if (f.existsSync()) return f.path;
    const sr = 22050;
    // pentatonika C-dur: C5 E5 G5 A5 C6 …
    const notes = [523.25, 659.25, 783.99, 880.0, 1046.5, 880.0, 783.99, 659.25];
    const noteLen = 0.38;
    final total = (sr * (notes.length * noteLen + 1.2)).round();
    final x = Float64List(total);
    for (var n = 0; n < notes.length; n++) {
      final start = (n * noteLen * sr).round();
      final f0 = notes[n];
      final len = (sr * 1.4).round();
      for (var i = 0; i < len && start + i < total; i++) {
        final t = i / sr;
        final env = exp(-3.2 * t) * (1 - exp(-120 * t));
        final v = sin(2 * pi * f0 * t) + 0.35 * sin(2 * pi * 2 * f0 * t) + 0.12 * sin(2 * pi * 3.01 * f0 * t);
        x[start + i] += 0.5 * env * v;
      }
    }
    await f.writeAsBytes(wav(toPcm(x, gain: 0.95), sr), flush: true);
    return f.path;
  }

  static Float64List _noise(String kind, int n, int sr) {
    final r = Random(42);
    final x = Float64List(n);
    double white() => r.nextDouble() * 2 - 1;

    switch (kind) {
      case 'white':
        for (var i = 0; i < n; i++) {
          x[i] = white();
        }
      case 'pink':
        // filtr Paula Kellet'a
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0;
        for (var i = 0; i < n; i++) {
          final w = white();
          b0 = 0.99886 * b0 + w * 0.0555179;
          b1 = 0.99332 * b1 + w * 0.0750759;
          b2 = 0.96900 * b2 + w * 0.1538520;
          b3 = 0.86650 * b3 + w * 0.3104856;
          b4 = 0.55000 * b4 + w * 0.5329522;
          b5 = -0.7616 * b5 - w * 0.0168980;
          x[i] = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362;
          b6 = w * 0.115926;
        }
      case 'brown':
      case 'waves':
        var last = 0.0;
        for (var i = 0; i < n; i++) {
          last = (last + 0.02 * white()) / 1.02;
          x[i] = last;
        }
        if (kind == 'waves') {
          // fale: powolna modulacja głośności ~8 s
          for (var i = 0; i < n; i++) {
            final t = i / sr;
            final m = 0.25 + 0.75 * pow(0.5 + 0.5 * sin(2 * pi * t / 8.0), 2.0);
            x[i] *= m;
          }
        }
      case 'fan':
        // wentylator: szum różowy + lekki buczący ton
        final pinkish = _noise('pink', n, sr);
        for (var i = 0; i < n; i++) {
          final t = i / sr;
          x[i] = pinkish[i] * 0.8 + 0.08 * sin(2 * pi * 110 * t) * (1 + 0.1 * sin(2 * pi * 0.3 * t));
        }
      case 'rain':
      default:
        // deszcz: przefiltrowany szum + losowe krople
        var lp = 0.0;
        for (var i = 0; i < n; i++) {
          lp = lp * 0.6 + white() * 0.4;
          x[i] = lp * 0.6;
        }
        final drops = n ~/ 400;
        for (var d = 0; d < drops; d++) {
          final at = r.nextInt(n);
          final amp = 0.3 + r.nextDouble() * 0.9;
          final f0 = 1500 + r.nextDouble() * 3500;
          final len = (sr * 0.012).round();
          for (var i = 0; i < len && at + i < n; i++) {
            final t = i / sr;
            x[at + i] += amp * exp(-400 * t) * sin(2 * pi * f0 * t);
          }
        }
    }
    return x;
  }

  /// Przenikanie końcówki w początek i obcięcie jej — pętla jest bezszwowa:
  /// ostatnia próbka wyniku przechodzi płynnie w pierwszą.
  static Float64List _makeLoopable(Float64List x, int fade) {
    final n = x.length - fade;
    final y = Float64List(n);
    for (var i = 0; i < n; i++) {
      if (i < fade) {
        final a = i / fade;
        y[i] = x[i] * a + x[n + i] * (1 - a);
      } else {
        y[i] = x[i];
      }
    }
    return y;
  }
}
