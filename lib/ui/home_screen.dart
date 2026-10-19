import 'package:bakometr_native/bakometr_native.dart';
import 'package:flutter/material.dart';

import '../core/bus.dart';
import '../core/db.dart';
import '../core/fmt.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../core/stats_util.dart';
import '../engine/night_engine.dart';
import 'charts.dart';
import 'theme.dart';

const lullabies = {
  'none': 'Bez dźwięku',
  'white': 'Biały szum',
  'pink': 'Różowy szum',
  'brown': 'Brązowy szum',
  'rain': 'Deszcz',
  'waves': 'Fale',
  'fan': 'Wentylator',
};

class HomeScreen extends StatefulWidget {
  final void Function(int nightId) onOpenNight;
  const HomeScreen({super.key, required this.onOpenNight});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final s = Settings.instance;
  List<Night> recent = [];
  double? lux;
  bool measuring = false;
  bool starting = false;

  @override
  void initState() {
    super.initState();
    s.addListener(_refresh);
    dataVersion.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    s.removeListener(_refresh);
    dataVersion.removeListener(_load);
    super.dispose();
  }

  void _refresh() => setState(() {});

  Future<void> _load() async {
    final r = await Db.instance.nights(limit: 30);
    if (mounted) setState(() => recent = r);
  }

