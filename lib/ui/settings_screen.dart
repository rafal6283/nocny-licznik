import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bakometr_native/bakometr_native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/cpap_import.dart';
import '../core/db.dart';
import '../core/exchange_export.dart';
import '../core/fmt.dart';
import '../core/health_sync.dart';
import '../core/reminders.dart';
import '../core/resmed_import.dart';
import '../core/settings.dart';
import '../core/weather.dart';
import 'cloud_screen.dart';
import 'diagnostics_screen.dart';
import 'sonar_test_screen.dart';
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

  Future<void> _pickPlace() async {
    final ctl = TextEditingController();
    var results = <Place>[];
    var busy = false;
    String? err;
    final picked = await showModalBottomSheet<Place>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.surface,
      builder: (c) => StatefulBuilder(
        builder: (c, set) {
          Future<void> go() async {
            if (ctl.text.trim().length < 2) return;
            set(() {
              busy = true;
              err = null;
            });
            try {
              results = await WeatherService.search(ctl.text);
              if (results.isEmpty) err = 'Nie znaleziono.';
            } catch (e) {
              err = 'Brak połączenia z internetem.';
            }
            set(() => busy = false);
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(c).viewInsets.bottom),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Miejscowość', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              TextField(
                controller: ctl,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'np. Kraków',
                  suffixIcon: busy
                      ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2))
                      : IconButton(icon: const Icon(Icons.search), onPressed: go),
                ),
                onSubmitted: (_) => go(),
              ),
              if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!)),
              for (final r in results)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(r.name),
                  subtitle: Text(r.detail),
                  onTap: () => Navigator.pop(c, r),
                ),
              if (Settings.instance.weatherReady)
                TextButton(
                  onPressed: () async {
                    await Settings.instance.clearWeatherPlace();
                    if (c.mounted) Navigator.pop(c);
                  },
                  child: const Text('Wyłącz pogodę'),
                ),
            ]),
          );
        },
      ),
    );
    if (picked == null) return;
    await s.setWeatherPlace(picked.name, picked.lat, picked.lon);
    _snack('Pobieram pogodę dla zapisanych nocy…');
    final n = await WeatherService.backfill(limit: 400);
    _snack('${picked.name}: pogoda uzupełniona dla $n ${plural(n, 'nocy', 'nocy', 'nocy')}.');
  }

  Future<void> _importCpap() async {
    try {
      final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['csv', 'txt']);
      if (f == null) return;
      final bytes = await f.readAsBytes();
      final days = CpapImport.parse(utf8.decode(bytes, allowMalformed: true));
      if (days.isEmpty) {
        _snack('Nie rozpoznano kolumn „Date” i „AHI” w pliku.');
        return;
      }
      final n = await CpapImport.apply(days);
      _snack('Wczytano ${days.length} dni z aparatu · dopasowano do $n ${plural(n, 'nocy', 'nocy', 'nocy')}.');
    } catch (e) {
      _snack('Import nie powiódł się: $e');
    }
  }

  bool _sdBusy = false;

  /// Karta SD z ResMed AirSense 10/11: STR.edf + DATALOG (zdarzenia i przebiegi).
  Future<void> _importResmedSd() async {
    if (_sdBusy) return;
    final nights = await Db.instance.nights();
    if (nights.isEmpty) {
      _snack('Najpierw nagraj choć jedną noc — dane z aparatu są dopisywane do nagranych nocy.');
      return;
    }
    String ymd(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
    final first = nights.map((n) => n.start).reduce((a, b) => a.isBefore(b) ? a : b);
    final last = nights.map((n) => n.start).reduce((a, b) => a.isAfter(b) ? a : b);
    setState(() => _sdBusy = true);
    try {
      ResmedResult res;
      if (Platform.isAndroid) {
        final paths = await BakometrNative.pickCpapCard(
            from: ymd(first.subtract(const Duration(days: 1))), to: ymd(last.add(const Duration(days: 1))));
        if (paths == null) return;
        if (paths.isEmpty) {
          _snack('Nie znalazłem STR.edf ani folderu DATALOG. Wskaż główny folder karty SD z aparatu.');
          return;
        }
        res = await ResmedImport.importPaths(paths);
      } else {
        final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['edf']);
        if (picked.isEmpty) return;
        final files = <(String, Uint8List)>[];
        for (final f in picked) {
          files.add((f.name, await f.readAsBytes()));
        }
        res = await ResmedImport.importFiles(files);
      }
      if (res.problems.isNotEmpty && res.nightsSummary == 0 && res.nightsDetail == 0) {
        _snack(res.problems.first);
      } else if (res.nightsSummary == 0 && res.nightsDetail == 0) {
        _snack('Wczytano ${res.files} plików, ale żaden dzień z aparatu nie pasuje do nagranych nocy.');
      } else {
        _snack('Aparat: podsumowania dla ${res.nightsSummary} ${plural(res.nightsSummary, 'nocy', 'nocy', 'nocy')}, '
            'szczegóły dla ${res.nightsDetail} · ${res.events} zdarzeń'
            '${res.problems.isEmpty ? '' : ' · ${res.problems.length} plików pominięto'}.');
      }
    } catch (e) {
      _snack('Import z karty nie powiódł się: $e');
    } finally {
      if (mounted) setState(() => _sdBusy = false);
    }
  }

  void _snack(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

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

  Future<void> _setHealthConnect(bool on) async {
    if (!on) {
      s.healthConnect = false;
      return;
    }
    final status = await BakometrNative.healthConnectStatus();
    if (status == 'unavailable') {
      _snack('Health Connect nie jest dostępne na tym telefonie');
      return;
    }
    final ok = await BakometrNative.healthConnectRequestPermission();
    if (!ok) {
      _snack(status == 'update'
          ? 'Zainstaluj lub zaktualizuj Health Connect ze Sklepu Play i włącz ponownie'
          : 'Bez zgody na zapis snu w Health Connect nie da się tego włączyć');
      return;
    }
    s.healthConnect = true;
    await _pushAll();
  }

  Future<void> _setWatchData(bool on) async {
    if (!on) {
      setState(() => s.watchData = false);
      return;
    }
    final status = await BakometrNative.healthConnectStatus();
    if (status == 'unavailable') {
      _snack('Health Connect nie jest dostępne na tym telefonie');
      return;
    }
    final ok = await BakometrNative.healthConnectRequestReadPermission();
    if (!ok) {
      _snack(status == 'update'
          ? 'Zainstaluj lub zaktualizuj Health Connect ze Sklepu Play i włącz ponownie'
          : 'Bez zgody na odczyt tętna, SpO₂ i snu nie da się pobrać danych z zegarka');
      return;
    }
    setState(() => s.watchData = true);
    _snack('Gotowe. Dane z zegarka zobaczysz w szczegółach każdej nocy');
  }

  Future<void> _pushAll() async {
    final n = await HealthSync.pushAll();
    _snack(n < 0 ? 'Nie udało się zapisać nocy w Health Connect' : 'Zapisano w Health Connect nocy: $n');
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
            SwitchListTile(
              title: const Text('Liczenie wiatrów 💨'),
              subtitle: const Text('Rozpoznawanie i licznik puszczanych wiatrów (domyślnie wyłączone)'),
              value: s.detectFarts,
              onChanged: (v) async {
                s.detectFarts = v;
                // noce w Health Connect mają notatkę z liczbą wiatrów — przepisz je bez/z nią
                if (s.healthConnect) await HealthSync.pushAll();
              },
            ),
            if (s.detectFarts)
              ListTile(
                title: const Text('Czułość na wiatry'),
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

        if (Platform.isAndroid) ...[
          _head('Sonar'),
          Card(
            child: Column(children: [
              SwitchListTile(
                title: const Text('Sonar oddechu 📡'),
                subtitle: const Text(
                    'Głośnik nadaje niesłyszalny ton 19 kHz, mikrofon odbiera echo od klatki piersiowej: częstość '
                    'oddechu, ruch oraz przerwy i spłycenia oddechu bez dotyku. Telefon może leżeć na szafce, '
                    'najlepiej na ładowarce.'),
                value: s.sonarEnabled,
                onChanged: (v) => s.sonarEnabled = v,
              ),
              ListTile(
                leading: const Icon(Icons.sensors),
                title: const Text('Test sonaru'),
                subtitle: const Text('Sprawdź, czy Twój telefon go obsługuje, i zobacz oddech na żywo'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SonarTestScreen())),
              ),
            ]),
          ),
        ],

        _head('Pogoda'),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Text('🌦️', style: TextStyle(fontSize: 22)),
              title: Text(s.weatherReady ? s.weatherPlace : 'Ustaw miejscowość'),
              subtitle: const Text('Pogoda dla każdej nocy (Open-Meteo, bez konta). Wysyłane są tylko współrzędne '
                  'miejscowości — żadne dane o śnie.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _pickPlace,
            ),
            if (s.weatherReady)
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('Uzupełnij pogodę dla zapisanych nocy'),
                onTap: () async {
                  _snack('Pobieram pogodę…');
                  final n = await WeatherService.backfill(limit: 400);
                  _snack('Uzupełniono pogodę dla $n ${plural(n, 'nocy', 'nocy', 'nocy')}.');
                },
              ),
          ]),
        ),

        _head('CPAP'),
        Card(
          child: Column(children: [
            SwitchListTile(
              title: const Text('Śpię z aparatem CPAP'),
              subtitle: const Text('Domyślnie dla kolejnych nocy (zmienisz też na ekranie Noc)'),
              value: s.cpapDefault,
              onChanged: (v) => s.cpapDefault = v,
            ),
            ListTile(
              leading: _sdBusy
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sd_card_outlined),
              title: const Text('Importuj z karty SD (ResMed AirSense 10/11)'),
              subtitle: const Text('Wyjmij kartę z aparatu, włóż do czytnika (USB-C/OTG) i wskaż jej główny folder. '
                  'AHI z podziałem na rodzaje bezdechów, nieszczelność, ciśnienie, oddech i zdarzenia z godziną'),
              onTap: _importResmedSd,
            ),
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('Importuj dane z aparatu (CSV)'),
              subtitle: const Text('Eksport „Summary” z programu OSCAR (karta SD z ResMed, Philips i in.) — '
                  'AHI, nieszczelność i czas użycia trafią do odpowiednich nocy'),
              onTap: _importCpap,
            ),
          ]),
        ),

        _head('Diagnostyka'),
        Card(
          child: ListTile(
            leading: const Icon(Icons.health_and_safety_outlined),
            title: const Text('Praca w tle i przerwane noce'),
            subtitle: const Text('Optymalizacja baterii, powody zamknięcia aplikacji przez system'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DiagnosticsScreen())),
          ),
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
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('Kopia i rodzina (Koofr)'),
              subtitle: const Text('Kopia zapasowa i podgląd snu domowników — za zgodą obu stron'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CloudScreen())),
            ),
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
            if (HealthSync.supported) ...[
              SwitchListTile(
                secondary: const Icon(Icons.favorite_border),
                title: const Text('Zapisuj sen w Health Connect'),
                subtitle: const Text('Każda noc z fazami snu trafi do Health Connect – zobaczą ją np. Life Cycle i Fitbit'),
                value: s.healthConnect,
                onChanged: _setHealthConnect,
              ),
              if (s.healthConnect)
                ListTile(
                  leading: const Icon(Icons.sync),
                  title: const Text('Wyślij wszystkie noce teraz'),
                  subtitle: const Text('Ponowny zapis aktualizuje noce, nie tworzy duplikatów'),
                  onTap: _pushAll,
                ),
              SwitchListTile(
                secondary: const Icon(Icons.watch_outlined),
                title: const Text('Dane z zegarka'),
                subtitle: const Text('Tętno, SpO₂ i fazy snu z Health Connect, pokazywane przy każdej nocy. '
                    'Zegarek Huawei: zainstaluj Health Sync i włącz w nim przesyłanie do Health Connect'),
                value: s.watchData,
                onChanged: _setWatchData,
              ),
            ],
            if (s.detectFarts)
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
                    .share(ShareParams(files: [XFile(x.file.path)], subject: 'Rytm Snu – wiatry'));
              },
            ),
            const ListTile(
              leading: Icon(Icons.lock_outline),
              title: Text('Prywatność'),
              subtitle: Text('Wszystko zostaje na telefonie, chyba że sam włączysz zapis w Health Connect albo kopię/podgląd na Koofr (szyfrowane na telefonie). Rozpoznawanie dźwięków (model YAMNet) działa offline.'),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        const Center(child: Text('Rytm Snu 2.8', style: TextStyle(color: C.muted, fontSize: 12))),
      ],
    );
  }
}
