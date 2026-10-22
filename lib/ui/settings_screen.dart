import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/db.dart';
import '../core/exchange_export.dart';
import '../core/fmt.dart';
import '../core/reminders.dart';
import '../core/settings.dart';
import 'theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final s = Settings.instance;

  @override
  void initState() {
    super.initState();
    s.addListener(_r);
  }

  @override
  void dispose() {
    s.removeListener(_r);
    super.dispose();
  }

  void _r() => setState(() {});

  Widget _head(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(t.toUpperCase(),
            style: const TextStyle(fontSize: 12, letterSpacing: 1.2, color: C.muted, fontWeight: FontWeight.w700)),
      );

  Widget _choice<T>(String title, T value, Map<T, String> options, void Function(T) set) => ListTile(
        title: Text(title),
        trailing: DropdownButton<T>(
          value: value,
          underline: const SizedBox(),
          items: [for (final e in options.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) {
            if (v != null) set(v);
          },
        ),
      );

  Future<void> _pickBedtime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: s.bedtimeHour, minute: s.bedtimeMinute),
      builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    if (t == null) return;
    s.bedtimeHour = t.hour;
    s.bedtimeMinute = t.minute;
    await Reminders.sync();
  }

  Future<void> _editTags() async {
    final ctl = TextEditingController();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.surface,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(c).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Twoje tagi', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final t in s.tags)
                InputChip(
                  label: Text('#$t'),
                  onDeleted: () => set(() => s.tags = [...s.tags]..remove(t)),
                ),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              decoration: const InputDecoration(hintText: 'Nowy tag, np. grochówka', prefixText: '#'),
              onSubmitted: (v) {
                final t = v.trim().replaceAll('#', '').toLowerCase();
                if (t.isNotEmpty && !s.tags.contains(t)) set(() => s.tags = [...s.tags, t]);
                ctl.clear();
              },
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text('Ustawienia', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        ),

        _head('Budzik'),
        Card(
          child: Column(children: [
            _choice<int>('Drzemka', s.snoozeMin, {5: '5 min', 10: '10 min', 15: '15 min'}, (v) => s.snoozeMin = v),
            _choice<int>('Narastanie głośności', s.rampSec,
                {15: '15 s', 30: '30 s', 60: '1 min', 120: '2 min', 300: '5 min'}, (v) => s.rampSec = v),
            SwitchListTile(title: const Text('Wibracje'), value: s.alarmVibrate, onChanged: (v) => s.alarmVibrate = v),
            _choice<String>('Zadanie przy wyłączaniu', s.captcha,
                {'none': 'Brak', 'math': 'Matematyka', 'shake': 'Potrząśnij'}, (v) => s.captcha = v),
            if (s.captcha == 'math')
              _choice<int>('Liczba działań', s.mathProblems, {1: '1', 2: '2', 3: '3', 5: '5'}, (v) => s.mathProblems = v),
            if (s.captcha == 'shake')
              _choice<int>('Liczba potrząśnięć', s.shakeCount, {15: '15', 30: '30', 50: '50'}, (v) => s.shakeCount = v),
          ]),
        ),

        _head('Wykrywanie'),
        Card(
          child: Column(children: [
            ListTile(
              title: const Text('Czułość na wiatry 💨'),
              subtitle: Slider(
                value: s.fartSensitivity,
                divisions: 10,
                label: '${(s.fartSensitivity * 100).round()}%',
                onChanged: (v) => s.fartSensitivity = v,
              ),
            ),
            ListTile(
              title: const Text('Czułość na chrapanie 😴'),
              subtitle: Slider(
                value: s.snoreSensitivity,
                divisions: 10,
                label: '${(s.snoreSensitivity * 100).round()}%',
                onChanged: (v) => s.snoreSensitivity = v,
              ),
            ),
            SwitchListTile(title: const Text('Mówienie przez sen'), value: s.detectTalk, onChanged: (v) => s.detectTalk = v),
            SwitchListTile(title: const Text('Kaszel'), value: s.detectCough, onChanged: (v) => s.detectCough = v),
            SwitchListTile(
              title: const Text('Nagrywaj krótkie klipy'),
              subtitle: const Text('Kilka sekund wokół zdarzenia — do odsłuchu i weryfikacji rano'),
              value: s.recordClips,
              onChanged: (v) => s.recordClips = v,
            ),
            SwitchListTile(
              title: const Text('Anty-chrapanie'),
              subtitle: const Text('Delikatne wibracje, gdy chrapiesz dłużej niż chwilę'),
              value: s.antiSnore,
              onChanged: (v) => s.antiSnore = v,
            ),
            _choice<int>('Pomiar światła (Android)', s.luxIntervalSec,
                {30: 'co 30 s', 60: 'co 1 min', 300: 'co 5 min'}, (v) => s.luxIntervalSec = v),
            ListTile(
              title: Text('Kalibracja hałasu: ${s.micOffset >= 92 ? '+' : ''}${(s.micOffset - 92).round()} dB'),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Slider(
                  value: s.micOffset,
                  min: 72,
                  max: 112,
                  divisions: 40,
                  label: '${(s.micOffset - 92).round()} dB',
                  onChanged: (v) => s.micOffset = v,
                ),
                const Text(
                  'Mikrofony telefonów różnią się czułością. Jeśli w cichej sypialni pokazuje się wyraźnie więcej '
                  'niż ~25–30 dB, przesuń w lewo; jeśli mniej — w prawo. Działa też wstecz dla zapisanych nocy.',
                  style: TextStyle(fontSize: 11, color: C.muted),
                ),
              ]),
            ),
          ]),
        ),

        _head('Sen'),
        Card(
          child: Column(children: [
            _choice<int>('Cel snu', s.sleepGoalMin,
                {for (var m = 360; m <= 600; m += 30) m: durHM(m)}, (v) => s.sleepGoalMin = v),
            _choice<int>('Opóźniony start nasłuchu', s.delayStartMin,
                {0: 'brak', 5: '5 min', 10: '10 min', 15: '15 min', 30: '30 min'}, (v) => s.delayStartMin = v),
            SwitchListTile(
              title: const Text('Przypomnienie o pójściu spać'),
              subtitle: Text('codziennie o ${two(s.bedtimeHour)}:${two(s.bedtimeMinute)}'),
              value: s.bedtimeReminder,
              onChanged: (v) async {
                s.bedtimeReminder = v;
                await Reminders.sync();
              },
            ),
            if (s.bedtimeReminder)
              ListTile(title: const Text('Godzina przypomnienia'), trailing: const Icon(Icons.schedule), onTap: _pickBedtime),
            SwitchListTile(
              title: const Text('Ekran nie gaśnie w nocy'),
              subtitle: const Text('Przydatne na ładowarce; na iPhonie poprawia pomiar światła'),
              value: s.keepScreenOn,
              onChanged: (v) => s.keepScreenOn = v,
            ),
          ]),
        ),

        _head('Tagi'),
        Card(
          child: ListTile(
            title: const Text('Edytuj listę tagów'),
            subtitle: Text(s.tags.map((t) => '#$t').join(' '), maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editTags,
          ),
        ),

        _head('Dane'),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.audio_file_outlined),
              title: const Text('Usuń wszystkie nagrania'),
              subtitle: const Text('Liczniki i wykresy zostają'),
              onTap: () async {
                final n = await Db.instance.deleteAllClips();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Usunięto nagrania: $n')));
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('Eksport wiatrów do Kreski'),
              subtitle: const Text('Plik do porównania z ręcznymi wpisami FF (cała historia)'),
              onTap: () async {
                final x = await exportFartExchange();
                if (!mounted) return;
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('Noce: ${x.nights} · wiatry: ${x.farts}')));
                await SharePlus.instance
                    .share(ShareParams(files: [XFile(x.file.path)], subject: 'Nocny Licznik – wiatry'));
              },
            ),
            const ListTile(
              leading: Icon(Icons.lock_outline),
              title: Text('Prywatność'),
              subtitle: Text('Wszystko zostaje na telefonie. Rozpoznawanie dźwięków (model YAMNet) działa offline.'),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        const Center(child: Text('Nocny Licznik 2.1', style: TextStyle(color: C.muted, fontSize: 12))),
      ],
    );
  }
}
