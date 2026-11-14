import 'package:flutter/material.dart';

import '../core/experiments.dart';
import '../core/fmt.dart';
import 'theme.dart';

class ExperimentsScreen extends StatefulWidget {
  const ExperimentsScreen({super.key});

  @override
  State<ExperimentsScreen> createState() => _ExperimentsScreenState();
}

class _ExperimentsScreenState extends State<ExperimentsScreen> {
  List<Experiment> list = Experiments.all();

  void _reload() => setState(() => list = Experiments.all());

  Future<void> _new() async {
    final preset = await showModalBottomSheet<(String, String, String, String)>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Text('Nowy eksperyment', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          for (final p in experimentPresets)
            ListTile(
              title: Text(p.$1),
              subtitle: Text('A: ${p.$2}  ·  B: ${p.$3}\n${p.$4 == 'ab' ? 'noce na zmianę (losowo)' : 'przed i po zmianie'}'),
              isThreeLine: true,
              onTap: () => Navigator.pop(ctx, p),
            ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Własny eksperyment'),
            onTap: () => Navigator.pop(ctx, ('', '', '', 'ab')),
          ),
        ]),
      ),
    );
    if (preset == null || !mounted) return;
    final name = TextEditingController(text: preset.$1);
    final a = TextEditingController(text: preset.$2.isEmpty ? 'jak zwykle' : preset.$2);
    final b = TextEditingController(text: preset.$3);
    var mode = preset.$4;
    var days = 14;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Eksperyment'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Nazwa')),
              TextField(controller: a, decoration: const InputDecoration(labelText: 'Wariant A (porównawczy)')),
              TextField(controller: b, decoration: const InputDecoration(labelText: 'Wariant B (zmiana)')),
              const SizedBox(height: 10),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'ab', label: Text('Na zmianę')),
                  ButtonSegment(value: 'before', label: Text('Przed / po')),
                ],
                selected: {mode},
                onSelectionChanged: (v) => set(() => mode = v.first),
              ),
              const SizedBox(height: 6),
              Text(
                mode == 'ab'
                    ? 'Każdego wieczoru aplikacja powie, który wariant dziś (losowo w parach nocy). Najpewniejszy wynik.'
                    : 'A = $days nocy przed dzisiejszym dniem, B = $days nocy od dziś. Dla zmian, których nie da się '
                        'robić co drugi dzień (ustawienia aparatu, nowa maska).',
                style: const TextStyle(fontSize: 12, color: C.muted),
              ),
              Row(children: [
                const Text('Czas trwania'),
                const Spacer(),
                DropdownButton<int>(
                  value: days,
                  items: const [
                    DropdownMenuItem(value: 10, child: Text('10 nocy')),
                    DropdownMenuItem(value: 14, child: Text('14 nocy')),
                    DropdownMenuItem(value: 21, child: Text('21 nocy')),
                    DropdownMenuItem(value: 28, child: Text('28 nocy')),
                  ],
                  onChanged: (v) => set(() => days = v ?? 14),
                ),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Anuluj')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Rozpocznij')),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty || b.text.trim().isEmpty) return;
    final now = DateTime.now();
    final day = now.hour < 12 ? now.subtract(const Duration(days: 1)) : now;
    Experiments.add(Experiment('${now.millisecondsSinceEpoch}', name.text.trim(), a.text.trim(), b.text.trim(), mode,
        DateTime(day.year, day.month, day.day), days));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final act = list.where((e) => e.active).toList();
    final done = list.where((e) => !e.active).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Eksperymenty')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _new,
        icon: const Icon(Icons.science_outlined),
        label: const Text('Nowy'),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
        const Text(
          'Sprawdź na sobie, czy zmiana naprawdę pomaga: aplikacja porówna noce z wariantem A i B '
          'i powie, czy różnica jest wyraźna, czy może być przypadkiem.',
          style: TextStyle(color: C.muted, height: 1.4),
        ),
        const SizedBox(height: 12),
        if (list.isEmpty)
          const Section(child: Text('Nie masz jeszcze eksperymentów.', style: TextStyle(color: C.muted))),
        for (final e in [...act, ...done]) ...[
          _ExperimentCard(e: e, onChanged: _reload),
          const SizedBox(height: 10),
        ],
      ]),
    );
  }
}

class _ExperimentCard extends StatefulWidget {
  final Experiment e;
  final VoidCallback onChanged;
  const _ExperimentCard({required this.e, required this.onChanged});

  @override
  State<_ExperimentCard> createState() => _ExperimentCardState();
}

class _ExperimentCardState extends State<_ExperimentCard> {
  List<ExperimentResult>? res;

  @override
  void initState() {
    super.initState();
    Experiments.results(widget.e).then((r) {
      if (mounted) setState(() => res = r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.e;
    final now = DateTime.now();
    final today = now.hour < 12 ? now.subtract(const Duration(days: 1)) : now;
    final arm = e.active && e.mode == 'ab' ? e.armFor(today) : null;
    final left = e.end.difference(DateTime(today.year, today.month, today.day)).inDays;
    return Section(
      title: '🧪 ${e.name}',
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'stop') {
            e.stopped = true;
            Experiments.update(e);
          }
          if (v == 'del') Experiments.remove(e.id);
          widget.onChanged();
        },
        itemBuilder: (_) => [
          if (e.active) const PopupMenuItem(value: 'stop', child: Text('Zakończ teraz')),
          const PopupMenuItem(value: 'del', child: Text('Usuń')),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('A: ${e.a}\nB: ${e.b}', style: const TextStyle(height: 1.4)),
        const SizedBox(height: 4),
        Text(
          e.active
              ? '${e.mode == 'ab' ? 'Noce na zmianę' : 'Przed / po'} · od ${shortDate(e.start)} · zostało $left ${left == 1 ? 'noc' : 'nocy'}'
              : 'Zakończony · ${shortDate(e.start)} – ${shortDate(e.end)}',
          style: const TextStyle(fontSize: 12, color: C.muted),
        ),
        if (arm != null)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(10)),
            child: Text('Dziś wariant $arm: ${e.armLabel(arm)}', style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        const SizedBox(height: 8),
        if (res == null)
          const LinearProgressIndicator()
        else
          for (final r in res!)
            if (r.a.n + r.b.n > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Expanded(child: Text(r.outcome.label)),
                  Text('A ${r.a.n > 0 ? r.a.mean.toStringAsFixed(r.outcome.decimals) : '—'} · '
                      'B ${r.b.n > 0 ? r.b.mean.toStringAsFixed(r.outcome.decimals) : '—'}  ',
                      style: const TextStyle(fontSize: 12, color: C.muted)),
                  Text(r.verdict,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: r.p < 0.2 && r.a.n >= 3 && r.b.n >= 3 ? (r.bBetter ? C.gas : C.danger) : C.muted)),
                ]),
              ),
        if (res != null && res!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Noce: A ${res!.first.a.n}, B ${res!.first.b.n}. „Wyraźnie” = mniej niż 5% szans na przypadek.',
                style: const TextStyle(fontSize: 11, color: C.muted)),
          ),
      ]),
    );
  }
}
