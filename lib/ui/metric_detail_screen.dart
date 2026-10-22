import 'package:flutter/material.dart';

import '../core/fmt.dart';
import '../core/metrics.dart';
import '../core/models.dart';
import 'charts.dart';
import 'night_detail_screen.dart';
import 'theme.dart';

/// Ekran „Więcej” jednej statystyki: duży wykres, podsumowanie, opis i lista nocy.
class MetricDetailScreen extends StatefulWidget {
  final Metric metric;
  final List<Night> chrono; // wszystkie noce, od najstarszej
  final Period initial;
  const MetricDetailScreen({super.key, required this.metric, required this.chrono, required this.initial});

  @override
  State<MetricDetailScreen> createState() => _MetricDetailScreenState();
}

class _MetricDetailScreenState extends State<MetricDetailScreen> {
  late Period period = widget.initial;

  List<Night> _inRange() {
    final c = widget.chrono;
    switch (period) {
      case Period.days:
        return c.length > 14 ? c.sublist(c.length - 14) : c;
      case Period.weeks:
        final from = DateTime.now().subtract(const Duration(days: 7 * 12));
        return c.where((n) => n.start.isAfter(from)).toList();
      case Period.months:
        final now = DateTime.now();
        final from = DateTime(now.year - 1, now.month, now.day);
        return c.where((n) => n.start.isAfter(from)).toList();
      case Period.all:
        return c;
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.metric;
    final pts = metricSeries(m, widget.chrono, period);
    final nights = _inRange();
    final sum = summarizeMetric(m, nights);
    final withValue = nights.where((n) => m.value(n) != null).toList().reversed.toList();
    final enough = widget.chrono.where((n) => m.value(n) != null).length >= m.minNights;

    Widget chart() {
      if (!enough) {
        return SizedBox(
          height: 200,
          child: Center(
            child: Text('Ten wykres wymaga ${m.minNights} nocy danych.',
                textAlign: TextAlign.center, style: const TextStyle(color: C.text, fontSize: 15)),
          ),
        );
      }
      return m.kind == ChartKind.bar
          ? BarSeriesChart(
              values: pts.map((p) => p.value ?? 0).toList(),
              labels: pts.map((p) => p.label).toList(),
              color: m.color,
              height: 230,
              fmt: m.fmt,
            )
          : LineSeriesChart(
              values: pts.map((p) => p.value).toList(),
              labels: pts.map((p) => p.label).toList(),
              color: m.color,
              height: 230,
              fmt: m.fmt,
              zeroBased: m.zeroBased,
            );
    }

    String f(double? v) => v == null ? '—' : m.fmt(v);

    return Scaffold(
      appBar: AppBar(title: Text(m.title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          PeriodTabs(value: period, onChanged: (p) => setState(() => period = p)),
          const SizedBox(height: 12),
          Section(child: chart()),
          const SizedBox(height: 12),
          TileGrid(columns: 2, children: [
            StatTile(label: 'Średnio', value: f(sum.avgV), color: m.color),
            StatTile(label: 'Ostatnia noc', value: f(sum.lastV)),
            StatTile(label: 'Najniżej', value: f(sum.minV)),
            StatTile(label: 'Najwyżej', value: f(sum.maxV)),
          ]),
          if (sum.best != null && sum.worst != null && sum.best != sum.worst) ...[
            const SizedBox(height: 8),
            TileGrid(columns: 2, children: [
              _nightTile('Najlepsza noc', sum.best!, C.gas),
              _nightTile('Najsłabsza noc', sum.worst!, C.danger),
            ]),
          ],
          const SizedBox(height: 12),
          Section(title: 'O tej statystyce', child: Text(m.about, style: const TextStyle(height: 1.4))),
          const SizedBox(height: 12),
          Section(
            title: 'Noce',
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(children: [
              if (withValue.isEmpty) const Text('Brak danych w tym okresie.', style: TextStyle(color: C.muted)),
              for (final n in withValue)
                InkWell(
                  onTap: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => NightDetailScreen(nightId: n.id!))),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(children: [
                      Expanded(child: Text(dayLabel(nightDay(n)))),
                      Text(m.fmt(m.value(n)!), style: TextStyle(fontWeight: FontWeight.w700, color: m.color)),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right, size: 18, color: C.muted),
                    ]),
                  ),
                ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _nightTile(String label, Night n, Color c) => InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => NightDetailScreen(nightId: n.id!))),
        child: StatTile(label: label, value: widget.metric.fmt(widget.metric.value(n)!), sub: dayLabel(nightDay(n)), color: c),
      );
}

/// Zakładki okresu jak w Sleep Cycle.
class PeriodTabs extends StatelessWidget {
  final Period value;
  final ValueChanged<Period> onChanged;
  const PeriodTabs({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        for (final p in Period.values)
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(p),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: p == value ? const Color(0xFF5EC8F2) : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Text(p.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: p == value ? C.bg : C.muted,
                    )),
              ),
            ),
          ),
      ]),
    );
  }
}
