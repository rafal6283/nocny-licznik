import 'dart:math';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../core/bus.dart';
import '../core/db.dart';
import '../core/fmt.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../core/stats_util.dart';
import '../core/weather.dart';
import '../engine/night_engine.dart';
import 'charts.dart';
import 'theme.dart';

class NightDetailScreen extends StatefulWidget {
  final int nightId;
  const NightDetailScreen({super.key, required this.nightId});

  @override
  State<NightDetailScreen> createState() => _NightDetailScreenState();
}

class _NightDetailScreenState extends State<NightDetailScreen> {
  Night? n;
  List<MinuteSample> ms = [];
  List<SoundEvent> evs = [];
  SoundType? filter = Settings.instance.detectFarts ? SoundType.fart : SoundType.snore;
  bool stepView = false;
  final player = AudioPlayer();
  int? playingId;
  final noteCtl = TextEditingController();
  Timer? _noteDebounce;

  @override
  void initState() {
    super.initState();
    player.playerStateStream.listen((st) {
      if (st.processingState == ProcessingState.completed && mounted) setState(() => playingId = null);
    });
    _load();
  }

  @override
  void dispose() {
    player.dispose();
    _noteDebounce?.cancel();
    noteCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final night = await Db.instance.night(widget.nightId);
    final m = await Db.instance.minutes(widget.nightId);
    final e = await Db.instance.events(widget.nightId);
    if (!mounted) return;
    setState(() {
      n = night;
      ms = m;
      evs = e;
      noteCtl.text = night?.note ?? '';
    });
  }

