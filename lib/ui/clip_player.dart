import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../core/models.dart';
import '../core/settings.dart';
import 'theme.dart';

/// Przebieg głośności nagrania (słupki) wyliczony z pliku WAV.
class ClipWave {
  final List<double> levels; // 0..1 dla każdego słupka
  final List<double> dbfs; // głośność słupka w dBFS
  final Duration duration;
  final double peakDbfs, avgDbfs;
  const ClipWave(this.levels, this.dbfs, this.duration, this.peakDbfs, this.avgDbfs);

  static final Map<String, ClipWave> _cache = {};

  static Future<ClipWave?> load(String path, {int bars = 72}) async {
    final hit = _cache[path];
    if (hit != null) return hit;
    try {
      final b = await File(path).readAsBytes();
      final w = parse(b, bars: bars);
      if (w != null) _cache[path] = w;
      return w;
    } catch (_) {
      return null;
    }
  }

  /// Parsuje WAV PCM 16-bit (mono lub stereo — bierze 1. kanał).
  static ClipWave? parse(Uint8List b, {int bars = 72}) {
    if (b.length < 44 || String.fromCharCodes(b.sublist(0, 4)) != 'RIFF') return null;
    final bd = ByteData.sublistView(b);
    var sr = 16000, ch = 1, bits = 16;
    var p = 12;
    int? dataOff, dataLen;
    while (p + 8 <= b.length) {
      final id = String.fromCharCodes(b.sublist(p, p + 4));
      final len = bd.getUint32(p + 4, Endian.little);
      if (id == 'fmt ' && p + 24 <= b.length) {
        ch = bd.getUint16(p + 10, Endian.little);
        sr = bd.getUint32(p + 12, Endian.little);
        bits = bd.getUint16(p + 22, Endian.little);
      } else if (id == 'data') {
        dataOff = p + 8;
        dataLen = min(len, b.length - dataOff);
        break;
      }
      p += 8 + len + (len.isOdd ? 1 : 0);
    }
    if (dataOff == null || bits != 16 || ch < 1 || sr <= 0) return null;
    final frames = dataLen! ~/ (2 * ch);
    if (frames <= 0) return null;
    final n = min(bars, frames);
    final per = frames / n;
    final db = <double>[];
    var sumAll = 0.0;
    var peak = -200.0;
    for (var i = 0; i < n; i++) {
      final a = (i * per).floor(), z = max(a + 1, ((i + 1) * per).floor());
      var s = 0.0;
      for (var k = a; k < z; k++) {
        final v = bd.getInt16(dataOff + k * 2 * ch, Endian.little) / 32768.0;
        s += v * v;
      }
      sumAll += s;
      final d = 10 * log(s / (z - a) + 1e-12) / ln10;
      db.add(d);
      if (d > peak) peak = d;
    }
    final avg = 10 * log(sumAll / frames + 1e-12) / ln10;
    // skala: od 6 dB nad tłem nagrania do szczytu (min. 30 dB zakresu)
    final sorted = [...db]..sort();
    final floor = sorted[(sorted.length * 0.1).floor()];
    final lo = min(floor, peak - 30);
    final levels = [for (final d in db) ((d - lo) / max(1e-6, peak - lo)).clamp(0.04, 1.0).toDouble()];
    return ClipWave(levels, db, Duration(milliseconds: (frames * 1000 / sr).round()), peak, avg);
  }
}

/// Co jeszcze działo się w czasie nagrania.
class ClipFact {
  final String emoji, text;
  const ClipFact(this.emoji, this.text);
}

double _pct(List<double> v, double q) {
  if (v.isEmpty) return double.infinity;
  final s = [...v]..sort();
  return s[min(s.length - 1, (s.length * q).floor())];
}

