import 'package:flutter/material.dart';

import '../core/bus.dart';
import '../core/db.dart';
import '../core/fmt.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../core/stats_util.dart';
import 'charts.dart';
import 'theme.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  List<Night> all = [];
  List<SoundEvent> fartEvents = [];
  int range = 30; // 7, 30, 0 = wszystkie
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    dataVersion.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    dataVersion.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final n = await Db.instance.nights();
    final f = await Db.instance.allEvents(SoundType.fart);
    if (mounted) {
      setState(() {
        all = n;
        fartEvents = f.where((e) => e.counts).toList();
        loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!loaded) return const Center(child: CircularProgressIndicator());
    final nights = (range == 0 ? all : all.take(range).toList()).reversed.toList(); // chronologicznie
    final goal = Settings.instance.sleepGoalMin;

    final header = Row(children: [
      Expanded(
        child: Text('Statystyki', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
      ),
      SegmentedButton<int>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 7, label: Text('7')),
          ButtonSegment(value: 30, label: Text('30')),
          ButtonSegment(value: 0, label: Text('Wszystkie')),
        ],
        selected: {range},
        onSelectionChanged: (v) => setState(() => range = v.first),
      ),
    ]);

    if (nights.isEmpty) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        header,
        const SizedBox(height: 60),
        const Text('Statystyki pojawią się po pierwszej nocy.',
            textAlign: TextAlign.center, style: TextStyle(color: C.muted)),
      ]);
    }

    final ids = nights.map((n) => n.id).toSet();
    final totalFarts = nights.fold<int>(0, (a, n) => a + n.fartCount);
    final record = nights.reduce((a, b) => a.fartCount >= b.fartCount ? a : b);
    final debt = sleepDebtMin(all, goal);
    final impacts = tagImpacts(nights).where((t) => t.nights >= 1).toList();

    // Rozkład bąków wg godziny zegarowej (20:00 → 10:00)
    const hourOrder = [20, 21, 22, 23, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
    final byHour = List<double>.filled(hourOrder.length, 0);
    for (final e in fartEvents.where((e) => ids.contains(e.nightId))) {
      final i = hourOrder.indexOf(e.ts.hour);
      if (i >= 0) byHour[i]++;
    }
    var peak = 0;
    for (var i = 1; i < byHour.length; i++) {
      if (byHour[i] > byHour[peak]) peak = i;
    }

    // Światło a sen
    final buckets = <String, List<Night>>{};
    for (final n in nights) {
      final b = lightBucket(n);
      if (b.isEmpty) continue;
      buckets.putIfAbsent(b, () => []).add(n);
    }

    final labels = [for (final n in nights) shortDate(n.start)];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        header,
        const SizedBox(height: 16),
        TileGrid(columns: 3, children: [
          StatTile(label: 'Średnio / noc', value: '💨 ${avg(nights.map((n) => n.fartCount)).toStringAsFixed(1)}', color: C.gas),
          StatTile(label: 'Razem', value: '$totalFarts', sub: '${nights.length} nocy', color: C.gas),
          StatTile(label: 'Rekord', value: '${record.fartCount}', sub: dayLabel(record.start), color: C.moon),
          StatTile(label: 'Sen średnio', value: durHM(avg(nights.map((n) => n.durationMin)))),
          StatTile(label: 'Ocena średnio', value: avg(nights.map((n) => n.score)).round().toString()),
          StatTile(
            label: debt >= 0 ? 'Dług snu' : 'Nadwyżka',
            value: durHM(debt.abs()),
            color: debt > 120 ? C.danger : C.gas,
          ),
        ]),
        const SizedBox(height: 12),
        Section(
          title: 'Bąki w kolejnych nocach',
          child: BarSeriesChart(values: nights.map((n) => n.fartCount.toDouble()).toList(), labels: labels),
        ),
        const SizedBox(height: 12),
        Section(
          title: 'Długość snu',
          trailing: Text('cel ${durHM(goal)}', style: const TextStyle(color: C.moon, fontSize: 12)),
          child: LineSeriesChart(
            values: nights.map((n) => n.durationMin / 60.0).toList(),
            labels: labels,
            color: C.light,
            goal: goal / 60.0,
          ),
        ),
        const SizedBox(height: 12),
        Section(
          title: 'Ocena snu',
          child: LineSeriesChart(values: nights.map((n) => n.score.toDouble()).toList(), labels: labels, color: C.gas),
        ),
        const SizedBox(height: 12),
        Section(
          title: 'O której najczęściej?',
          trailing: byHour[peak] > 0
              ? Text('szczyt ${two(hourOrder[peak])}:00', style: const TextStyle(color: C.gas, fontWeight: FontWeight.w700))
              : null,
          child: BarSeriesChart(values: byHour, labels: [for (final h in hourOrder) '$h'], highlight: byHour[peak] > 0 ? peak : null),
        ),
        const SizedBox(height: 12),
        Section(
          title: 'Co wpływa na wynik? (tagi)',
          child: impacts.isEmpty
              ? const Text('Dodawaj tagi przed snem (#fasola, #piwo…), a tu zobaczysz, co daje najwięcej wiatrów.',
                  style: TextStyle(color: C.muted))
              : Column(children: [
                  for (final t in impacts)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('#${t.tag}', style: const TextStyle(fontWeight: FontWeight.w700)),
                            Text('${t.nights} ${plural(t.nights, 'noc', 'noce', 'nocy')} · '
                                '${t.fartsWith.toStringAsFixed(1)} vs ${t.fartsWithout.toStringAsFixed(1)} bąków',
                                style: const TextStyle(fontSize: 12, color: C.muted)),
                          ]),
                        ),
                        _delta('${t.fartDeltaPct >= 0 ? '+' : ''}${t.fartDeltaPct.round()}% 💨',
                            t.fartDeltaPct > 10 ? C.danger : (t.fartDeltaPct < -10 ? C.gas : C.muted)),
                        const SizedBox(width: 6),
                        _delta('${t.scoreDelta >= 0 ? '+' : ''}${t.scoreDelta.round()} pkt',
                            t.scoreDelta < -3 ? C.danger : (t.scoreDelta > 3 ? C.gas : C.muted)),
                      ]),
                    ),
                  const SizedBox(height: 4),
                  const Text('Porównanie średnich nocy z tagiem i bez — przy kilku nocach to jeszcze ciekawostka, nie nauka.',
                      style: TextStyle(fontSize: 11, color: C.muted)),
                ]),
        ),
        const SizedBox(height: 12),
        Section(
          title: 'Światło a sen',
          child: buckets.isEmpty
              ? const Text('Brak pomiarów światła — zmierz je albo zaznacz przed snem.', style: TextStyle(color: C.muted))
              : Column(children: [
                  for (final b in ['dark', 'dim', 'bright'])
                    if (buckets[b] != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(lightBucketLabel(b), style: const TextStyle(fontWeight: FontWeight.w700)),
                              Text('${buckets[b]!.length} ${plural(buckets[b]!.length, 'noc', 'noce', 'nocy')}',
                                  style: const TextStyle(fontSize: 12, color: C.muted)),
                            ]),
                          ),
                          _delta('ocena ${avg(buckets[b]!.map((n) => n.score)).round()}', C.text),
                          const SizedBox(width: 6),
                          _delta('${durHM(avg(buckets[b]!.map((n) => n.durationMin)))}', C.light),
                          const SizedBox(width: 6),
                          _delta('💨 ${avg(buckets[b]!.map((n) => n.fartCount)).toStringAsFixed(1)}', C.gas),
                        ]),
                      ),
                ]),
        ),
        const SizedBox(height: 12),
        Section(
          title: 'Przerwy w oddechu 🫁 (na godzinę snu)',
          trailing: Text('norma < 5', style: const TextStyle(color: C.muted, fontSize: 12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            BarSeriesChart(
              values: nights.map((n) => n.apneaIndex).toList(),
              labels: labels,
              color: C.danger,
              height: 120,
            ),
            const SizedBox(height: 6),
            Text(
              'Średnio ${avg(nights.where((n) => n.durationMin >= 120).map((n) => n.apneaIndex)).toStringAsFixed(1)}/h — '
              '${apneaCategory(avg(nights.where((n) => n.durationMin >= 120).map((n) => n.apneaIndex)))}. '
              'Orientacyjnie, nie diagnoza.',
              style: const TextStyle(fontSize: 12, color: C.muted),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Section(
          title: 'Chrapanie',
          child: BarSeriesChart(
            values: nights.map((n) => n.snoreMin.toDouble()).toList(),
            labels: labels,
            color: C.light,
            height: 110,
          ),
        ),
      ],
    );
  }

  Widget _delta(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(10)),
        child: Text(t, style: TextStyle(fontSize: 12, color: c, fontWeight: FontWeight.w600)),
      );
}