  Future<void> _play(SoundEvent e) async {
    if (playingId == e.id) {
      await player.stop();
      setState(() => playingId = null);
      return;
    }
    try {
      await player.setFilePath(e.clipPath!);
      setState(() => playingId = e.id);
      await player.play();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nie można odtworzyć nagrania')));
      }
    }
  }

  Future<void> _verify(SoundEvent e, bool? v) async {
    e.verified = v;
    await Db.instance.updateEvent(e);
    await NightEngine.summarize(n!, ms, evs);
    setState(() {});
  }

  Future<void> _save() async {
    await Db.instance.updateNight(n!);
    dataChanged();
    setState(() {});
  }

  Future<void> _editTags() async {
    final all = {...Settings.instance.tags, ...n!.tags}.toList();
    final sel = {...n!.tags};
    await showModalBottomSheet(
      context: context,
      backgroundColor: C.surface,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Tagi tej nocy', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final t in all)
                FilterChip(
                  label: Text('#$t'),
                  selected: sel.contains(t),
                  onSelected: (v) => set(() => v ? sel.add(t) : sel.remove(t)),
                ),
            ]),
            const SizedBox(height: 12),
          ]),
        ),
      ),
    );
    n!.tags = sel.toList();
    await _save();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Usunąć tę noc?'),
        content: const Text('Znikną też jej nagrania.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Anuluj')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: C.danger),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Usuń')),
        ],
      ),
    );
    if (ok != true) return;
    await Db.instance.deleteNight(widget.nightId);
    dataChanged();
    if (mounted) Navigator.pop(context);
  }

  Widget _weatherCard(Night night) {
    String f(double? v, String unit, [int dec = 0]) => v == null ? '—' : '${v.toStringAsFixed(dec)}$unit';
    final trend = night.wPressTrend;
    final mp = night.moonPhase;
    return Section(
      title: 'Pogoda tej nocy 🌦️',
      trailing: Settings.instance.weatherPlace.isNotEmpty
          ? Text(Settings.instance.weatherPlace, style: const TextStyle(color: C.muted, fontSize: 12))
          : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (night.wTemp != null)
          TileGrid(columns: 3, children: [
            StatTile(label: 'Temperatura', value: f(night.wTemp, '°C', 1), color: const Color(0xFFFF9E7A)),
            StatTile(label: 'Wilgotność', value: f(night.wHum, '%')),
            StatTile(
              label: 'Ciśnienie',
              value: f(night.wPress, ' hPa'),
              sub: trend == null
                  ? null
                  : '${trend >= 0 ? '↑' : '↓'} ${trend.abs().toStringAsFixed(1)} hPa / 24 h',
              color: const Color(0xFFB59BFF),
            ),
            StatTile(label: 'Wiatr maks.', value: f(night.wWind, ' km/h')),
            StatTile(label: 'Opady', value: f(night.wRain, ' mm', 1), color: C.light),
            StatTile(label: 'Zachmurzenie', value: f(night.wCloud, '%')),
          ])
        else
          const Text('Brak danych pogodowych — ustaw miejscowość w Ustawieniach → Pogoda.',
              style: TextStyle(color: C.muted, fontSize: 12)),
        if (mp != null) ...[
          const SizedBox(height: 10),
          Text(
              '${WeatherService.moonEmoji(mp)} Księżyc: ${WeatherService.moonName(mp)} · '
              'oświetlenie ${(WeatherService.illumination(mp) * 100).round()}%',
              style: const TextStyle(fontSize: 13)),
        ],
      ]),
    );
  }

  Widget _noiseCard(Night night) {
    final s = Settings.instance;
    final pts = ms.where((m) => m.noiseDb > -120).toList();
    final avgSpl = s.spl(night.avgNoise!);
    final maxSpl = night.maxNoise != null ? s.spl(night.maxNoise!) : null;
    final loud = pts.where((m) => s.spl(m.noiseDb) > 35).length;
    return Section(
      title: 'Hałas w sypialni 🔊',
      trailing: Text('śr. ${avgSpl.round()} dB${maxSpl != null ? ' · maks. ${maxSpl.round()} dB' : ''}',
          style: const TextStyle(color: C.muted, fontSize: 12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        LineSeriesChart(
          values: [for (final m in pts) s.spl(m.noiseDb)],
          labels: [for (final m in pts) hhmm(m.ts)],
          color: const Color(0xFF3DDC97),
          zeroBased: false,
          fmt: (v) => '${v.round()} dB',
        ),
        const SizedBox(height: 6),
        Text(
          avgSpl <= 30
              ? 'Cicho — średni poziom w zaleceniach WHO dla sypialni (do ok. 30 dB).'
              : 'Głośniej niż zalecane dla sypialni (WHO: ok. 30 dB). '
                  'Powyżej 35 dB przez ${durHM(loud)}.',
          style: const TextStyle(fontSize: 12),
        ),
        const Text('Pomiar mikrofonem telefonu — orientacyjny; kalibrację zmienisz w Ustawieniach.',
            style: TextStyle(fontSize: 11, color: C.muted)),
      ]),
    );
  }

  Widget _cpapCard(Night night) {
    String f(double? v, String unit, [int dec = 1]) => v == null ? '—' : '${v.toStringAsFixed(dec)}$unit';
    final ahi = night.cpapAhi;
    return Section(
      title: 'Aparat CPAP 😷',
      trailing: TextButton(onPressed: () => _editCpap(night), child: Text(ahi == null ? 'Dodaj dane' : 'Edytuj')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TileGrid(columns: 3, children: [
          StatTile(
            label: 'AHI z aparatu',
            value: f(ahi, ''),
            sub: ahi != null ? apneaCategory(ahi) : null,
            color: ahi == null ? C.muted : (ahi < 5 ? C.gas : (ahi < 15 ? C.moon : C.danger)),
          ),
          StatTile(label: 'Nieszczelność', value: f(night.cpapLeak, ' l/min')),
          StatTile(
              label: 'Użycie', value: night.cpapUsageMin == null ? '—' : durHM(night.cpapUsageMin!)),
        ]),
        const SizedBox(height: 8),
        const Text(
          'AHI odczytasz z wyświetlacza aparatu, aplikacji producenta (np. myAir, DreamMapper) albo zaimportujesz '
          'z pliku CSV programu OSCAR (Ustawienia → CPAP). Przy dobrze dobranym ciśnieniu AHI zwykle jest < 5.',
          style: TextStyle(fontSize: 11, color: C.muted),
        ),
      ]),
    );
  }

  Future<void> _editCpap(Night night) async {
    final ahi = TextEditingController(text: night.cpapAhi?.toString() ?? '');
    final leak = TextEditingController(text: night.cpapLeak?.toString() ?? '');
    final use = TextEditingController(
        text: night.cpapUsageMin == null ? '' : (night.cpapUsageMin! / 60).toStringAsFixed(1));
    double? num(String s) => double.tryParse(s.replaceAll(',', '.').trim());
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Dane z aparatu CPAP'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: ahi,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'AHI (zdarzenia/h)')),
          TextField(
              controller: leak,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Nieszczelność (l/min) — opcjonalnie')),
          TextField(
              controller: use,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Czas użycia (godziny) — opcjonalnie')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Zapisz')),
        ],
      ),
    );
    if (ok != true) return;
    night.cpap = true;
    night.cpapAhi = num(ahi.text);
    night.cpapLeak = num(leak.text);
    final h = num(use.text);
    night.cpapUsageMin = h == null ? null : (h * 60).round();
    await _save();
  }

  Widget _breathRateCard() {
    final pts = ms.where((m) => m.breathRate != null).toList();
    if (pts.length < 3) return const SizedBox();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Section(
        title: 'Częstość oddechu (sonar)',
        trailing: Text(
            'śr. ${(pts.map((m) => m.breathRate!).reduce((a, b) => a + b) / pts.length).toStringAsFixed(1)}/min',
            style: const TextStyle(color: C.muted, fontSize: 12)),
        child: LineSeriesChart(
          values: [for (final m in pts) m.breathRate],
          labels: [for (final m in pts) hhmm(m.ts)],
          color: C.light,
          zeroBased: false,
          fmt: (v) => v.toStringAsFixed(0),
        ),
      ),
    );
  }

  Widget _breathingCard(Night night) {
    final idx = night.apneaIndex;
    final color = idx < 5 ? C.gas : (idx < 15 ? C.moon : C.danger);
    final enough = night.durationMin >= 120;
    return Section(
      title: 'Oddech w nocy 🫁',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(idx.toStringAsFixed(1),
              style: TextStyle(fontSize: 36, fontWeight: FontWeight.w800, color: color, height: 1)),
          const SizedBox(width: 8),
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text('zdarzeń / godz. snu', style: TextStyle(color: C.muted)),
          ),
        ]),
        const SizedBox(height: 6),
        Text(
          !enough
              ? 'Za krótka noc na wiarygodny wskaźnik (potrzeba min. 2 h snu).'
              : night.sonar
                  ? 'Wskaźnik ${apneaCategory(idx)} · sonar: ${night.apneaCount} '
                      '${plural(night.apneaCount, 'przerwa', 'przerwy', 'przerw')} i ${night.hypopneaCount} '
                      '${plural(night.hypopneaCount, 'spłycenie', 'spłycenia', 'spłyceń')} oddechu ≥10 s'
                      '${night.breathRate != null ? ' · średnio ${night.breathRate!.toStringAsFixed(1)} oddechu/min' : ''}'
                  : night.cpap
                      ? 'Noc z CPAP: dźwiękowy detektor przerw jest wyłączony (szum aparatu). '
                          'Wiarygodny wskaźnik daje sam aparat — patrz karta CPAP — albo sonar.'
                      : 'Wskaźnik ${apneaCategory(idx)} · ${night.apneaCount} '
                          '${plural(night.apneaCount, 'przerwa', 'przerwy', 'przerw')} ≥10 s zakończonych westchnieniem lub chrapnięciem',
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 8,
            child: Row(children: [
              Expanded(flex: 5, child: Container(color: C.gas.withValues(alpha: 0.8))),
              Expanded(flex: 10, child: Container(color: C.moon.withValues(alpha: 0.8))),
              Expanded(flex: 15, child: Container(color: C.wake.withValues(alpha: 0.8))),
              Expanded(flex: 10, child: Container(color: C.danger.withValues(alpha: 0.8))),
            ]),
          ),
        ),
        LayoutBuilder(
          builder: (c, b) => Padding(
            padding: EdgeInsets.only(
                left: (b.maxWidth * min(idx, 40.0) / 40 - 6).clamp(0.0, max(0.0, b.maxWidth - 12)).toDouble()),
            child: Icon(Icons.arrow_drop_up, color: color, size: 18),
          ),
        ),
        const Text(
          'To orientacyjne wskazanie, nie diagnoza. Bez sonaru wykrywane są głównie przerwy u osób, które chrapią. '
          'Jeśli wskaźnik często przekracza 15, ktoś zauważa u Ciebie przerwy w oddychaniu albo budzisz się '
          'niewyspany — porozmawiaj z lekarzem o badaniu snu (poligrafia/polisomnografia).',
          style: TextStyle(fontSize: 11, color: C.muted),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final night = n;
    if (night == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final end = night.end ?? (ms.isNotEmpty ? ms.last.ts : night.start);
    final farts = evs.where((e) => e.type == SoundType.fart && e.counts).toList();
    final hasLux = ms.any((m) => m.lux != null);
    final clips = evs.where((e) => e.clipPath != null && (filter == null || e.type == filter)).toList();

    // Rozkład bąków na godziny nocy
    final hours = <int>[];
    var h = DateTime(night.start.year, night.start.month, night.start.day, night.start.hour);
    while (h.isBefore(end)) {
      hours.add(h.hour);
      h = h.add(const Duration(hours: 1));
    }
    final perHour = List<double>.filled(hours.length, 0);
    for (final f in farts) {
      final i = f.ts.difference(DateTime(night.start.year, night.start.month, night.start.day, night.start.hour)).inHours;
      if (i >= 0 && i < perHour.length) perHour[i]++;
    }
    var peak = -1;
    for (var i = 0; i < perHour.length; i++) {
      if (perHour[i] > 0 && (peak < 0 || perHour[i] > perHour[peak])) peak = i;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(dayLabel(night.start)),
        actions: [IconButton(onPressed: _delete, icon: const Icon(Icons.delete_outline))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          Section(
            child: Column(children: [
              Row(children: [
                ScoreRing(score: night.score),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (Settings.instance.detectFarts || night.fartCount > 0) ...[
                      Text('💨 ${night.fartCount}',
                          style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: C.gas, height: 1)),
                      Text(plural(night.fartCount, 'bąk', 'bąki', 'bąków'), style: const TextStyle(color: C.gas)),
                      const SizedBox(height: 6),
                      Text('${durHM(night.durationMin)} snu', style: const TextStyle(fontSize: 16)),
                    ] else ...[
                      Text(durHM(night.durationMin),
                          style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: C.text, height: 1)),
                      const Text('snu', style: TextStyle(color: C.muted)),
                      const SizedBox(height: 6),
                    ],
                    if (night.cpap || night.sonar)
                      Text([if (night.cpap) '😷 CPAP', if (night.sonar) '📡 sonar'].join(' · '),
                          style: const TextStyle(color: C.muted, fontSize: 12)),
                    Text('${hhmm(night.start)} → ${hhmm(end)} · w łóżku ${durHM(night.inBedMin)}',
                        style: const TextStyle(color: C.muted, fontSize: 12)),
                  ]),
                ),
              ]),
              const SizedBox(height: 16),
              StageBar(n: night),
            ]),
          ),
          if (night.micBlockedMin > 0) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: const Color(0xFF3A2A10), borderRadius: BorderRadius.circular(16)),
              child: Text(
                '⚠️ Przez ${durHM(night.micBlockedMin)} mikrofon był zajęty przez inną aplikację — '
                'w tym czasie dźwięki (wiatry, chrapanie, oddech) nie były liczone.',
                style: const TextStyle(color: C.moon, fontSize: 13),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Section(
            title: 'Wykres snu',
            trailing: SegmentedButton<bool>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: false, label: Text('Fala')),
                ButtonSegment(value: true, label: Text('Fazy')),
              ],
              selected: {stepView},
              onSelectionChanged: (v) => setState(() => stepView = v.first),
            ),
            child: stepView
                ? Hypnogram(minutes: ms)
                : SleepWaveGraph(
                    minutes: ms,
                    events: evs,
                    start: night.start,
                    end: end,
                    showFarts: Settings.instance.detectFarts || night.fartCount > 0),
          ),
          const SizedBox(height: 12),
          if (night.cpap) ...[
            _cpapCard(night),
            const SizedBox(height: 12),
          ],
          _breathingCard(night),
          _breathRateCard(),
          const SizedBox(height: 12),
          TileGrid(columns: 3, children: [
            StatTile(label: 'Zasypianie', value: durHM(night.latencyMin)),
            StatTile(label: 'Przebudzenia', value: '${night.awakenings}'),
            StatTile(label: 'Chrapanie', value: durHM(night.snoreMin), color: C.light),
            StatTile(label: 'Mówienie', value: '${night.talkCount}', color: C.rem),
            StatTile(label: 'Kaszel', value: '${night.coughCount}', color: C.wake),
            StatTile(label: 'Przerwy w oddechu', value: '${night.apneaCount}', color: C.danger),
            StatTile(label: 'Efektywność', value: '${night.inBedMin > 0 ? (night.durationMin * 100 / night.inBedMin).round() : 0}%'),
            StatTile(
              label: 'Hałas śr.',
              value: night.avgNoise != null ? '${Settings.instance.spl(night.avgNoise!).round()} dB' : '—',
              color: const Color(0xFF3DDC97),
            ),
            StatTile(
              label: 'Światło',
              value: night.avgLux != null ? luxLabel(night.avgLux) : (night.lightManual.isEmpty ? '—' : '✋'),
              sub: night.avgLux != null ? luxWord(night.avgLux) : lightBucketLabel(night.lightManual),
              color: C.moon,
            ),
          ]),
          const SizedBox(height: 12),
          if (hasLux)
            Section(
              title: 'Światło w pokoju',
              trailing: Text('maks. ${luxLabel(night.maxLux)}', style: const TextStyle(color: C.muted, fontSize: 12)),
              child: LineSeriesChart(
                values: ms.map((m) => m.lux).toList(),
                labels: [for (final m in ms) hhmm(m.ts)],
                logScale: true,
              ),
            ),
          if (hasLux) const SizedBox(height: 12),
          if (night.avgNoise != null) ...[
            _noiseCard(night),
            const SizedBox(height: 12),
          ],
          if (night.wTemp != null || night.moonPhase != null) ...[
            _weatherCard(night),
            const SizedBox(height: 12),
          ],
          if (farts.isNotEmpty)
            Section(
              title: 'Godzina szczytu',
              trailing: peak >= 0
                  ? Text('${two(hours[peak])}:00–${two((hours[peak] + 1) % 24)}:00',
                      style: const TextStyle(color: C.gas, fontWeight: FontWeight.w700))
                  : null,
              child: BarSeriesChart(values: perHour, labels: [for (final x in hours) '$x'], highlight: peak),
            ),
          if (farts.isNotEmpty) const SizedBox(height: 12),

          // --- Nagrania ---
          Section(
            title: 'Nagrania',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 6, children: [
                for (final t in SoundType.values)
                  if (t != SoundType.fart || Settings.instance.detectFarts || night.fartCount > 0)
                  ChoiceChip(
                    label: Text('${t.emoji} ${evs.where((e) => e.type == t && e.clipPath != null).length}'),
                    selected: filter == t,
                    onSelected: (_) => setState(() => filter = t),
                  ),
              ]),
              const SizedBox(height: 8),
              if (clips.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Brak nagrań tego typu.', style: TextStyle(color: C.muted)),
                ),
              for (final e in clips)
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(14)),
                  child: ListTile(
                    contentPadding: const EdgeInsets.only(left: 4, right: 4),
                    leading: IconButton(
                      icon: Icon(playingId == e.id ? Icons.stop_circle : Icons.play_circle, color: C.sound(e.type), size: 34),
                      onPressed: () => _play(e),
                    ),
                    title: Text('${hhmmss(e.ts)}  ${e.type.label}',
                        style: TextStyle(
                            decoration: e.verified == false ? TextDecoration.lineThrough : null,
                            color: e.verified == false ? C.muted : C.text)),
                    subtitle: Text('pewność ${(e.confidence * 100).round()}%',
                        style: const TextStyle(fontSize: 12, color: C.muted)),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: 'To było to',
                        icon: Icon(Icons.check_circle, color: e.verified == true ? C.gas : C.muted.withValues(alpha: 0.5)),
                        onPressed: () => _verify(e, e.verified == true ? null : true),
                      ),
                      IconButton(
                        tooltip: 'Fałszywy alarm',
                        icon: Icon(Icons.cancel, color: e.verified == false ? C.danger : C.muted.withValues(alpha: 0.5)),
                        onPressed: () => _verify(e, e.verified == false ? null : false),
                      ),
                    ]),
                  ),
                ),
              const SizedBox(height: 6),
              const Text('Odrzucone nagrania nie liczą się do wyniku nocy.',
                  style: TextStyle(fontSize: 11, color: C.muted)),
            ]),
          ),
          const SizedBox(height: 12),

          // --- Tagi, ocena, notatka ---
          Section(
            title: 'Tagi i notatka',
            trailing: IconButton(onPressed: _editTags, icon: const Icon(Icons.edit, size: 18)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (night.tags.isEmpty)
                const Text('Bez tagów', style: TextStyle(color: C.muted))
              else
                Wrap(spacing: 6, runSpacing: 6, children: [for (final t in night.tags) Chip(label: Text('#$t'))]),
              const SizedBox(height: 12),
              Row(children: [
                const Text('Jak się wyspałeś? ', style: TextStyle(color: C.muted)),
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(i <= night.rating ? Icons.star : Icons.star_border, color: C.moon),
                    onPressed: () {
                      night.rating = night.rating == i ? 0 : i;
                      _save();
                    },
                  ),
              ]),
              TextField(
                controller: noteCtl,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(hintText: 'Notatka (np. co było na kolację)', border: InputBorder.none),
                onChanged: (v) {
                  night.note = v;
                  _noteDebounce?.cancel();
                  _noteDebounce = Timer(const Duration(milliseconds: 600), _save);
                },
              ),
            ]),
          ),
        ],
      ),
    );
  }
}
