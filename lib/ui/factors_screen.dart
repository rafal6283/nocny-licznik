import 'package:flutter/material.dart';

import '../core/insights.dart';
import '../core/models.dart';
import 'theme.dart';

/// Wszystkie czynniki i ich wpływ na Twój sen (z Twoich nocy).
class FactorsScreen extends StatefulWidget {
  const FactorsScreen({super.key});

  @override
  State<FactorsScreen> createState() => _FactorsScreenState();
}

class _FactorsScreenState extends State<FactorsScreen> {
  FactorReport? rep;

  @override
  void initState() {
    super.initState();
    Insights.build().then((r) {
      if (mounted) setState(() => rep = r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = rep;
    return Scaffold(
      appBar: AppBar(title: const Text('Co wpływa na Twój sen')),
      body: r == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
              Text(
                'Porównanie Twoich nocy: z danym czynnikiem i bez niego (albo z najwyższą i najniższą 1/3 wartości). '
                'Pokazane są tylko wyraźne różnice. To związek, nie dowód przyczyny — do sprawdzenia przyczyny '
                'służą Eksperymenty. Noce w analizie: ${r.nights.length}.',
                style: const TextStyle(color: C.muted, height: 1.4),
              ),
              const SizedBox(height: 12),
              if (r.effects.isEmpty)
                const Section(
                  child: Text(
                    'Jeszcze za mało nocy, żeby wskazać czynniki. Potrzeba co najmniej 8 nocy z danym czynnikiem '
                    'i po 4 noce w każdej grupie. Pomagają tagi wieczorne, treningi i posiłki z Health Connect '
                    'oraz termometr w sypialni.',
                    style: TextStyle(color: C.muted, height: 1.4),
                  ),
                ),
              for (final f in r.factors)
                if (r.effects.any((e) => e.factor.id == f.id)) ...[
                  _factorCard(r, f),
                  const SizedBox(height: 10),
                ],
            ]),
    );
  }

  Widget _factorCard(FactorReport r, Factor f) {
    final effs = r.effects.where((e) => e.factor.id == f.id).toList();
    final e0 = effs.first;
    final groups = f.isBool
        ? 'z: ${e0.nHigh} nocy · bez: ${e0.nLow} nocy'
        : '${f.highWord} (≥ ${_fmt(e0.highMin)}${f.unit}): ${e0.nHigh} · ${f.lowWord} (≤ ${_fmt(e0.lowMax)}${f.unit}): ${e0.nLow}';
    return Section(
      title: '${f.emoji == '#' ? '' : '${f.emoji} '}${f.label}',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(groups, style: const TextStyle(fontSize: 11, color: C.muted)),
        const SizedBox(height: 6),
        for (final e in effs)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Icon(e.helps ? Icons.arrow_upward : Icons.arrow_downward, size: 16, color: e.helps ? C.gas : C.danger),
              const SizedBox(width: 6),
              Expanded(child: Text(e.outcome.label)),
              Text(e.outcome.fmtDelta(e.delta),
                  style: TextStyle(fontWeight: FontWeight.w700, color: e.helps ? C.gas : C.danger)),
              const SizedBox(width: 8),
              Text(_strength(e.d), style: const TextStyle(fontSize: 11, color: C.muted)),
            ]),
          ),
      ]),
    );
  }
}

String _fmt(double v) => v.toStringAsFixed(v.abs() >= 100 ? 0 : 1);

String _strength(double d) {
  final a = d.abs();
  if (a >= 0.8) return 'silny';
  if (a >= 0.5) return 'średni';
  return 'słaby';
}

/// Karta na ekranie nocy: co tej nocy mogło pomóc albo zaszkodzić.
class NightInsightsCard extends StatefulWidget {
  final Night night;
  const NightInsightsCard({super.key, required this.night});

  @override
  State<NightInsightsCard> createState() => _NightInsightsCardState();
}

class _NightInsightsCardState extends State<NightInsightsCard> {
  List<NightExplanation>? items;

  @override
  void initState() {
    super.initState();
    Insights.build().then((r) {
      if (mounted) setState(() => items = Insights.explain(r, widget.night));
    });
  }

  @override
  Widget build(BuildContext context) {
    final it = items;
    if (it == null || it.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Section(
        title: 'Co wpłynęło na tę noc',
        trailing: TextButton(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FactorsScreen())),
          child: const Text('Wszystkie'),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final x in it.take(4))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(x.emoji == '#' ? '🏷️' : x.emoji, style: const TextStyle(fontSize: 18)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(x.title, style: TextStyle(fontWeight: FontWeight.w600, color: x.positive ? C.gas : C.text)),
                    Text(x.detail, style: const TextStyle(fontSize: 12, color: C.muted)),
                  ]),
                ),
                Icon(x.positive ? Icons.thumb_up_alt_outlined : Icons.thumb_down_alt_outlined,
                    size: 16, color: x.positive ? C.gas : C.danger),
              ]),
            ),
          const SizedBox(height: 4),
          const Text('Na podstawie Twoich wcześniejszych nocy.', style: TextStyle(fontSize: 11, color: C.muted)),
        ]),
      ),
    );
  }
}
