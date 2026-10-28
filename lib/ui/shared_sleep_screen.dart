import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:koofr_sync/koofr_sync.dart';

import '../core/cloud.dart';
import '../core/fmt.dart';
import '../core/models.dart';
import 'charts.dart';
import 'theme.dart';

/// Sen innej osoby (tylko do odczytu), pobrany i odszyfrowany z Koofr.
/// Nic nie jest zapisywane na telefonie — po cofnięciu zgody dane znikają.
class SharedSleepScreen extends StatefulWidget {
  final Member owner;
  const SharedSleepScreen({super.key, required this.owner});

  @override
  State<SharedSleepScreen> createState() => _SharedSleepScreenState();
}

class _SharedSleepScreenState extends State<SharedSleepScreen> {
  List<SharedNight>? nights;
  DateTime? updated;
  String? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final r = await Cloud.sync.fetchShared(widget.owner.id);
      if (r == null) {
        nights = null;
        error = '${widget.owner.name} nie wysłał(a) jeszcze danych. Pojawią się po otwarciu Rytmu Snu na tamtym telefonie.';
      } else {
        final j = (jsonDecode(utf8.decode(r.$1)) as Map).cast<String, Object?>();
        if (j['format'] != 'rytm-snu-podglad') throw KoofrException('Nieznany format danych.');
        updated = j['generatedAt'] is int ? DateTime.fromMillisecondsSinceEpoch(j['generatedAt'] as int) : r.$2;
        nights = [
          for (final n in (j['nights'] as List? ?? const []))
            SharedNight((n as Map).cast<String, Object?>()),
        ]..sort((a, b) => b.start.compareTo(a.start));
      }
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final list = nights;
    return Scaffold(
      appBar: AppBar(title: Text('Sen: ${widget.owner.name}')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (loading && list == null) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
            if (error != null) Padding(padding: const EdgeInsets.all(16), child: Text(error!, style: const TextStyle(color: C.muted))),
            if (updated != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('Aktualizacja: ${dayLabel(updated!)}, ${hhmm(updated!)}',
                    style: const TextStyle(color: C.muted, fontSize: 12)),
              ),
            if (list != null && list.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Brak nocy w udostępnionym okresie.'))),
            if (list != null && list.isNotEmpty) _summary(list),
            for (final n in list ?? const <SharedNight>[])
              Card(
                child: ListTile(
                  leading: ScoreRing(score: n.score, size: 44),
                  title: Text(dayLabel(nightOf(n.start))),
                  subtitle: Text('${durHM(n.toNight().durationMin)} snu · ${hhmm(n.start)}–${n.end == null ? '?' : hhmm(n.end!)}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => _SharedNightScreen(owner: widget.owner.name, night: n))),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _summary(List<SharedNight> list) {
    final last7 = list.take(7).toList();
    final avgSleep = last7.map((n) => n.toNight().durationMin).reduce((a, b) => a + b) / last7.length;
    final avgScore = last7.map((n) => n.score).reduce((a, b) => a + b) / last7.length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Expanded(child: _stat('Średni sen', durHM(avgSleep), 'ostatnie ${last7.length} nocy')),
          Expanded(child: _stat('Średnia ocena', avgScore.round().toString(), 'na 100')),
        ]),
      ),
    );
  }

  Widget _stat(String label, String value, String sub) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: C.muted, fontSize: 12)),
        Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        Text(sub, style: const TextStyle(color: C.muted, fontSize: 11)),
      ]);
}

class _SharedNightScreen extends StatelessWidget {
  final String owner;
  final SharedNight night;
  const _SharedNightScreen({required this.owner, required this.night});

  @override
  Widget build(BuildContext context) {
    final n = night.toNight();
    final ms = night.minutes();
    String? val(String k, String Function(num v) f) => night.numOf(k) == null ? null : f(night.numOf(k)!);
    final rows = <(String, String?)>[
      ('Sen', durHM(n.durationMin)),
      ('W łóżku', durHM(n.inBedMin)),
      ('Zasypianie', durHM(n.latencyMin)),
      ('Przebudzenia', '${n.awakenings}'),
      ('Chrapanie', val('snoreMin', (v) => durHM(v))),
      ('Mówienie', val('talk', (v) => '$v')),
      ('Kaszel', val('cough', (v) => '$v')),
      ('Przerwy w oddechu', val('apnea', (v) => '$v')),
      ('Spłycenia oddechu', val('hypopnea', (v) => '$v')),
      ('Wskaźnik przerw', val('apneaIndex', (v) => '${v.toStringAsFixed(1)}/h · ${apneaCategory(v.toDouble())}')),
      ('Oddech', val('breathRate', (v) => '${v.toStringAsFixed(1)}/min')),
      ('CPAP AHI', val('cpapAhi', (v) => v.toStringAsFixed(1))),
      ('CPAP nieszczelność', val('cpapLeak', (v) => '${v.toStringAsFixed(1)} l/min')),
      ('CPAP użycie', val('cpapUsage', (v) => durHM(v))),
      ('Tętno śr./min.', night.has('hrAvg') ? '${night.numOf('hrAvg')?.round()} / ${night.numOf('hrMin')?.round() ?? '—'}' : null),
      ('SpO₂ śr./min.', night.has('spo2Avg') ? '${night.numOf('spo2Avg')?.round()}% / ${night.numOf('spo2Min')?.round() ?? '—'}%' : null),
      ('Ocena osoby', night.has('rating') && night.numOf('rating') != 0 ? '★' * night.numOf('rating')!.toInt() : null),
      ('Wiatry', val('farts', (v) => fartsLabel(v.toInt()))),
    ].where((r) => r.$2 != null).toList();

    return Scaffold(
      appBar: AppBar(title: Text('$owner · ${dayLabel(nightOf(night.start))}')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        Center(child: ScoreRing(score: n.score, size: 120)),
        const SizedBox(height: 16),
        StageBar(n: n),
        if (ms.length >= 2) ...[
          const SizedBox(height: 16),
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Hypnogram(minutes: ms))),
        ],
        const SizedBox(height: 12),
        Card(
          child: Column(children: [
            for (final r in rows)
              ListTile(dense: true, title: Text(r.$1), trailing: Text(r.$2!, style: const TextStyle(fontWeight: FontWeight.w600))),
          ]),
        ),
        if (night.tags.isNotEmpty || (night.raw['note'] as String? ?? '').isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (night.tags.isNotEmpty) Text(night.tags.map((t) => '#$t').join(' ')),
                if ((night.raw['note'] as String? ?? '').isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(night.raw['note'] as String, style: const TextStyle(color: C.muted)),
                ],
              ]),
            ),
          ),
      ]),
    );
  }
}