  Future<void> _pickAlarm() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: s.alarmHour, minute: s.alarmMinute),
      builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    if (t != null) {
      s.alarmHour = t.hour;
      s.alarmMinute = t.minute;
      s.alarmEnabled = true;
    }
  }

  Future<void> _measure() async {
    setState(() => measuring = true);
    final v = await BakometrNative.measureLux();
    if (!mounted) return;
    setState(() {
      measuring = false;
      lux = v;
      if (v != null) s.tonightLight = lightBucket(Night(start: DateTime.now(), avgLux: v));
    });
    if (v == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nie udało się zmierzyć światła — wybierz ręcznie.')));
    }
  }

  Future<void> _start() async {
    setState(() => starting = true);
    final plan = NightPlan(
      alarmAt: s.alarmEnabled ? nextOccurrence(s.alarmHour, s.alarmMinute) : null,
      smartWindowMin: s.smartWindowMin,
      tags: s.tonightTags,
      lightManual: s.tonightLight,
      lullaby: s.lullaby,
      lullabyMin: s.lullabyMin,
      delayMin: s.delayStartMin,
    );
    final ok = await NightEngine.instance.start(plan);
    if (!mounted) return;
    setState(() => starting = false);
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(NightEngine.instance.lastError ?? 'Nie udało się rozpocząć')));
    } else {
      // Tagi dotyczą jednej nocy — czyścimy na następną.
      s.tonightTags = [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final alarm = nextOccurrence(s.alarmHour, s.alarmMinute);
    final untilAlarm = alarm.difference(DateTime.now());
    final debt = sleepDebtMin(recent, s.sleepGoalMin);
    final last = recent.isNotEmpty ? recent.first : null;
    final hour = DateTime.now().hour;
    final greet = hour < 5 || hour >= 18 ? 'Dobry wieczór' : (hour < 12 ? 'Dzień dobry' : 'Cześć');

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text(greet, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        Text(dayLabel(DateTime.now()), style: const TextStyle(color: C.muted)),
        const SizedBox(height: 16),

        // --- Budzik ---
        Section(
          title: 'Budzik',
          trailing: Switch(value: s.alarmEnabled, onChanged: (v) => s.alarmEnabled = v),
          child: Opacity(
            opacity: s.alarmEnabled ? 1 : 0.4,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              InkWell(
                onTap: _pickAlarm,
                borderRadius: BorderRadius.circular(12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${two(s.alarmHour)}:${two(s.alarmMinute)}',
                      style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w300, color: C.moon, height: 1)),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('za ${durHM(untilAlarm.inMinutes)}', style: const TextStyle(color: C.muted)),
                  ),
                ]),
              ),
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final w in [0, 15, 30, 45])
                  ChoiceChip(
                    label: Text(w == 0 ? 'Bez okna' : '$w min wcześniej'),
                    selected: s.smartWindowMin == w,
                    onSelected: s.alarmEnabled ? (_) => s.smartWindowMin = w : null,
                  ),
              ]),
              const SizedBox(height: 6),
              Text(
                s.smartWindowMin == 0
                    ? 'Zadzwoni dokładnie o tej godzinie.'
                    : 'Inteligentne budzenie: zadzwoni w lekkiej fazie snu w ostatnich ${s.smartWindowMin} min.',
                style: const TextStyle(fontSize: 12, color: C.muted),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 12),

        // --- Dzisiejsza noc: tagi i światło ---
        Section(
          title: 'Co dziś na talerzu i w głowie?',
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final t in s.tags)
              FilterChip(
                label: Text('#$t'),
                selected: s.tonightTags.contains(t),
                onSelected: (v) {
                  final cur = [...s.tonightTags];
                  v ? cur.add(t) : cur.remove(t);
                  s.tonightTags = cur;
                },
              ),
          ]),
        ),
        const SizedBox(height: 12),
        Section(
          title: 'Światło w sypialni',
          trailing: TextButton.icon(
            onPressed: measuring ? null : _measure,
            icon: measuring
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.wb_sunny_outlined, size: 18),
            label: Text(lux != null ? luxLabel(lux) : 'Zmierz'),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'dark', label: Text('Ciemno')),
                ButtonSegment(value: 'dim', label: Text('Półmrok')),
                ButtonSegment(value: 'bright', label: Text('Jasno')),
              ],
              emptySelectionAllowed: true,
              selected: s.tonightLight.isEmpty ? <String>{} : {s.tonightLight},
              onSelectionChanged: (v) => s.tonightLight = v.isEmpty ? '' : v.first,
            ),
            const SizedBox(height: 6),
            const Text(
              'Android mierzy światło czujnikiem przez całą noc. Na iPhonie pomiar robi przednia kamera '
              '(telefon ekranem do góry) przy starcie i przy każdym otwarciu aplikacji w nocy.',
              style: TextStyle(fontSize: 12, color: C.muted),
            ),
          ]),
        ),
        const SizedBox(height: 12),

        // --- Kołysanka ---
        Section(
          title: 'Kołysanka',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            DropdownButton<String>(
              value: s.lullaby,
              isExpanded: true,
              underline: const SizedBox(),
              items: [for (final e in lullabies.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) => s.lullaby = v ?? 'none',
            ),
            if (s.lullaby != 'none') ...[
              Wrap(spacing: 6, children: [
                for (final m in [10, 20, 30, 45, 60])
                  ChoiceChip(label: Text('$m min'), selected: s.lullabyMin == m, onSelected: (_) => s.lullabyMin = m),
              ]),
              Row(children: [
                const Icon(Icons.volume_down, size: 18, color: C.muted),
                Expanded(child: Slider(value: s.lullabyVolume, onChanged: (v) => s.lullabyVolume = v)),
              ]),
              const Text('Wycisza się łagodnie. Liczenie dźwięków rusza dopiero po jej końcu.',
                  style: TextStyle(fontSize: 12, color: C.muted)),
            ],
          ]),
        ),
        const SizedBox(height: 20),

        SizedBox(
          height: 64,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: C.moon,
              foregroundColor: C.bg,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
            onPressed: starting ? null : _start,
            icon: const Icon(Icons.nightlight_round),
            label: Text(starting ? 'Uruchamiam…' : 'Idę spać', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Połóż telefon na materacu obok poduszki, ekranem do góry, najlepiej na ładowarce.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: C.muted),
        ),
        const SizedBox(height: 20),

        // --- Dług snu i ostatnia noc ---
        if (recent.isNotEmpty)
          TileGrid(children: [
            StatTile(
              label: debt >= 0 ? 'Dług snu (14 dni)' : 'Nadwyżka snu',
              value: durHM(debt.abs()),
              color: debt > 120 ? C.danger : C.gas,
            ),
            StatTile(
              label: 'Cel snu',
              value: durHM(s.sleepGoalMin),
              sub: 'średnio ${durHM(avg(recent.take(7).map((n) => n.durationMin)))} (7 nocy)',
            ),
          ]),
        if (last != null) ...[
          const SizedBox(height: 12),
          Card(
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => widget.onOpenNight(last.id!),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  ScoreRing(score: last.score, size: 76),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Ostatnia noc · ${dayLabel(last.start)}', style: const TextStyle(color: C.muted, fontSize: 12)),
                      const SizedBox(height: 4),
                      Text('💨 ${fartsLabel(last.fartCount)}',
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: C.gas)),
                      Text('${durHM(last.durationMin)} snu · chrapanie ${durHM(last.snoreMin)}',
                          style: const TextStyle(color: C.text)),
                    ]),
                  ),
                  const Icon(Icons.chevron_right, color: C.muted),
                ]),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
