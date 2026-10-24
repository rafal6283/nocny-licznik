import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'bus.dart';
import 'db.dart';
import 'edf.dart';
import 'metrics.dart';
import 'models.dart';

/// Dzienne podsumowanie z STR.edf.
class ResmedDay {
  final DateTime date;
  final int usageMin;
  final double? ahi, oai, cai, hi, leak50, leak95, press50, press95, rr50;
  const ResmedDay(this.date, this.usageMin, this.ahi, this.oai, this.cai, this.hi, this.leak50, this.leak95,
      this.press50, this.press95, this.rr50);
}

class ResmedResult {
  int days = 0, nightsSummary = 0, nightsDetail = 0, events = 0, files = 0;
  final List<String> problems = [];
}

/// Import z karty SD aparatów ResMed AirSense 10/11:
/// • STR.edf — podsumowanie dnia (AHI i rodzaje zdarzeń, nieszczelność, ciśnienie, czas użycia),
/// • DATALOG/RRRRMMDD/*_EVE.edf — zdarzenia z godziną (EDF+),
/// • DATALOG/RRRRMMDD/*_PLD.edf — przebiegi co 2 s (nieszczelność, ciśnienie, oddech, chrapanie, ograniczenie przepływu).
/// Dzień ResMed trwa od południa do południa — tak jak „dzień nocy” w aplikacji.
class ResmedImport {
  static double? _first(EdfFile f, List<String> names, int r, {double scale = 1}) {
    final i = f.indexOf(names);
    if (i < 0) return null;
    final v = f.record(i, r);
    if (v.isEmpty) return null;
    final x = v.first;
    if (x.isNaN || x < 0) return null; // wartości ujemne = brak danych
    return x * scale;
  }

  static double _leakScale(EdfFile f, List<String> names) {
    final i = f.indexOf(names);
    if (i < 0) return 1;
    final d = f.signals[i].dim.toLowerCase();
    return d.contains('/s') ? 60 : 1; // l/s → l/min
  }

  static List<ResmedDay> parseStr(EdfFile f) {
    const leakN = ['Leak.50', 'Leak Med'];
    const leak95N = ['Leak.95', 'Leak.95%'];
    final ls = _leakScale(f, [...leakN, ...leak95N]);
    final out = <ResmedDay>[];
    final day0 = DateTime(f.start.year, f.start.month, f.start.day);
    for (var r = 0; r < f.numRecords; r++) {
      final dur = _first(f, ['Duration', 'OnDuration'], r);
      if (dur == null || dur < 1) continue; // dzień bez użycia
      out.add(ResmedDay(
        DateTime(day0.year, day0.month, day0.day + r),
        dur.round(),
        _first(f, ['AHI'], r),
        _first(f, ['OAI'], r),
        _first(f, ['CAI'], r),
        _first(f, ['HI'], r),
        _first(f, leakN, r, scale: ls),
        _first(f, leak95N, r, scale: ls),
        _first(f, ['MaskPress.50', 'TgtIPAP.50', 'TgtEPAP.50'], r),
        _first(f, ['MaskPress.95', 'TgtIPAP.95', 'TgtEPAP.95'], r),
        _first(f, ['RespRate.50'], r),
      ));
    }
    return out;
  }

  /// Rodzaj zdarzenia → klucz w bazie.
  static String? eventKind(String t) {
    final s = t.toLowerCase();
    if (s.contains('recording') || s.contains('start')) return null;
    if (s.contains('obstructive')) return 'ev_oa';
    if (s.contains('central')) return 'ev_ca';
    if (s.contains('hypopnea')) return 'ev_h';
    if (s.contains('arousal')) return 'ev_arousal';
    if (s.contains('apnea')) return 'ev_a';
    if (s.contains('flow')) return 'ev_fl';
    if (s.contains('csr') || s.contains('cheyne')) return 'ev_csr';
    return null;
  }

  static List<(DateTime, String, double?, double?)> parseEve(EdfFile f) => [
        for (final a in f.annotations())
          if (eventKind(a.text) != null)
            (f.start.add(Duration(milliseconds: (a.onset * 1000).round())), eventKind(a.text)!, null, a.duration)
      ];

