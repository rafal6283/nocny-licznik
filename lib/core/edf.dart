import 'dart:convert';
import 'dart:typed_data';

/// Sygnał w pliku EDF.
class EdfSignal {
  final String label;
  final String dim;
  final double physMin, physMax;
  final int digMin, digMax;
  final int samplesPerRecord;
  EdfSignal(this.label, this.dim, this.physMin, this.physMax, this.digMin, this.digMax, this.samplesPerRecord);

  double get gain => (digMax == digMin) ? 1 : (physMax - physMin) / (digMax - digMin);
  double physical(int d) => (d - digMin) * gain + physMin;
  bool get isAnnotation => label.toLowerCase().contains('annotation');
}

/// Adnotacja EDF+ (np. zdarzenie z aparatu CPAP).
class EdfAnnotation {
  final double onset; // sekundy od początku nagrania
  final double? duration;
  final String text;
  const EdfAnnotation(this.onset, this.duration, this.text);
}

/// Minimalny czytnik EDF / EDF+ (format plików z kart SD aparatów ResMed AirSense 10/11).
class EdfFile {
  final DateTime start; // czas lokalny z nagłówka
  final int numRecords;
  final double recordDuration; // s
  final List<EdfSignal> signals;
  final Uint8List _bytes;
  final int _headerBytes;
  final int _recordBytes;
  final List<int> _offsets; // przesunięcie sygnału w rekordzie (bajty)

  EdfFile._(this.start, this.numRecords, this.recordDuration, this.signals, this._bytes, this._headerBytes,
      this._recordBytes, this._offsets);

  static String _s(Uint8List b, int off, int len) => latin1.decode(b.sublist(off, off + len)).trim();

  static double _d(String s) => double.tryParse(s.replaceAll(',', '.')) ?? 0;

  static EdfFile parse(Uint8List b) {
    if (b.length < 256) throw const FormatException('Plik EDF za krótki');
    final date = _s(b, 168, 8); // dd.mm.yy
    final time = _s(b, 176, 8); // hh.mm.ss
    final headerBytes = int.tryParse(_s(b, 184, 8)) ?? 0;
    var numRecords = int.tryParse(_s(b, 236, 8)) ?? -1;
    final recDur = _d(_s(b, 244, 8));
    final ns = int.tryParse(_s(b, 252, 4)) ?? 0;
    if (ns <= 0 || headerBytes != 256 + ns * 256) throw const FormatException('Nieprawidłowy nagłówek EDF');

    final dp = date.split('.');
    final tp = time.split('.');
    var yy = int.tryParse(dp.length > 2 ? dp[2] : '') ?? 0;
    yy += yy >= 85 ? 1900 : 2000;
    final start = DateTime(
      yy,
      int.tryParse(dp.length > 1 ? dp[1] : '') ?? 1,
      int.tryParse(dp[0]) ?? 1,
      int.tryParse(tp[0]) ?? 0,
      int.tryParse(tp.length > 1 ? tp[1] : '') ?? 0,
      int.tryParse(tp.length > 2 ? tp[2] : '') ?? 0,
    );

    var p = 256;
    List<String> field(int width) {
      final out = <String>[];
      for (var i = 0; i < ns; i++) {
        out.add(_s(b, p + i * width, width));
      }
      p += ns * width;
      return out;
    }

    final labels = field(16);
    field(80); // transducer
    final dims = field(8);
    final pmin = field(8);
    final pmax = field(8);
    final dmin = field(8);
    final dmax = field(8);
    field(80); // prefiltering
    final spr = field(8);
    field(32); // reserved

    final sigs = <EdfSignal>[];
    final offsets = <int>[];
    var rb = 0;
    for (var i = 0; i < ns; i++) {
      final n = int.tryParse(spr[i]) ?? 0;
      sigs.add(EdfSignal(labels[i], dims[i], _d(pmin[i]), _d(pmax[i]), int.tryParse(dmin[i]) ?? -32768,
          int.tryParse(dmax[i]) ?? 32767, n));
      offsets.add(rb);
      rb += n * 2;
    }
    if (rb <= 0) throw const FormatException('Pusty rekord EDF');
    final available = (b.length - headerBytes) ~/ rb;
    if (numRecords < 0 || numRecords > available) numRecords = available;
    return EdfFile._(start, numRecords, recDur, sigs, b, headerBytes, rb, offsets);
  }

  int indexOf(List<String> names) {
    for (final n in names) {
      final i = signals.indexWhere((s) => s.label.toLowerCase() == n.toLowerCase());
      if (i >= 0) return i;
    }
    return -1;
  }

  /// Wartości fizyczne sygnału z rekordu [r].
  List<double> record(int sig, int r) {
    final s = signals[sig];
    final bd = ByteData.sublistView(_bytes);
    final base = _headerBytes + r * _recordBytes + _offsets[sig];
    final out = <double>[];
    for (var k = 0; k < s.samplesPerRecord; k++) {
      final pos = base + k * 2;
      if (pos + 2 > _bytes.length) break;
      out.add(s.physical(bd.getInt16(pos, Endian.little)));
    }
    return out;
  }

  /// Cały sygnał (wszystkie rekordy po kolei).
  List<double> signal(int sig) => [for (var r = 0; r < numRecords; r++) ...record(sig, r)];

  /// Odstęp między próbkami sygnału w sekundach.
  double interval(int sig) => recordDuration / signals[sig].samplesPerRecord;

  /// Adnotacje EDF+ (TAL: +onset\x15duration\x14tekst\x14…\x00).
  List<EdfAnnotation> annotations() {
    final out = <EdfAnnotation>[];
    for (var si = 0; si < signals.length; si++) {
      if (!signals[si].isAnnotation) continue;
      for (var r = 0; r < numRecords; r++) {
        final base = _headerBytes + r * _recordBytes + _offsets[si];
        final len = signals[si].samplesPerRecord * 2;
        if (base + len > _bytes.length) break;
        final raw = latin1.decode(_bytes.sublist(base, base + len));
        for (final tal in raw.split('\u0000')) {
          if (tal.isEmpty || !(tal.startsWith('+') || tal.startsWith('-'))) continue;
          final parts = tal.split('\u0014');
          final head = parts.first.split('\u0015');
          final onset = double.tryParse(head[0]);
          if (onset == null) continue;
          final dur = head.length > 1 ? double.tryParse(head[1]) : null;
          for (final t in parts.skip(1)) {
            if (t.trim().isEmpty) continue;
            out.add(EdfAnnotation(onset, dur, t.trim()));
          }
        }
      }
    }
    return out;
  }
}