List<ClipFact> clipFacts(
  SoundEvent e,
  Duration dur,
  List<MinuteSample> ms,
  List<SoundEvent> evs,
  List<DateTime> cpap, {
  bool farts = false,
}) {
  final from = e.ts.subtract(const Duration(seconds: 5));
  final to = e.ts.add(dur + const Duration(seconds: 5));
  final out = <ClipFact>[];

  // minuty nachodzące na nagranie (ts minuty = jej koniec)
  final idx = <int>[
    for (var i = 0; i < ms.length; i++)
      if (ms[i].ts.isAfter(from) && ms[i].ts.subtract(const Duration(minutes: 1)).isBefore(to)) i
  ];
  final over = [for (final i in idx) ms[i]];

  if (over.isNotEmpty) out.add(ClipFact('🛌', 'faza: ${over.first.stage.label.toLowerCase()}'));

  // ruch — względem tej nocy (górne 20% minut z ruchem)
  final mot = [for (final m in ms) if (m.motion > 0) m.motion];
  final thr = _pct(mot, 0.8);
  final sMot = [for (final m in ms) if ((m.sonarMotion ?? 0) > 0) m.sonarMotion!];
  final sThr = _pct(sMot, 0.8);
  if (over.any((m) => m.motion > 0 && m.motion >= thr)) {
    out.add(const ClipFact('🏃', 'ruch'));
  } else if (over.any((m) => (m.sonarMotion ?? 0) > 0 && m.sonarMotion! >= sThr)) {
    out.add(const ClipFact('🏃', 'ruch (sonar)'));
  }

  // zmiana światła względem poprzedniej minuty
  for (final i in idx) {
    final cur = ms[i].lux;
    if (cur == null) continue;
    double? prev;
    for (var j = i - 1; j >= max(0, i - 3); j--) {
      if (ms[j].lux != null) {
        prev = ms[j].lux;
        break;
      }
    }
    if (prev == null) continue;
    if ((cur - prev).abs() >= max(3.0, 0.5 * min(cur, prev))) {
      out.add(ClipFact('💡', cur > prev ? 'zapalone światło (${prev.round()}→${cur.round()} lx)' : 'zgaszone światło (${prev.round()}→${cur.round()} lx)'));
      break;
    }
  }

  // inne dźwięki w tym czasie
  final seen = <SoundType>{e.type};
  for (final o in evs) {
    if (o.id == e.id || seen.contains(o.type)) continue;
    if (o.type == SoundType.fart && !farts) continue;
    if (o.verified == false) continue;
    final oEnd = o.ts.add(Duration(milliseconds: max(1000, o.durationMs)));
    if (oEnd.isBefore(from) || o.ts.isAfter(to)) continue;
    seen.add(o.type);
    out.add(ClipFact(o.type.emoji, o.type.label.toLowerCase()));
  }
  if (!seen.contains(SoundType.snore) && over.any((m) => m.snore)) out.add(const ClipFact('😴', 'chrapanie'));
  if (!seen.contains(SoundType.apnea) && over.any((m) => m.apneas > 0)) {
    out.add(const ClipFact('🫁', 'przerwa w oddechu'));
  }
  if (farts && !seen.contains(SoundType.fart) && over.any((m) => m.farts > 0)) out.add(const ClipFact('◆', 'FF'));

  // CPAP
  if (cpap.any((t) => !t.isBefore(from.subtract(const Duration(seconds: 25))) && !t.isAfter(to))) {
    out.add(const ClipFact('😷', 'zdarzenie z aparatu CPAP'));
  }

  // oddech i tętno
  final br = [for (final m in over) if (m.breathRate != null) m.breathRate!];
  if (br.isNotEmpty) out.add(ClipFact('🌬️', 'oddech ${(br.reduce((a, b) => a + b) / br.length).round()}/min'));
  final hr = [for (final m in over) if (m.hr != null) m.hr!];
  if (hr.isNotEmpty) out.add(ClipFact('❤️', 'tętno ${(hr.reduce((a, b) => a + b) / hr.length).round()}'));
  return out;
}