  /// Przebiegi uśrednione do minut.
  static List<(DateTime, String, double?, double?)> parsePld(EdfFile f) {
    final out = <(DateTime, String, double?, double?)>[];
    void add(List<String> names, String kind, {double Function(EdfSignal s)? scale}) {
      final i = f.indexOf(names);
      if (i < 0) return;
      final k = scale?.call(f.signals[i]) ?? 1;
      final v = f.signal(i);
      final dt = f.interval(i);
      final perMin = max(1, (60 / dt).round());
      for (var j = 0; j + perMin <= v.length; j += perMin) {
        var sum = 0.0, c = 0;
        for (var q = j; q < j + perMin; q++) {
          if (v[q] >= 0) {
            sum += v[q];
            c++;
          }
        }
        if (c == 0) continue;
        out.add((f.start.add(Duration(milliseconds: (j * dt * 1000).round())), kind, sum / c * k, null));
      }
    }

    double leakScale(EdfSignal s) => s.dim.toLowerCase().contains('/s') ? 60 : 1;
    add(['Leak.2s', 'Leak'], 'leak', scale: leakScale);
    add(['MaskPress.2s', 'Press.2s', 'MaskPress'], 'press');
    add(['RespRate.2s', 'RespRate'], 'rr');
    add(['Snore.2s', 'Snore'], 'snore');
    add(['FlowLim.2s', 'FlowLim'], 'flim');
    return out;
  }

  /// Importuje listę plików (STR.edf, *_EVE.edf, *_PLD.edf) do zapisanych nocy.
  static Future<ResmedResult> importFiles(List<(String name, Uint8List bytes)> files) async {
    final res = ResmedResult();
    final nights = await Db.instance.nights();
    if (nights.isEmpty) {
      res.problems.add('Brak zapisanych nocy w aplikacji — dane z aparatu przypisuję tylko do nagranych nocy.');
      return res;
    }
    final touched = <int>{};
    final detailRows = <int, Map<String, List<(DateTime, String, double?, double?)>>>{};

    Night? nightAt(DateTime t) {
      for (final n in nights) {
        final end = n.end ?? n.start.add(Duration(minutes: n.inBedMin));
        if (!t.isBefore(n.start.subtract(const Duration(hours: 2))) && !t.isAfter(end.add(const Duration(hours: 2)))) {
          return n;
        }
      }
      return null;
    }

    for (final (name, bytes) in files) {
      final lower = name.toLowerCase();
      EdfFile f;
      try {
        f = EdfFile.parse(bytes);
      } catch (e) {
        res.problems.add('$name: $e');
        continue;
      }
      res.files++;
      if (lower.endsWith('str.edf')) {
        final days = parseStr(f);
        res.days += days.length;
        for (final d in days) {
          for (final n in nights) {
            if (nightDay(n) != d.date) continue;
            n.cpap = true;
            n.cpapUsageMin = d.usageMin;
            n.cpapAhi = d.ahi ?? n.cpapAhi;
            n.cpapOai = d.oai;
            n.cpapCai = d.cai;
            n.cpapHi = d.hi;
            n.cpapLeak = d.leak50 ?? n.cpapLeak;
            n.cpapLeak95 = d.leak95;
            n.cpapPress50 = d.press50;
            n.cpapPress95 = d.press95;
            n.cpapRr = d.rr50;
            await Db.instance.updateNight(n);
            touched.add(n.id!);
            res.nightsSummary++;
          }
        }
      } else if (lower.endsWith('eve.edf') || lower.endsWith('pld.edf')) {
        final n = nightAt(f.start.add(const Duration(hours: 1)));
        if (n == null) continue;
        final rows = lower.endsWith('eve.edf') ? parseEve(f) : parsePld(f);
        final key = lower.endsWith('eve.edf') ? 'ev_' : 'series';
        detailRows.putIfAbsent(n.id!, () => {}).putIfAbsent(key, () => []).addAll(rows);
        if (key == 'ev_') res.events += rows.length;
      }
    }

    // Zapis szczegółów (jedna noc może mieć kilka sesji = kilka plików)
    for (final e in detailRows.entries) {
      final ev = e.value['ev_'];
      if (ev != null) await Db.instance.replaceExt(e.key, 'ev_', ev);
      final se = e.value['series'];
      if (se != null) {
        for (final k in ['leak', 'press', 'rr', 'snore', 'flim']) {
          await Db.instance.replaceExt(e.key, k, se.where((r) => r.$2 == k).toList());
        }
      }
      final n = nights.firstWhere((x) => x.id == e.key);
      if (!n.cpap) {
        n.cpap = true;
        await Db.instance.updateNight(n);
      }
      touched.add(e.key);
      res.nightsDetail++;
    }
    if (touched.isNotEmpty) dataChanged();
    return res;
  }

  /// Wczytuje pliki z dysku (ścieżki zwrócone przez wybór karty SD lub plików).
  static Future<ResmedResult> importPaths(List<String> paths) async {
    final files = <(String, Uint8List)>[];
    for (final p in paths) {
      try {
        files.add((p.split(Platform.pathSeparator).last, await File(p).readAsBytes()));
      } catch (_) {}
    }
    return importFiles(files);
  }
}
