import 'dart:math';

import 'package:flutter/material.dart';

import '../core/body_position.dart';
import '../core/db.dart';
import '../core/fmt.dart';
import '../core/models.dart';
import 'theme.dart';

/// Pozycja ciała a oddech: bezdechy i chrapanie w każdej pozycji, ze wszystkich nocy z opaską.
class PositionStatsScreen extends StatefulWidget {
  const PositionStatsScreen({super.key});

  @override
  State<PositionStatsScreen> createState() => _PositionStatsScreenState();
}

class PosAgg {
  double minutes = 0;
  int appEvents = 0, cpapEvents = 0, snoreMin = 0;
  double cpapMinutes = 0;
  double? perHour(int n, double min) => min < 20 ? null : n / (min / 60);
}

class _PositionStatsScreenState extends State<PositionStatsScreen> {
  Map<BodyPos, PosAgg>? agg;
  int nights = 0;
  int days = 90;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => agg = null);
    final (out, used) = await computePositionStats(days);
    if (mounted) {
      setState(() {
        agg = out;
        nights = used;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = agg;
    return Scaffold(
      appBar: AppBar(title: const Text('Pozycja ciała a oddech')),
      body: a == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
              Wrap(spacing: 6, children: [
                for (final (d, t) in [(30, '30 dni'), (90, '90 dni'), (365, 'Rok'), (100000, 'Całość')])
                  ChoiceChip(
                    label: Text(t),
                    selected: days == d,
                    onSelected: (_) {
                      days = d;
                      _load();
                    },
                  ),
              ]),
              const SizedBox(height: 10),
              if (nights == 0)
                const Section(
                  child: Text(
                    'Pozycję ciała zna opaska na klatkę piersiową (Polar H10). Śpij z nią kilka nocy, '
                    'a tu pojawi się porównanie bezdechów i chrapania na plecach, bokach i brzuchu.',
                    style: TextStyle(color: C.muted, height: 1.4),
                  ),
                )
              else ...[
                _verdict(a),
                const SizedBox(height: 10),
                _table(a),
                const SizedBox(height: 8),
                Text(
                  'Noce z opaską: $nights. Indeksy liczone na godzinę snu w danej pozycji (pozycje poniżej 20 min '
                  'pominięte). „Aplikacja” = przerwy w oddechu z mikrofonu/sonaru, „aparat” = zdarzenia z karty AirSense '
                  '(liczone na godzinę z maską).',
                  style: const TextStyle(fontSize: 11, color: C.muted, height: 1.4),
                ),
              ],
            ]),
    );
  }

  Widget _table(Map<BodyPos, PosAgg> a) {
    final rows = [for (final p in BodyPos.values) if (a[p]!.minutes > 0) p];
    String f(double? v) => v == null ? '—' : v.toStringAsFixed(1);
    return Card(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(columnSpacing: 16, columns: const [
          DataColumn(label: Text('Pozycja')),
          DataColumn(label: Text('Czas'), numeric: true),
          DataColumn(label: Text('Aplikacja\n/h'), numeric: true),
          DataColumn(label: Text('Aparat\n/h'), numeric: true),
          DataColumn(label: Text('Chrapanie'), numeric: true),
        ], rows: [
          for (final p in rows)
            DataRow(cells: [
              DataCell(Text(p.label)),
              DataCell(Text(durHM(a[p]!.minutes))),
              DataCell(Text(f(a[p]!.perHour(a[p]!.appEvents, a[p]!.minutes)))),
              DataCell(Text(f(a[p]!.perHour(a[p]!.cpapEvents, a[p]!.cpapMinutes)))),
              DataCell(Text('${(a[p]!.snoreMin / max(1, a[p]!.minutes) * 100).round()}%')),
            ]),
        ]),
      ),
    );
  }

  /// Kryterium Cartwrighta: indeks na plecach ≥ 2× większy niż na bokach → bezdech zależny od pozycji.
  Widget _verdict(Map<BodyPos, PosAgg> a) {
    final back = a[BodyPos.back]!;
    final side = PosAgg();
    for (final p in [BodyPos.left, BodyPos.right]) {
      side.minutes += a[p]!.minutes;
      side.appEvents += a[p]!.appEvents;
      side.cpapEvents += a[p]!.cpapEvents;
      side.cpapMinutes += a[p]!.cpapMinutes;
      side.snoreMin += a[p]!.snoreMin;
    }
    String? line(String what, double? b, double? s) {
      if (b == null || s == null) return null;
      if (b >= 2 * max(s, 0.5) && b >= 5) {
        return '$what: na plecach ${b.toStringAsFixed(1)}/h, na bokach ${s.toStringAsFixed(1)}/h — '
            'wyraźnie zależne od pozycji.';
      }
      return '$what: na plecach ${b.toStringAsFixed(1)}/h, na bokach ${s.toStringAsFixed(1)}/h.';
    }

    final l1 = line('Przerwy w oddechu (aplikacja)', back.perHour(back.appEvents, back.minutes),
        side.perHour(side.appEvents, side.minutes));
    final l2 = line('Zdarzenia z aparatu', back.perHour(back.cpapEvents, back.cpapMinutes),
        side.perHour(side.cpapEvents, side.cpapMinutes));
    final snB = back.minutes < 20 ? null : back.snoreMin / back.minutes * 100;
    final snS = side.minutes < 20 ? null : side.snoreMin / side.minutes * 100;
    final positional = [l1, l2].whereType<String>().any((l) => l.contains('wyraźnie'));
    return Section(
      title: positional ? '🛏️ Oddech zależy od pozycji' : 'Podsumowanie',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final l in [l1, l2].whereType<String>())
          Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text(l, style: const TextStyle(height: 1.35))),
        if (snB != null && snS != null)
          Text('Chrapanie: na plecach ${snB.round()}% czasu, na bokach ${snS.round()}%.', style: const TextStyle(height: 1.35)),
        if (l1 == null && l2 == null && (snB == null || snS == null))
          const Text('Za mało snu na plecach albo na bokach, żeby porównać.', style: TextStyle(color: C.muted)),
        if (positional) ...[
          const SizedBox(height: 6),
          const Text(
            'To ważna informacja dla lekarza: przy bezdechu zależnym od pozycji pomaga czasem spanie na boku '
            '(np. poduszka lub plecak pozycyjny), także jako uzupełnienie CPAP.',
            style: TextStyle(fontSize: 12, color: C.muted, height: 1.4),
          ),
        ],
      ]),
    );
  }
}