String _mmss(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// Rozwinięty odtwarzacz: przebieg głośności z postępem, przewijanie dotykiem, poziom dźwięku.
class ClipWaveView extends StatefulWidget {
  final String path;
  final Color color;
  final AudioPlayer player;
  final bool active; // czy to nagranie jest teraz załadowane w odtwarzaczu
  final Future<void> Function(Duration at) onSeek;
  const ClipWaveView(
      {super.key, required this.path, required this.color, required this.player, required this.active, required this.onSeek});

  @override
  State<ClipWaveView> createState() => _ClipWaveViewState();
}

class _ClipWaveViewState extends State<ClipWaveView> {
  ClipWave? wave;
  bool failed = false;
  double? dragFrac;

  @override
  void initState() {
    super.initState();
    ClipWave.load(widget.path).then((w) {
      if (mounted) setState(() => w == null ? failed = true : wave = w);
    });
  }

  @override
  Widget build(BuildContext context) {
    final w = wave;
    if (failed) {
      return const Padding(
          padding: EdgeInsets.all(8), child: Text('Nie można odczytać nagrania', style: TextStyle(color: C.muted)));
    }
    if (w == null) return const SizedBox(height: 64, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
    final s = Settings.instance;
    return StreamBuilder<Duration>(
      stream: widget.player.positionStream,
      builder: (context, snap) {
        final pos = widget.active ? (snap.data ?? Duration.zero) : Duration.zero;
        final frac = dragFrac ??
            (w.duration.inMilliseconds == 0 ? 0.0 : (pos.inMilliseconds / w.duration.inMilliseconds).clamp(0.0, 1.0));
        Future<void> seekTo(double f) =>
            widget.onSeek(Duration(milliseconds: (w.duration.inMilliseconds * f.clamp(0.0, 1.0)).round()));
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          LayoutBuilder(builder: (context, box) {
            double f(Offset o) => (o.dx / box.maxWidth).clamp(0.0, 1.0);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => seekTo(f(d.localPosition)),
              onHorizontalDragUpdate: (d) => setState(() => dragFrac = f(d.localPosition)),
              onHorizontalDragEnd: (_) {
                final x = dragFrac;
                setState(() => dragFrac = null);
                if (x != null) seekTo(x);
              },
              child: SizedBox(
                height: 64,
                width: box.maxWidth,
                child: CustomPaint(painter: _ClipWavePainter(w.levels, frac, widget.color, widget.active || dragFrac != null)),
              ),
            );
          }),
          const SizedBox(height: 4),
          Row(children: [
            Text('${_mmss(Duration(milliseconds: (w.duration.inMilliseconds * frac).round()))} / ${_mmss(w.duration)}',
                style: const TextStyle(fontSize: 11, color: C.muted, fontFeatures: [FontFeature.tabularFigures()])),
            const Spacer(),
            Text('🔊 śr. ${s.spl(w.avgDbfs).round()} dB · szczyt ${s.spl(w.peakDbfs).round()} dB',
                style: const TextStyle(fontSize: 11, color: C.muted)),
          ]),
        ]);
      },
    );
  }
}

class _ClipWavePainter extends CustomPainter {
  final List<double> levels;
  final double frac;
  final Color color;
  final bool showHead;
  _ClipWavePainter(this.levels, this.frac, this.color, this.showHead);

  @override
  void paint(Canvas c, Size size) {
    final n = levels.length;
    if (n == 0) return;
    final slot = size.width / n;
    final bw = max(1.5, slot * 0.55);
    final mid = size.height / 2;
    final played = Paint()..color = color;
    final rest = Paint()..color = C.muted.withValues(alpha: 0.45);
    for (var i = 0; i < n; i++) {
      final x = slot * i + (slot - bw) / 2;
      final h = max(2.0, levels[i] * (size.height - 8));
      c.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(x, mid - h / 2, bw, h), Radius.circular(bw / 2)),
          (i + 0.5) / n <= frac ? played : rest);
    }
    if (showHead) {
      final hx = (size.width * frac).clamp(7.0, size.width - 7);
      final head = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(hx, mid), width: 14, height: size.height), const Radius.circular(7));
      c.drawRRect(head, Paint()..color = color.withValues(alpha: 0.35));
      c.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(hx, mid), width: 3, height: size.height - 10), const Radius.circular(2)),
          Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant _ClipWavePainter old) =>
      old.frac != frac || old.levels != levels || old.showHead != showHead || old.color != color;
}
