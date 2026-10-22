import 'db.dart';
import 'metrics.dart';
import 'bus.dart';

/// Dzienne dane z aparatu CPAP.
class CpapDay {
  final DateTime date;
  final double? ahi;
  final double? leak;
  final int? usageMin;
  const CpapDay(this.date, this.ahi, this.leak, this.usageMin);
}

/// Import podsumowań z aparatu CPAP z pliku CSV — np. eksport „Summary” z programu OSCAR
/// (czyta kartę SD z aparatów ResMed, Philips i innych). Kolumny rozpoznawane po nazwie:
/// data (Date/Data/Day), AHI, nieszczelność (Leak — preferowana mediana), czas użycia
/// (Total Time/Usage/Hours).
class CpapImport {
  static List<CpapDay> parse(String text) {
    final lines = text.replaceAll('\r', '').split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return [];
    final delim = lines.first.split(';').length > lines.first.split(',').length ? ';' : ',';
    List<String> cells(String l) => _splitCsv(l, delim);

    var headerIdx = -1;
    for (var i = 0; i < lines.length && i < 10; i++) {
      final h = cells(lines[i]).map((c) => c.toLowerCase()).toList();
      if (h.any((c) => c.contains('ahi')) && h.any((c) => c.contains('date') || c.contains('data') || c == 'day')) {
        headerIdx = i;
        break;
      }
    }
    if (headerIdx < 0) return [];
    final h = cells(lines[headerIdx]).map((c) => c.toLowerCase().trim()).toList();
    int find(bool Function(String) f) => h.indexWhere(f);
    final iDate = find((c) => c == 'date' || c == 'data' || c == 'day' || c.startsWith('date'));
    final iAhi = find((c) => c == 'ahi' || c.startsWith('ahi'));
    var iLeak = find((c) => c.contains('leak') && (c.contains('med') || c.contains('50')));
    if (iLeak < 0) iLeak = find((c) => c.contains('leak') && (c.contains('95') || c.contains('avg') || c.contains('aver')));
    if (iLeak < 0) iLeak = find((c) => c.contains('leak') || c.contains('nieszczel'));
    final iUse = find((c) => c.contains('total time') || c.contains('usage') || c.contains('hours') || c.contains('czas'));

    final out = <CpapDay>[];
    for (final l in lines.skip(headerIdx + 1)) {
      final c = cells(l);
      if (iDate < 0 || iDate >= c.length) continue;
      final d = _date(c[iDate]);
      if (d == null) continue;
      out.add(CpapDay(
        d,
        iAhi >= 0 && iAhi < c.length ? _num(c[iAhi]) : null,
        iLeak >= 0 && iLeak < c.length ? _num(c[iLeak]) : null,
        iUse >= 0 && iUse < c.length ? _minutes(c[iUse]) : null,
      ));
    }
    return out;
  }

  /// Przypisuje dane do nocy (po dniu rozpoczęcia nocy). Zwraca liczbę zaktualizowanych nocy.
  static Future<int> apply(List<CpapDay> days) async {
    final nights = await Db.instance.nights();
    var n = 0;
    for (final night in nights) {
      final day = nightDay(night);
      CpapDay? m;
      for (final d in days) {
        if (d.date == day) {
          m = d;
          break;
        }
      }
      if (m == null) continue;
      night.cpap = true;
      night.cpapAhi = m.ahi ?? night.cpapAhi;
      night.cpapLeak = m.leak ?? night.cpapLeak;
      night.cpapUsageMin = m.usageMin ?? night.cpapUsageMin;
      await Db.instance.updateNight(night);
      n++;
    }
    if (n > 0) dataChanged();
    return n;
  }

  static List<String> _splitCsv(String line, String d) {
    final out = <String>[];
    final b = StringBuffer();
    var q = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        q = !q;
      } else if (ch == d && !q) {
        out.add(b.toString().trim());
        b.clear();
      } else {
        b.write(ch);
      }
    }
    out.add(b.toString().trim());
    return out;
  }

  static double? _num(String s) => double.tryParse(s.replaceAll(',', '.').replaceAll(RegExp(r'[^0-9.\-]'), ''));

  static int? _minutes(String s) {
    final t = s.trim();
    final parts = t.split(':');
    if (parts.length >= 2) {
      final h = int.tryParse(parts[0]) ?? 0;
      final m = int.tryParse(parts[1]) ?? 0;
      return h * 60 + m;
    }
    final v = _num(t);
    if (v == null) return null;
    return v <= 24 ? (v * 60).round() : v.round(); // godziny albo minuty
  }

  static DateTime? _date(String s) {
    final t = s.trim().split(' ').first;
    var m = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$').firstMatch(t);
    if (m != null) return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    m = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$').firstMatch(t);
    if (m != null) {
      final a = int.parse(m[1]!), b = int.parse(m[2]!);
      // dzień.miesiąc.rok (PL); jeśli drugi człon > 12, to format amerykański
      return b > 12 ? DateTime(int.parse(m[3]!), a, b) : DateTime(int.parse(m[3]!), b, a);
    }
    return null;
  }
}
