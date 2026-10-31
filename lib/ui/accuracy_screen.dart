import 'package:flutter/material.dart';

import '../core/calibration.dart';
import '../core/fmt.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../core/sound_thresholds.dart';
import '../engine/night_engine.dart';
import '../engine/stage_model.dart';
import 'theme.dart';

/// Jak dobrze aplikacja zgadza się z zegarkiem i aparatem CPAP, oraz stan kalibracji.
class AccuracyScreen extends StatefulWidget {
  const AccuracyScreen({super.key});

  @override
  State<AccuracyScreen> createState() => _AccuracyScreenState();
}

class _AccuracyScreenState extends State<AccuracyScreen> {
  final s = Settings.instance;
  CalibReport? rep;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => busy = true);
    final r = await Calibration.run(apply: false);
    if (mounted) {
      setState(() {
        rep = r;
        busy = false;
      });
    }
  }

  Future<void> _calibrate() async {
    setState(() => busy = true);
    final r = await Calibration.run(apply: true);
    if (!mounted) return;
    setState(() {
      rep = r;
      busy = false;
    });
    _snack(r.changes.isEmpty ? 'Bez zmian — kalibracja jest aktualna.' : 'Zmieniono: ${r.changes.join('; ')}.');
  }

  Future<void> _reset() async {
    setState(() => busy = true);
    StageModel.current = StageModel.defaults;
    s.stageModelJson = '';
    SoundThresholds.map = {};
    s.minConfJson = '';
    s.calibSnoreNights = 0;
    await NightEngine.reanalyzeAll();
    await _load();
    _snack('Przywrócono ustawienia domyślne rozpoznawania.');
  }

  void _snack(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  String pct(double? v) => v == null ? '—' : '${(v * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    final r = rep;
    return Scaffold(
      appBar: AppBar(title: const Text('Dokładność i kalibracja')),
      body: r == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
                const Text(
                  'Aplikacja porównuje swoje wyniki z zegarkiem (fazy snu) i aparatem CPAP (bezdechy, chrapanie) '
                  'oraz uczy się z Twoich ocen nagrań. Im więcej nocy z zegarkiem i aparatem, tym lepsze dopasowanie.',
                  style: TextStyle(color: C.muted, height: 1.4),
                ),
                const SizedBox(height: 12),
                _stagesSection(r),
                const SizedBox(height: 12),
                _apneaSection(r),
                const SizedBox(height: 12),
                _snoreSection(r),
                const SizedBox(height: 12),
                _labelsSection(r),
                const SizedBox(height: 12),
                Card(
                  child: Column(children: [
                    SwitchListTile(
                      title: const Text('Kalibruj automatycznie'),
                      subtitle: const Text('Po każdym uruchomieniu, gdy przybędą noce z zegarkiem, aparatem lub ocenami'),
                      value: s.autoCalibration,
                      onChanged: (v) => setState(() => s.autoCalibration = v),
                    ),
                    ListTile(
                      leading: busy
                          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.tune),
                      title: const Text('Kalibruj teraz'),
                      subtitle: const Text('Uczy model i progi, potem przelicza wszystkie noce'),
                      onTap: busy || !s.autoCalibration ? null : _calibrate,
                    ),
                    ListTile(
                      leading: const Icon(Icons.restart_alt),
                      title: const Text('Przywróć domyślne'),
                      subtitle: const Text('Usuwa dostrojenie i przelicza noce ustawieniami fabrycznymi'),
                      onTap: busy ? null : _reset,
                    ),
                  ]),
                ),
              ]),
            ),
    );
  }

  Widget _stagesSection(CalibReport r) {
    final m = StageModel.current;
    if (r.stages.isEmpty) {
      return const Section(
        title: 'Fazy snu a zegarek',
        child: Text(
          'Brak nocy z fazami snu z zegarka. Włącz Ustawienia → „Dane z zegarka (Health Connect)” i śpij z zegarkiem — '
          'np. Huawei przez aplikację Health Sync. Wystarczy kilka nocy.',
          style: TextStyle(color: C.muted, height: 1.4),
        ),
      );
    }
    return Section(
      title: 'Fazy snu a zegarek',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TileGrid(columns: 2, children: [
          StatTile(label: 'Zgodność · fabryczne', value: pct(r.agreeDefault), sub: 'κ ${r.kappaDefault?.toStringAsFixed(2) ?? '—'}'),
          StatTile(
              label: 'Zgodność · dostrojone',
              value: pct(r.agreeTuned),
              sub: 'κ ${r.kappaTuned?.toStringAsFixed(2) ?? '—'}',
              color: (r.agreeTuned ?? 0) > (r.agreeDefault ?? 0) ? C.gas : C.text),
        ]),
        const SizedBox(height: 8),
        Text(
          m.personalized
              ? 'Model dostrojony na ${m.nights} ${m.nights == 1 ? 'nocy' : 'nocach'} (${durHM(m.minutes)} z fazami z zegarka).'
              : 'Model fabryczny — kalibracja jeszcze nie zapisana.',
          style: const TextStyle(fontSize: 12, color: C.muted),
        ),
        const SizedBox(height: 8),
        for (final a in r.stages.take(10))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(child: Text(dayLabel(nightOf(a.night.start)))),
              Text('${pct(a.agreeDefault)} → ', style: const TextStyle(color: C.muted)),
              Text(pct(a.agreeTuned),
                  style: TextStyle(fontWeight: FontWeight.w700, color: a.agreeTuned >= a.agreeDefault ? C.gas : C.danger)),
            ]),
          ),
        const SizedBox(height: 6),
        const Text(
          'Zgodność samego telefonu (bez zegarka) z fazami z zegarka, minuta po minucie. Przy ocenie dostrojenia '
          'oceniana noc jest pomijana w nauce, żeby wynik był uczciwy. κ (kappa) to zgodność ponad przypadek: '
          '0,2–0,4 słaba, 0,4–0,6 umiarkowana, >0,6 dobra. Zegarek też nie jest badaniem snu — to porównanie, '
          'nie prawda absolutna. W noce z zegarkiem jego fazy są dodatkowo łączone z danymi telefonu.',
          style: TextStyle(fontSize: 11, color: C.muted, height: 1.4),
        ),
      ]),
    );
  }

  Widget _apneaSection(CalibReport r) {
    final a = r.apnea;
    if (a.nights == 0) {
      return const Section(
        title: 'Bezdechy a aparat CPAP',
        child: Text('Zaimportuj dane z karty SD AirSense (Ustawienia → CPAP), żeby porównać wykryte przerwy w oddechu '
            'ze zdarzeniami zapisanymi przez aparat.', style: TextStyle(color: C.muted, height: 1.4)),
      );
    }
    String rate(int c) => a.hours > 0 ? (c / a.hours).toStringAsFixed(1) : '—';
    final thrA = r.labels[SoundType.apnea]?.threshold, thrH = r.labels[SoundType.hypopnea]?.threshold;
    return Section(
      title: 'Bezdechy a aparat CPAP',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TileGrid(columns: 2, children: [
          StatTile(label: 'Aparat (na godzinę)', value: rate(a.device), sub: '${a.device} zdarzeń'),
          StatTile(label: 'Aplikacja (na godzinę)', value: rate(a.ours), sub: '${a.ours} zdarzeń'),
          StatTile(label: 'Wykryte z aparatu', value: pct(a.sensitivity), sub: 'czułość'),
          StatTile(label: 'Potwierdzone przez aparat', value: pct(a.precision), sub: 'trafność'),
        ]),
        const SizedBox(height: 6),
        Text(
          '${a.nights} ${a.nights == 1 ? 'noc' : 'nocy'}, ${a.hours.toStringAsFixed(1)} h z maską. '
          'Progi pewności: przerwy ${_thr(thrA)}, spłycenia ${_thr(thrH)}. '
          'Z maską bezdechów jest zwykle mało — pewniejsza kalibracja po kilkunastu nocach.',
          style: const TextStyle(fontSize: 11, color: C.muted, height: 1.4),
        ),
      ]),
    );
  }

  Widget _snoreSection(CalibReport r) {
    final a = r.snore;
    if (a.nights == 0) {
      return const Section(
        title: 'Chrapanie a aparat CPAP',
        child: Text('Po imporcie z karty SD aplikacja porówna minuty chrapania z czujnikiem chrapania w aparacie.',
            style: TextStyle(color: C.muted, height: 1.4)),
      );
    }
    return Section(
      title: 'Chrapanie a aparat CPAP',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TileGrid(columns: 2, children: [
          StatTile(label: 'Minuty wg aparatu', value: '${a.device}'),
          StatTile(label: 'Minuty wg aplikacji', value: '${a.ours}'),
          StatTile(label: 'Wykryte z aparatu', value: pct(a.sensitivity), sub: 'czułość'),
          StatTile(label: 'Potwierdzone przez aparat', value: pct(a.precision), sub: 'trafność'),
        ]),
        const SizedBox(height: 6),
        Text(
          '${a.nights} ${a.nights == 1 ? 'noc' : 'nocy'}, ${a.hours.toStringAsFixed(1)} h porównania. '
          'Czułość wykrywania chrapania w aplikacji: ${(s.snoreSensitivity * 100).round()}% '
          '(dostrajana automatycznie od 3 nocy). Przy dobrze dobranym ciśnieniu chrapania z maską prawie nie ma.',
          style: const TextStyle(fontSize: 11, color: C.muted, height: 1.4),
        ),
      ]),
    );
  }

  String _thr(double? t) => t == null ? 'za mało danych' : (t == 0 ? 'niepotrzebny' : '${(t * 100).round()}%');

  Widget _labelsSection(CalibReport r) {
    final types = [
      for (final t in SoundType.values)
        if ((t != SoundType.fart || s.detectFarts) && r.labels[t] != null && (r.labels[t]!.yes + r.labels[t]!.no) > 0) t
    ];
    return Section(
      title: 'Twoje oceny nagrań',
      child: types.isEmpty
          ? const Text(
              'Oceniaj nagrania przy nocy (✓ „to było to”, ✗ „fałszywy alarm”). Od 8 ocen danego rodzaju aplikacja '
              'sama dobierze próg pewności, poniżej którego zdarzenia przestaną się liczyć.',
              style: TextStyle(color: C.muted, height: 1.4))
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final t in types)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Text('${t.emoji}  ', style: const TextStyle(fontSize: 16)),
                    Expanded(child: Text(t.label)),
                    Text('✓ ${r.labels[t]!.yes}  ✗ ${r.labels[t]!.no}  ', style: const TextStyle(color: C.muted)),
                    Text('próg ${_thr(r.labels[t]!.threshold)}', style: const TextStyle(fontSize: 12)),
                  ]),
                ),
              const SizedBox(height: 4),
              const Text(
                'Próg uwzględnia też porównanie z aparatem CPAP. Ręczna ocena zawsze ma pierwszeństwo.',
                style: TextStyle(fontSize: 11, color: C.muted),
              ),
            ]),
    );
  }
}
