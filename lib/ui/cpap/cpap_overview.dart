import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/fmt.dart';
import '../../cpap/cpap_data.dart';
import '../theme.dart';
import 'cpap_charts.dart';

/// Przegląd jak „Overview” w OSCAR: wykresy dzień po dniu w wybranym okresie.
class CpapOverview extends StatefulWidget {
  final List<CardDay> days; // od najstarszego, tylko dni z użyciem
  final ValueChanged<DateTime> onOpenDay;
  const CpapOverview({super.key, required this.days, required this.onOpenDay});

  @override
  State<CpapOverview> createState() => _CpapOverviewState();
}

class _CpapOverviewState extends State<CpapOverview> with AutomaticKeepAliveClientMixin {
  int range = 30; // dni; 0 = wszystko
  int? sel;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.days.isEmpty) {
      return const Center(child: Text('Brak danych z aparatu.', style: TextStyle(color: C.muted)));
    }
    final last = widget.days.last.date;
    final first = range == 0 ? widget.days.first.date : last.subtract(Duration(days: range - 1));
    final byDate = {for (final d in widget.days) d.date: d};
    // wszystkie dni kalendarzowe w okresie (puste = noc bez aparatu)
    final dates = <DateTime>[];
    for (var d = first; !d.isAfter(last); d = DateTime(d.year, d.month, d.day + 1)) {
      dates.add(d);
    }
    final ds = [for (final d in dates) byDate[d]];
    final used = ds.whereType<CardDay>().toList();
    final compliant = used.where((d) => d.compliant).length;
    final avgUse = used.isEmpty ? 0 : used.fold<int>(0, (a, d) => a + d.usageMin) / dates.length;
    final markers = <int>[];
    CardDay? prev;
    for (var i = 0; i < ds.length; i++) {
      final d = ds[i];
      if (d == null) continue;
      if (prev != null && prev.settingsKey != d.settingsKey) markers.add(i);
      prev = d;
    }
    List<double?> col(double? Function(CardDay) f) => [for (final d in ds) d == null ? null : f(d)];
    final s = sel != null && sel! < ds.length ? ds[sel!] : null;

    Widget chart(String title, String unit, List<List<double?>> stacks, List<Color> colors,
        {List<double?>? dots, double? thr, String Function(int i)? tip, List<String>? legend}) {
      final has = stacks.any((l) => l.any((x) => x != null && x > 0));
      if (!has) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Section(
          title: title,
          trailing: Text(unit, style: const TextStyle(fontSize: 11, color: C.muted)),
          padding: const EdgeInsets.fromLTRB(10, 12, 12, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DailyBars(
              days: dates,
              stacks: stacks,
              colors: colors,
              dots: dots,
              threshold: thr,
              selected: sel,
              markers: markers,
              onSelect: (i) => setState(() => sel = i),
            ),
            if (legend != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(spacing: 10, children: [
                  for (var i = 0; i < legend.length; i++)
                    Text('■ ${legend[i]}', style: TextStyle(fontSize: 11, color: i < colors.length ? colors[i] : Colors.white)),
                ]),
              ),
            if (sel != null && tip != null && sel! < dates.length)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${shortDate(dates[sel!])}: ${tip(sel!)}', style: const TextStyle(fontSize: 12)),
              ),
          ]),
        ),
      );
    }

    String v1(double? x, [int d = 1]) => x == null ? '—' : x.toStringAsFixed(d);

    return ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 32), children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final (n, t) in [(14, '2 tyg.'), (30, 'Miesiąc'), (90, '3 mies.'), (182, '6 mies.'), (365, 'Rok'), (0, 'Wszystko')])
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(t),
                selected: range == n,
                onSelected: (_) => setState(() {
                  range = n;
                  sel = null;
                }),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 8),
      TileGrid(columns: 3, children: [
        StatTile(label: 'Noce z aparatem', value: '${used.length}/${dates.length}'),
        StatTile(
            label: 'Przestrzeganie',
            value: '${(compliant / max(1, dates.length) * 100).round()}%',
            sub: '≥ 4 h',
            color: compliant / max(1, dates.length) >= 0.7 ? C.gas : C.moon),
        StatTile(label: 'Śr. użycie', value: durHM(avgUse), sub: 'na noc'),
      ]),
      if (s != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: FilledButton.tonalIcon(
            onPressed: () => widget.onOpenDay(s.date),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: Text('Otwórz ${dayLabel(s.date)}'),
          ),
        ),
      const SizedBox(height: 10),
      chart('Czas użycia', 'godziny', [col((d) => d.usageMin / 60)], [const Color(0xFF5EC8F2)],
          thr: 4, tip: (i) => ds[i] == null ? 'bez aparatu' : durHM(ds[i]!.usageMin)),
      chart(
        'AHI i rodzaje zdarzeń',
        'na godzinę',
        [col((d) => d.oai), col((d) => d.cai), col((d) => d.uai), col((d) => d.hi)],
        [cpapEventColor('oa'), cpapEventColor('ca'), cpapEventColor('ua'), cpapEventColor('h')],
        dots: col((d) => d.ahi),
        thr: 5,
        legend: ['OA', 'CA', 'UA', 'H', '• AHI'],
        tip: (i) => ds[i] == null
            ? '—'
            : 'AHI ${v1(ds[i]!.ahi)} · OA ${v1(ds[i]!.oai)} · CA ${v1(ds[i]!.cai)} · H ${v1(ds[i]!.hi)}',
      ),
      chart('Nieszczelność', 'L/min', [col((d) => d.leak95)], [cpapSignalColor('leak')],
          dots: col((d) => d.leak50),
          thr: 24,
          legend: ['95%', '• mediana'],
          tip: (i) => ds[i] == null ? '—' : '95%: ${v1(ds[i]!.leak95)} · mediana ${v1(ds[i]!.leak50)} · max ${v1(ds[i]!.leakMax)}'),
      chart('Ciśnienie', 'cmH₂O', [col((d) => d.press95)], [cpapSignalColor('press')],
          dots: col((d) => d.press50),
          legend: ['95%', '• mediana'],
          tip: (i) => ds[i] == null ? '—' : '95%: ${v1(ds[i]!.press95)} · mediana ${v1(ds[i]!.press50)}'),
      chart('Częstość oddechu', '/min', [col((d) => d.rr50)], [cpapSignalColor('rr')],
          tip: (i) => ds[i] == null ? '—' : 'mediana ${v1(ds[i]!.rr50, 0)} · 95% ${v1(ds[i]!.rr95, 0)}'),
      chart('Objętość oddechowa', 'mL', [col((d) => d.tv50)], [cpapSignalColor('tv')],
          tip: (i) => ds[i] == null ? '—' : 'mediana ${v1(ds[i]!.tv50, 0)} · 95% ${v1(ds[i]!.tv95, 0)}'),
      chart('Wentylacja minutowa', 'L/min', [col((d) => d.mv50)], [cpapSignalColor('mv')],
          tip: (i) => ds[i] == null ? '—' : 'mediana ${v1(ds[i]!.mv50)} · 95% ${v1(ds[i]!.mv95)}'),
      chart('RERA (wybudzenia oddechowe)', 'na godzinę', [col((d) => d.rin)], [cpapEventColor('rera')],
          tip: (i) => ds[i] == null ? '—' : v1(ds[i]!.rin)),
      chart('SpO₂ (pulsoksymetr)', '%', [col((d) => d.spo250)], [cpapSignalColor('spo2')],
          tip: (i) => ds[i] == null ? '—' : v1(ds[i]!.spo250, 0)),
      if (markers.isNotEmpty)
        Section(
          title: 'Zmiany ustawień',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final i in markers)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text('${shortDate(dates[i])}: ${_settingsText(ds[i]!)}', style: const TextStyle(fontSize: 13)),
              ),
            const SizedBox(height: 4),
            const Text('Żółte przerywane linie na wykresach = dzień zmiany ustawień.',
                style: TextStyle(fontSize: 11, color: C.muted)),
          ]),
        ),
    ]);
  }

  String _settingsText(CardDay d) {
    final p = d.isAuto
        ? '${d.setMin?.toStringAsFixed(1) ?? '—'}–${d.setMax?.toStringAsFixed(1) ?? '—'} cmH₂O'
        : '${d.setPress?.toStringAsFixed(1) ?? '—'} cmH₂O';
    return '${d.modeName} $p, EPR ${d.eprOn ? d.eprLevel : 'wył.'}, rampa ${d.rampOn ? '${d.rampTime} min' : 'wył.'}, '
        'nawilżacz ${d.humOn ? d.humLevel : 'wył.'}';
  }
}

