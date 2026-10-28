import 'package:flutter/material.dart';

import '../core/bus.dart';
import '../core/db.dart';
import '../core/fmt.dart';
import '../core/metrics.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../core/stats_util.dart';
import '../core/weather_impact.dart';
import 'charts.dart';
import 'metric_detail_screen.dart';
import 'theme.dart';

/// Statystyki w układzie Sleep Cycle: zakładki okresu i karta na każdą miarę z „Więcej ›”.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  List<Night> chrono = [];
  List<SoundEvent> fartEvents = [];
  Period period = Period.days;
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    dataVersion.addListener(_load);
    Settings.instance.addListener(_refresh);
    _load();
  }

  @override
  void dispose() {
    dataVersion.removeListener(_load);
    Settings.instance.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final n = await Db.instance.nights();
    final f = await Db.instance.allEvents(SoundType.fart);
    if (mounted) {
      setState(() {
        chrono = n.reversed.toList();
        fartEvents = f.where((e) => e.counts).toList();
        loaded = true;
      });
    }
  }

  List<Night> _rangeNights() {
    switch (period) {
      case Period.days:
        return chrono.length > 14 ? chrono.sublist(chrono.length - 14) : chrono;
      case Period.weeks:
        final from = DateTime.now().subtract(const Duration(days: 84));
        return chrono.where((n) => n.start.isAfter(from)).toList();
      case Period.months:
        final now = DateTime.now();
        return chrono.where((n) => n.start.isAfter(DateTime(now.year - 1, now.month, now.day))).toList();
      case Period.all:
        return chrono;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!loaded) return const Center(child: CircularProgressIndicator());
    final title = Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text('Statystyki',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
    );
    if (chrono.isEmpty) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        title,
        PeriodTabs(value: period, onChanged: (p) => setState(() => period = p)),
        const SizedBox(height: 60),
        const Text('Statystyki pojawią się po pierwszej nocy.',
            textAlign: TextAlign.center, style: TextStyle(color: C.muted)),
      ]);
    }

    final showFarts = Settings.instance.detectFarts;
    final metrics = buildMetrics(
      regularityScores(chrono),
      farts: showFarts,
      cpap: chrono.any((n) => n.cpapAhi != null),
      breath: chrono.any((n) => n.breathRate != null),
      weather: chrono.any((n) => n.wTemp != null),
    );
    final nights = _rangeNights();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        title,
        PeriodTabs(value: period, onChanged: (p) => setState(() => period = p)),
        const SizedBox(height: 16),
        for (final m in metrics) ...[
          _metricCard(m),
          const SizedBox(height: 12),
        ],
        ..._extras(nights, showFarts),
      ],
    );
  }

  Widget _metricCard(Metric m) {
    final pts = metricSeries(m, chrono, period);
    final enough = chrono.where((n) => m.value(n) != null).length >= m.minNights;
    final hasAny = pts.any((p) => p.value != null);
    Widget body;
    if (!enough) {
      body = SizedBox(
        height: 110,
        child: Center(
          child: Text('Ten wykres wymaga ${m.minNights} nocy danych.',
              textAlign: TextAlign.center, style: const TextStyle(color: C.text, fontSize: 15)),
        ),
      );
    } else if (!hasAny) {
      body = const SizedBox(
        height: 80,
        child: Center(child: Text('Brak pomiarów w tym okresie.', style: TextStyle(color: C.muted))),
      );
    } else if (m.kind == ChartKind.bar) {
      body = BarSeriesChart(
        values: pts.map((p) => p.value ?? 0).toList(),
        labels: pts.map((p) => p.label).toList(),
        color: m.color,
        height: 150,
        fmt: m.fmt,
      );
    } else {
      body = LineSeriesChart(
        values: pts.map((p) => p.value).toList(),
        labels: pts.map((p) => p.label).toList(),
        color: m.color,
        height: 150,
        fmt: m.fmt,
        zeroBased: m.zeroBased,
      );
    }

    return Section(
      title: m.title,
      trailing: _moreButton(enough && hasAny
          ? () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => MetricDetailScreen(metric: m, chrono: chrono, initial: period)))
          : null),
      child: body,
    );
  }

  Widget _moreButton(VoidCallback? onTap) => Opacity(
        opacity: onTap == null ? 0.35 : 1,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(14)),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Text('Więcej', style: TextStyle(fontSize: 12, color: Color(0xFF5EC8F2), fontWeight: FontWeight.w600)),
              Icon(Icons.chevron_right, size: 16, color: Color(0xFF5EC8F2)),
            ]),
          ),
        ),
      );

  /// Sekcje własne Rytmu Snu (pod statystykami w stylu Sleep Cycle).
  List<Widget> _extras(List<Night> nights, bool showFarts) {
    if (nights.isEmpty) return [];
    final ids = nights.map((n) => n.id).toSet();
    final totalFarts = nights.fold<int>(0, (a, n) => a + n.fartCount);
    final record = nights.reduce((a, b) => a.fartCount >= b.fartCount ? a : b);
    final debt = sleepDebtMin(chrono.reversed.toList(), Settings.instance.sleepGoalMin);
    final impacts = tagImpacts(nights, byFarts: showFarts);

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

    final buckets = <String, List<Night>>{};
    for (final n in nights) {
      final b = lightBucket(n);
      if (b.isNotEmpty) buckets.putIfAbsent(b, () => []).add(n);
    }
    final s = Settings.instance;
    final noiseBuckets = <String, List<Night>>{};
    for (final n in nights.where((n) => n.avgNoise != null)) {
      final db = s.spl(n.avgNoise!);
      final b = db <= 30 ? 'quiet' : (db <= 40 ? 'mid' : 'loud');
      noiseBuckets.putIfAbsent(b, () => []).add(n);
    }
    const noiseLabels = {'quiet': 'Cicho (≤30 dB)', 'mid': 'Umiarkowanie (30–40 dB)', 'loud': 'Głośno (>40 dB)'};

    Widget compareRow(String label, List<Night> ns) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
                Text('${ns.length} ${plural(ns.length, 'noc', 'noce', 'nocy')}',
                    style: const TextStyle(fontSize: 12, color: C.muted)),
              ]),
            ),
            _delta('${avg(ns.map((n) => n.score)).round()}%', C.text),
            const SizedBox(width: 6),
            _delta(durHM(avg(ns.map((n) => n.durationMin))), C.light),
            if (showFarts) ...[
              const SizedBox(width: 6),
              _delta('FF ${avg(ns.map((n) => n.fartCount)).toStringAsFixed(1)}', C.gas),
            ],
          ]),
        );

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 10),
        child: Text(showFarts ? 'Więcej o FF i nawykach' : 'Więcej o nawykach',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
      ),
      TileGrid(columns: 3, children: [
        if (showFarts) ...[
          StatTile(label: 'Średnio / noc', value: 'FF ${avg(nights.map((n) => n.fartCount)).toStringAsFixed(1)}', color: C.gas),
          StatTile(label: 'Razem', value: '$totalFarts', sub: '${nights.length} nocy', color: C.gas),
          StatTile(label: 'Rekord', value: '${record.fartCount}', sub: dayLabel(nightDay(record)), color: C.moon),
        ],
        StatTile(
          label: debt >= 0 ? 'Dług snu (14 dni)' : 'Nadwyżka snu',
          value: durHM(debt.abs()),
          color: debt > 120 ? C.danger : C.gas,
        ),
        StatTile(
          label: 'Przerwy w oddechu',
          value: '${avg(nights.where((n) => n.durationMin >= 120).map((n) => n.apneaIndex)).toStringAsFixed(1)}/h',
          sub: apneaCategory(avg(nights.where((n) => n.durationMin >= 120).map((n) => n.apneaIndex))),
          color: C.danger,
        ),
        StatTile(
          label: 'Hałas śr.',
          value: nights.any((n) => n.avgNoise != null)
              ? '${avg(nights.where((n) => n.avgNoise != null).map((n) => s.spl(n.avgNoise!))).round()} dB'
              : '—',
          color: const Color(0xFF3DDC97),
        ),
      ]),
      if (showFarts) ...[
      const SizedBox(height: 12),
      Section(
        title: 'FF — o której najczęściej?',
        trailing: byHour[peak] > 0
            ? Text('szczyt ${two(hourOrder[peak])}:00', style: const TextStyle(color: C.gas, fontWeight: FontWeight.w700))
            : null,
        child: BarSeriesChart(
          values: byHour,
          labels: [for (final h in hourOrder) '$h'],
          highlight: byHour[peak] > 0 ? peak : null,
          showAverage: false,
        ),
      ),
      ],
      const SizedBox(height: 12),
      Section(
        title: 'Co wpływa na wynik? (tagi)',
        child: impacts.isEmpty
            ? const Text('Dodawaj tagi przed snem (#kawa, #piwo, #trening…), a tu zobaczysz, jak wpływają na sen.',
                style: TextStyle(color: C.muted))
            : Column(children: [
                for (final t in impacts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('#${t.tag}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text(
                              showFarts
                                  ? '${t.nights} ${plural(t.nights, 'noc', 'noce', 'nocy')} · '
                                      '${t.fartsWith.toStringAsFixed(1)} vs ${t.fartsWithout.toStringAsFixed(1)} FF'
                                  : '${t.nights} ${plural(t.nights, 'noc', 'noce', 'nocy')} · '
                                      'ocena ${t.scoreWith.round()}% vs ${t.scoreWithout.round()}%',
                              style: const TextStyle(fontSize: 12, color: C.muted)),
                        ]),
                      ),
                      if (showFarts) ...[
                        _delta('${t.fartDeltaPct >= 0 ? '+' : ''}${t.fartDeltaPct.round()}% FF',
                            t.fartDeltaPct > 10 ? C.danger : (t.fartDeltaPct < -10 ? C.gas : C.muted)),
                        const SizedBox(width: 6),
                      ],
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
                  if (buckets[b] != null) compareRow(lightBucketLabel(b), buckets[b]!),
              ]),
      ),
      const SizedBox(height: 12),
      Section(
        title: 'Hałas a sen',
        child: noiseBuckets.isEmpty
            ? const Text('Pomiar hałasu pojawi się po pierwszej nocy z nową wersją.', style: TextStyle(color: C.muted))
            : Column(children: [
                for (final b in ['quiet', 'mid', 'loud'])
                  if (noiseBuckets[b] != null) compareRow(noiseLabels[b]!, noiseBuckets[b]!),
              ]),
      ),
      const SizedBox(height: 12),
      _weatherSection(showFarts),
    ];
  }

  /// Pogoda a sen: noce z najniższą vs najwyższą 1/3 wartości każdego czynnika (wszystkie noce).
  Widget _weatherSection(bool showFarts) {
    final s = Settings.instance;
    final withWeather = chrono.where((n) => n.wTemp != null).length;
    Widget body;
    if (!s.weatherReady && withWeather == 0) {
      body = const Text(
          'Ustaw swoją miejscowość w Ustawieniach → Pogoda. Aplikacja pobierze warunki dla każdej nocy '
          '(także wstecz) i pokaże, jak temperatura, ciśnienie, wilgotność, wiatr czy Księżyc łączą się z Twoim snem.',
          style: TextStyle(color: C.muted));
    } else {
      final impacts = weatherImpacts(chrono, farts: showFarts);
      if (impacts.isEmpty) {
        body = Text(
            'Potrzeba co najmniej 6 nocy z danymi pogodowymi (teraz: $withWeather). '
            'Pogoda pobiera się automatycznie po każdej nocy.',
            style: const TextStyle(color: C.muted));
      } else {
        final top = impacts.first;
        final e = top.score;
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (top.strength >= 0.15)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(14)),
              child: Text(
                '${top.factor.emoji} Najmocniej: ${top.factor.label.toLowerCase()} — '
                '${e.highBetter ? top.factor.highWord : top.factor.lowWord} = lepszy sen '
                '(ocena ${e.outcome.fmtDelta(e.highBetter ? e.delta : -e.delta)}, ${strengthWord(e.r)}).',
                style: const TextStyle(fontWeight: FontWeight.w600, height: 1.35),
              ),
            ),
          for (final f in impacts) _factorRow(f),
          const SizedBox(height: 6),
          const Text(
            'Porównanie nocy z najniższą i najwyższą 1/3 wartości (opady: noce suche vs deszczowe). Korelacja to nie '
            'przyczyna — przy kilkunastu nocach traktuj to jako wskazówkę. Pogoda: Open-Meteo, Księżyc liczony lokalnie.',
            style: TextStyle(fontSize: 11, color: C.muted),
          ),
        ]);
      }
    }
    return Section(title: 'Pogoda a sen 🌦️', child: body);
  }

  Widget _factorRow(FactorImpact f) {
    final f0 = f.factor;
    final range = f0.id == 'rain'
        ? 'sucho vs deszcz'
        : '≤ ${f0.fmt(f.lowMax)} vs ≥ ${f0.fmt(f.highMin)}';
    Color col(OutcomeEffect e) =>
        e.r.abs() < 0.15 ? C.muted : (e.highBetter ? C.gas : C.danger);
    final shown = f.effects.where((e) => e.outcome.id == 'score' || e.outcome.id == 'sleep' || e.r.abs() >= 0.3);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('${f0.emoji} ${f0.label}', style: const TextStyle(fontWeight: FontWeight.w700)),
          const Spacer(),
          Text('${f.nights} nocy · $range', style: const TextStyle(fontSize: 11, color: C.muted)),
        ]),
        const SizedBox(height: 5),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final e in shown)
            _delta('${f0.highWord}: ${e.outcome.label} ${e.outcome.fmtDelta(e.delta)}', col(e)),
        ]),
        const SizedBox(height: 3),
        Text('${strengthWord(f.score.r)} z oceną snu (r = ${f.score.r.toStringAsFixed(2).replaceAll('.', ',')})',
            style: const TextStyle(fontSize: 11, color: C.muted)),
      ]),
    );
  }

  Widget _delta(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(10)),
        child: Text(t, style: TextStyle(fontSize: 12, color: c, fontWeight: FontWeight.w600)),
      );
}
