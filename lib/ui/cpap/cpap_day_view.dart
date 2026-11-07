import 'dart:math';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../../core/fmt.dart';
import '../../cpap/cpap_data.dart';
import '../theme.dart';
import 'cpap_charts.dart';

/// Dzień z aparatu — jak „Daily” w OSCAR: podsumowanie, ustawienia, sesje, flagi zdarzeń,
/// zsynchronizowane przebiegi (przepływ 25 Hz, ciśnienie, nieszczelność, objętości…) i lista zdarzeń.
class CpapDayView extends StatefulWidget {
  final List<DateTime> dates; // dostępne dni, od najstarszego
  final Map<DateTime, CardDay> summaries;
  final DateTime day;
  final ValueChanged<DateTime> onDay;
  final int waveDays;
  const CpapDayView(
      {super.key, required this.dates, required this.summaries, required this.day, required this.onDay, required this.waveDays});

  @override
  State<CpapDayView> createState() => _CpapDayViewState();
}

class _CpapDayViewState extends State<CpapDayView> with AutomaticKeepAliveClientMixin {
  CpapDetail? detail;
  CpapViewport? vp;
  bool loading = false;
  String? error;
  bool showAllEvents = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CpapDayView old) {
    super.didUpdateWidget(old);
    if (old.day != widget.day) _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
      detail = null;
      vp = null;
      showAllEvents = false;
    });
    try {
      final d = await CpapStore.detail(widget.day);
      if (!mounted) return;
      final sum = widget.summaries[widget.day];
      // zakres osi czasu: sesje z plików albo z podsumowania (maska)
      final spans = <double>[];
      for (final (a, b) in d.sessions) {
        spans
          ..add(a.millisecondsSinceEpoch / 1000)
          ..add(b.millisecondsSinceEpoch / 1000);
      }
      for (final (a, b) in sum?.maskSessions ?? const <(DateTime, DateTime)>[]) {
        spans
          ..add(a.millisecondsSinceEpoch / 1000)
          ..add(b.millisecondsSinceEpoch / 1000);
      }
      for (final e in d.events) {
        spans.add(e.t);
      }
      setState(() {
        detail = d;
        loading = false;
        if (spans.isNotEmpty) {
          final a = spans.reduce(min), b = spans.reduce(max);
          vp = CpapViewport(a - 300, max(b + 300, a + 600));
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '$e';
        });
      }
    }
  }

  int get _idx => widget.dates.indexOf(widget.day);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final sum = widget.summaries[widget.day];
    final i = _idx;
    return ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 32), children: [
      Row(children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          onPressed: i > 0 ? () => widget.onDay(widget.dates[i - 1]) : null,
        ),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: _pickDate,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(children: [
                Text(dayLabel(widget.day), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                Text('noc ${widget.day.day}/${widget.day.add(const Duration(days: 1)).day}.${two(widget.day.add(const Duration(days: 1)).month)}',
                    style: const TextStyle(fontSize: 11, color: C.muted)),
              ]),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          onPressed: i >= 0 && i < widget.dates.length - 1 ? () => widget.onDay(widget.dates[i + 1]) : null,
        ),
      ]),
      if (sum != null) ...[_summary(sum), const SizedBox(height: 10), _settings(sum), const SizedBox(height: 10)],
      if (loading) const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
      if (error != null) Text('Błąd odczytu: $error', style: const TextStyle(color: C.danger)),
      if (detail != null) ..._detail(detail!, sum),
    ]);
  }

  Future<void> _pickDate() async {
    if (widget.dates.isEmpty) return;
    final set = widget.dates.toSet();
    final d = await showDatePicker(
      context: context,
      initialDate: widget.day,
      firstDate: widget.dates.first,
      lastDate: widget.dates.last,
      selectableDayPredicate: (d) => set.contains(DateTime(d.year, d.month, d.day)),
    );
    if (d != null) widget.onDay(DateTime(d.year, d.month, d.day));
  }

  String f1(double? v, [int d = 1]) => v == null ? '—' : v.toStringAsFixed(d);

  Widget _summary(CardDay s) {
    final ahi = s.ahi;
    final ahiCol = ahi == null ? C.text : (ahi < 5 ? C.gas : (ahi < 15 ? C.moon : C.danger));
    final l95 = s.leak95;
    return Section(
      title: 'Podsumowanie aparatu',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TileGrid(columns: 3, children: [
          StatTile(
              label: 'Użycie',
              value: durHM(s.usageMin),
              sub: s.compliant ? '✓ ≥ 4 h' : 'poniżej 4 h',
              color: s.compliant ? C.gas : C.moon),
          StatTile(label: 'AHI', value: f1(ahi), sub: 'zdarzeń/h', color: ahiCol),
          StatTile(
              label: 'Nieszczelność 95%',
              value: f1(l95),
              sub: 'L/min · med. ${f1(s.leak50)}',
              color: (l95 ?? 0) > 24 ? C.danger : C.text),
          StatTile(label: 'Ciśnienie 95%', value: f1(s.press95), sub: 'med. ${f1(s.press50)} · max ${f1(s.pressMax)}'),
          StatTile(label: 'Oddechy/min', value: f1(s.rr50, 0), sub: '95%: ${f1(s.rr95, 0)}'),
          StatTile(label: 'Obj. oddechowa', value: f1(s.tv50, 0), sub: 'mL · 95%: ${f1(s.tv95, 0)}'),
          StatTile(label: 'Wentylacja min.', value: f1(s.mv50), sub: 'L/min · 95%: ${f1(s.mv95)}'),
          if (s.spo250 != null) StatTile(label: 'SpO₂ mediana', value: f1(s.spo250, 0), sub: '%'),
          StatTile(label: 'Maska', value: '${s.maskSessions.length}×', sub: 'sesji'),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final (k, label, v) in [
            ('oa', 'OA', s.oai),
            ('ca', 'CA', s.cai),
            ('ua', 'UA', s.uai),
            ('h', 'H', s.hi),
            ('rera', 'RERA', s.rin),
          ])
            if (v != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: cpapEventColor(k).withValues(alpha: 0.18), borderRadius: BorderRadius.circular(20)),
                child: Text('$label ${v.toStringAsFixed(1)}/h', style: TextStyle(fontSize: 12, color: cpapEventColor(k))),
              ),
          if (s.csr != null && s.csr! > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                  color: cpapEventColor('csr').withValues(alpha: 0.18), borderRadius: BorderRadius.circular(20)),
              child: Text('CSR ${s.csr!.toStringAsFixed(0)}', style: TextStyle(fontSize: 12, color: cpapEventColor('csr'))),
            ),
        ]),
        if (s.maskSessions.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final (a, b) in s.maskSessions)
            Text('😷 ${hhmm(a)} – ${hhmm(b)}  (${durHM(b.difference(a).inMinutes)})',
                style: const TextStyle(fontSize: 12, color: C.muted)),
        ],
      ]),
    );
  }

  Widget _settings(CardDay s) {
    CardDay? prev;
    final i = _idx;
    for (var j = i - 1; j >= 0; j--) {
      final p = widget.summaries[widget.dates[j]];
      if (p != null) {
        prev = p;
        break;
      }
    }
    final changed = prev != null && prev.settingsKey != s.settingsKey;
    String p(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)} cmH₂O';
    final rows = <(String, String)>[
      ('Tryb', s.modeName),
      if (s.isAuto) ('Zakres ciśnienia', '${s.setMin?.toStringAsFixed(1) ?? '—'} – ${p(s.setMax)}') else ('Ciśnienie', p(s.setPress)),
      if (s.setStart != null) ('Ciśnienie startowe', p(s.setStart)),
      ('EPR (ulga wydechowa)', s.eprOn ? 'poziom ${s.eprLevel ?? '—'}' : 'wył.'),
      ('Rampa', s.rampOn ? '${s.rampTime ?? '—'} min' : 'wył.'),
      ('Nawilżacz', s.humOn ? 'poziom ${s.humLevel ?? '—'}' : 'wył.'),
      if (s.tempOn || s.temp != null) ('Rura grzana', s.tempOn ? '${s.temp?.toStringAsFixed(0) ?? '—'} °C' : 'wył.'),
      ('Maska', s.maskName),
      ('SmartStart', s.smartStart ? 'wł.' : 'wył.'),
    ];
    return Section(
      title: 'Ustawienia aparatu',
      trailing: changed
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: C.moon.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(10)),
              child: const Text('zmiana', style: TextStyle(fontSize: 11, color: C.moon)),
            )
          : null,
      child: Column(children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Expanded(child: Text(k, style: const TextStyle(color: C.muted, fontSize: 13))),
              Text(v, style: const TextStyle(fontSize: 13)),
            ]),
          ),
      ]),
    );
  }

  List<Widget> _detail(CpapDetail d, CardDay? sum) {
    final v = vp;
    if (d.isEmpty || v == null) {
      return [
        Section(
          child: Text(
            sum == null
                ? 'Brak danych z tego dnia.'
                : 'Brak szczegółowych plików z tej nocy (zdarzenia i przebiegi). Zaimportuj kartę ponownie — '
                    'aplikacja dopisze brakujące pliki.',
            style: const TextStyle(color: C.muted, height: 1.4),
          ),
        ),
      ];
    }
    final sessions = [
      for (final (a, b) in (sum?.maskSessions.isNotEmpty ?? false) ? sum!.maskSessions : d.sessions)
        (a.millisecondsSinceEpoch / 1000, b.millisecondsSinceEpoch / 1000)
    ];
    final flowEvents = [for (final e in d.events) if (e.kind != 'other') e];
    final counts = <String, int>{};
    for (final e in d.events) {
      counts[e.kind] = (counts[e.kind] ?? 0) + 1;
    }
    final evList = [for (final e in d.events) if (e.kind != 'other' || e.text.isNotEmpty) e];
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _zoomBar(v),
            const SizedBox(height: 6),
            CpapFlagsChart(events: d.events, csr: d.csr, sessions: sessions, vp: v),
            if (!d.hasFlow)
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 4),
                child: Text(
                  widget.waveDays > 0
                      ? 'Pełny zapis oddechu (przepływ 25 Hz) jest dostępny dla ostatnich ${widget.waveDays} dni '
                          '(Ustawienia → CPAP) — albo ta noc nie została jeszcze zaimportowana.'
                      : 'Brak pełnego zapisu oddechu z tej nocy.',
                  style: const TextStyle(fontSize: 11, color: C.muted),
                ),
              ),
            for (final s in d.series.values)
              CpapWaveChart(
                key: ValueKey('${widget.day}-${s.key}'),
                series: s,
                vp: v,
                height: s.key == 'flow' ? 150 : 80,
                events: s.key == 'flow' ? flowEvents : const [],
                regions: s.key == 'flow' ? d.csr : const [],
                refLine: s.key == 'leak' ? 24 : null,
                symmetric: s.key == 'flow',
                decimals: switch (s.key) {
                  'tv' || 'spo2' || 'pulse' || 'rr' => 0,
                  'flim' || 'snore' || 'ie' => 2,
                  _ => 1,
                },
              ),
            const SizedBox(height: 6),
            const Text(
              'Przeciągnij w bok, aby przesunąć · dotknij, aby odczytać wartości · stuknij dwa razy, aby powiększyć.',
              style: TextStyle(fontSize: 10, color: C.muted),
              textAlign: TextAlign.center,
            ),
          ]),
        ),
      ),
      const SizedBox(height: 10),
      Section(
        title: 'Zdarzenia (${evList.length})',
        child: evList.isEmpty
            ? const Text('Aparat nie zapisał zdarzeń tej nocy.', style: TextStyle(color: C.muted))
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Wrap(spacing: 10, runSpacing: 4, children: [
                  for (final (k, label, short) in cpapEventKinds)
                    if ((counts[k] ?? 0) > 0)
                      Text('$short ${counts[k]}', style: TextStyle(color: cpapEventColor(k), fontWeight: FontWeight.w700)),
                  if (d.csr.isNotEmpty)
                    Text('CSR ${durHM(d.csr.fold<double>(0, (a, r) => a + (r.$2 - r.$1)) / 60)}',
                        style: TextStyle(color: cpapEventColor('csr'), fontWeight: FontWeight.w700)),
                ]),
                const SizedBox(height: 6),
                for (final e in showAllEvents ? evList : evList.take(30))
                  InkWell(
                    onTap: () {
                      v.window(max(90, e.dur * 4), e.t + e.dur / 2);
                      v.setCursor(e.t);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(children: [
                        Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(color: cpapEventColor(e.kind), borderRadius: BorderRadius.circular(2))),
                        const SizedBox(width: 8),
                        Text(tLabel(e.t, sec: true),
                            style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontSize: 13)),
                        const SizedBox(width: 10),
                        Expanded(
                            child: Text(
                                cpapEventKinds.firstWhere((k) => k.$1 == e.kind, orElse: () => ('other', e.text, '•')).$2,
                                style: const TextStyle(fontSize: 13))),
                        if (e.dur > 0) Text('${e.dur.round()} s', style: const TextStyle(color: C.muted, fontSize: 12)),
                        const Icon(Icons.zoom_in, size: 16, color: C.muted),
                      ]),
                    ),
                  ),
                if (evList.length > 30 && !showAllEvents)
                  TextButton(onPressed: () => setState(() => showAllEvents = true), child: Text('Pokaż wszystkie (${evList.length})')),
              ]),
      ),
    ];
  }

  Widget _zoomBar(CpapViewport v) {
    Widget chip(String t, VoidCallback f) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ActionChip(
            label: Text(t, style: const TextStyle(fontSize: 12)),
            onPressed: f,
            visualDensity: VisualDensity.compact,
          ),
        );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        chip('Cała noc', v.all),
        chip('1 h', () => v.window(3600)),
        chip('10 min', () => v.window(600)),
        chip('2 min', () => v.window(120)),
        chip('30 s', () => v.window(30)),
        IconButton(icon: const Icon(Icons.zoom_out), onPressed: () => v.zoom(2.5), visualDensity: VisualDensity.compact),
        IconButton(icon: const Icon(Icons.zoom_in), onPressed: () => v.zoom(0.4), visualDensity: VisualDensity.compact),
        IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Ukryj kursor',
            onPressed: () => v.setCursor(null),
            visualDensity: VisualDensity.compact),
      ]),
    );
  }
}