/// Statystyki jak w OSCAR: wiersze = miary, kolumny = okresy.
class CpapStatsView extends StatelessWidget {
  final List<CardDay> days;
  const CpapStatsView({super.key, required this.days});

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) return const Center(child: Text('Brak danych z aparatu.', style: TextStyle(color: C.muted)));
    final last = days.last.date;
    final periods = <(String, int)>[('Ostatnia', 1), ('7 dni', 7), ('30 dni', 30), ('6 mies.', 182), ('Rok', 365), ('Całość', 0)];
    List<CardDay> sel(int n) =>
        n == 0 ? days : days.where((d) => !d.date.isBefore(last.subtract(Duration(days: n - 1)))).toList();
    int calDays(int n) => n == 0 ? last.difference(days.first.date).inDays + 1 : n;

    // średnia ważona czasem użycia (jak OSCAR dla wskaźników na godzinę)
    String wavg(List<CardDay> ds, double? Function(CardDay) f, [int dec = 2]) {
      var s = 0.0, w = 0.0;
      for (final d in ds) {
        final v = f(d);
        if (v == null) continue;
        s += v * d.usageMin;
        w += d.usageMin;
      }
      return w == 0 ? '—' : (s / w).toStringAsFixed(dec);
    }

    String avg(List<CardDay> ds, double? Function(CardDay) f, [int dec = 1]) {
      final v = ds.map(f).whereType<double>().toList();
      return v.isEmpty ? '—' : (v.reduce((a, b) => a + b) / v.length).toStringAsFixed(dec);
    }

    final rows = <(String, String Function(List<CardDay>, int))>[
      ('Noce z aparatem', (ds, n) => '${ds.length}/${calDays(n)}'),
      ('Przestrzeganie ≥ 4 h', (ds, n) => '${(ds.where((d) => d.compliant).length / max(1, calDays(n)) * 100).round()}%'),
      ('Śr. użycie (noce z aparatem)', (ds, n) => ds.isEmpty ? '—' : durHM(ds.fold<int>(0, (a, d) => a + d.usageMin) / ds.length)),
      ('Śr. użycie (wszystkie noce)', (ds, n) => durHM(ds.fold<int>(0, (a, d) => a + d.usageMin) / max(1, calDays(n)))),
      ('AHI', (ds, n) => wavg(ds, (d) => d.ahi)),
      ('Bezdechy obturacyjne (OAI)', (ds, n) => wavg(ds, (d) => d.oai)),
      ('Bezdechy centralne (CAI)', (ds, n) => wavg(ds, (d) => d.cai)),
      ('Bezdechy niesklas. (UAI)', (ds, n) => wavg(ds, (d) => d.uai)),
      ('Spłycenia (HI)', (ds, n) => wavg(ds, (d) => d.hi)),
      ('RERA', (ds, n) => wavg(ds, (d) => d.rin)),
      ('Nieszczelność mediana', (ds, n) => avg(ds, (d) => d.leak50)),
      ('Nieszczelność 95%', (ds, n) => avg(ds, (d) => d.leak95)),
      ('Noce z nieszcz. 95% > 24', (ds, n) => '${ds.where((d) => (d.leak95 ?? 0) > 24).length}'),
      ('Ciśnienie mediana', (ds, n) => avg(ds, (d) => d.press50)),
      ('Ciśnienie 95%', (ds, n) => avg(ds, (d) => d.press95)),
      ('Ciśnienie maks.', (ds, n) => avg(ds, (d) => d.pressMax)),
      ('Częstość oddechu', (ds, n) => avg(ds, (d) => d.rr50, 0)),
      ('Objętość oddechowa (mL)', (ds, n) => avg(ds, (d) => d.tv50, 0)),
      ('Wentylacja minutowa', (ds, n) => avg(ds, (d) => d.mv50)),
      ('Zdjęcia maski / noc', (ds, n) => avg(ds, (d) => d.maskSessions.length.toDouble())),
      if (days.any((d) => d.spo250 != null)) ('SpO₂ mediana', (ds, n) => avg(ds, (d) => d.spo250, 0)),
    ];
    final data = [for (final p in periods) sel(p.$2)];
    return ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 32), children: [
      Card(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 18,
            headingRowHeight: 40,
            dataRowMinHeight: 34,
            dataRowMaxHeight: 40,
            columns: [
              const DataColumn(label: Text('')),
              for (final p in periods) DataColumn(label: Text(p.$1, style: const TextStyle(fontWeight: FontWeight.w700)), numeric: true),
            ],
            rows: [
              for (final (label, f) in rows)
                DataRow(cells: [
                  DataCell(Text(label, style: const TextStyle(fontSize: 13))),
                  for (var i = 0; i < periods.length; i++) DataCell(Text(f(data[i], periods[i].$2), style: const TextStyle(fontSize: 13))),
                ]),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Ostatni dzień z aparatem: ${dayLabel(last)}. Wskaźniki na godzinę (AHI itd.) są średnią ważoną czasem użycia, '
        'pozostałe — średnią z nocy. Ciśnienie, nieszczelność i oddech to wartości z podsumowań aparatu (mediana, 95. percentyl).',
        style: const TextStyle(fontSize: 11, color: C.muted, height: 1.4),
      ),
    ]);
  }
}