const _cpapKinds = {'ev_oa', 'ev_ca', 'ev_h', 'ev_a'};

/// Zdarzenia oddechowe i chrapanie w każdej pozycji ciała (noce z opaską z ostatnich [days] dni).
Future<(Map<BodyPos, PosAgg>, int)> computePositionStats(int days) async {
  final out = {for (final p in BodyPos.values) p: PosAgg()};
  var used = 0;
  for (final n in await Db.instance.nights(limit: 400)) {
    if (n.id == null || DateTime.now().difference(n.start).inDays > days) continue;
    final ext = await Db.instance.ext(n.id!);
    final pos = [for (final r in ext) if (r.$2 == 'h10ps' && r.$3 != null) r]..sort((a, b) => a.$1.compareTo(b.$1));
    if (pos.isEmpty) continue;
    used++;
    final ms = await Db.instance.minutes(n.id!);
    final usage = {for (final r in ext) if (r.$2 == 'press' || r.$2 == 'leak') r.$1.millisecondsSinceEpoch ~/ 60000};
    BodyPos? at(DateTime t) {
      BodyPos? p;
      for (final r in pos) {
        if (r.$1.isAfter(t)) break;
        p = BodyPos.values[r.$3!.round().clamp(0, BodyPos.values.length - 1)];
      }
      return p;
    }

    for (final m in ms) {
      if (m.stage == Stage.wake) continue;
      final t = m.ts.subtract(const Duration(seconds: 30));
      final p = at(t);
      if (p == null) continue;
      final a = out[p]!;
      a.minutes += 1;
      a.appEvents += m.apneas;
      if (m.snore) a.snoreMin++;
      if (usage.contains(t.millisecondsSinceEpoch ~/ 60000)) a.cpapMinutes += 1;
    }
    for (final r in ext) {
      if (!_cpapKinds.contains(r.$2)) continue;
      final p = at(r.$1);
      if (p != null) out[p]!.cpapEvents++;
    }
  }
  return (out, used);
}
