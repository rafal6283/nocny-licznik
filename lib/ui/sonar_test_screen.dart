import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';

import '../core/audio_synth.dart';
import '../core/settings.dart';
import '../engine/night_engine.dart';
import '../engine/sonar.dart';
import 'charts.dart';
import 'theme.dart';

/// Sprawdza, czy głośnik i mikrofon tego telefonu radzą sobie z sonarem 19 kHz,
/// i pokazuje na żywo przebieg oddechu.
class SonarTestScreen extends StatefulWidget {
  const SonarTestScreen({super.key});

  @override
  State<SonarTestScreen> createState() => _SonarTestScreenState();
}

class _SonarTestScreenState extends State<SonarTestScreen> {
  final s = Settings.instance;
  AudioRecorder? rec;
  AudioPlayer? player;
  StreamSubscription<Uint8List>? sub;
  SonarProcessor? sonar;
  Timer? ui;
  bool running = false;
  String? error;
  String? usedSource;
  final List<double> ampHist = [];

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  Future<void> _start() async {
    if (NightEngine.instance.isActive) {
      setState(() => error = 'Najpierw zakończ trwającą noc.');
      return;
    }
    setState(() {
      error = null;
      ampHist.clear();
    });
    rec = AudioRecorder();
    if (!await rec!.hasPermission()) {
      setState(() => error = 'Brak dostępu do mikrofonu.');
      return;
    }
    Stream<Uint8List>? stream;
    for (final src in [NightEngine.sonarSourceOf(s.sonarSource), AndroidAudioSource.defaultSource]) {
      try {
        stream = await rec!.startStream(RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: SonarProcessor.fs,
          numChannels: 1,
          androidConfig: AndroidRecordConfig(audioSource: src),
        ));
        usedSource = src.name;
        break;
      } catch (_) {
        try {
          await rec!.stop();
        } catch (_) {}
      }
    }
    if (stream == null) {
      setState(() => error = 'Nie udało się uruchomić mikrofonu 48 kHz.');
      return;
    }
    sonar = SonarProcessor()
      ..onSecond = (sec) {
        ampHist.add(sec.amplitude);
        if (ampHist.length > 120) ampHist.removeAt(0);
      };
    sub = stream.listen((b) {
      final n = b.length ~/ 2;
      final bd = ByteData.sublistView(b);
      final x = Float32List(n);
      for (var i = 0; i < n; i++) {
        x[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
      }
      sonar?.feed(x);
    });
    try {
      player = AudioPlayer();
      await player!.setFilePath(await AudioSynth.sonarTone(s.sonarVolume));
      await player!.setLoopMode(LoopMode.one);
      unawaited(player!.play());
    } catch (e) {
      setState(() => error = 'Nie udało się odtworzyć tonu: $e');
    }
    ui = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
    setState(() => running = true);
  }

  Future<void> _stop() async {
    ui?.cancel();
    await sub?.cancel();
    sub = null;
    try {
      await rec?.stop();
      await rec?.dispose();
    } catch (_) {}
    rec = null;
    try {
      await player?.stop();
      await player?.dispose();
    } catch (_) {}
    player = null;
    if (mounted) setState(() => running = false);
  }

  @override
  Widget build(BuildContext context) {
    final sn = sonar;
    final q = sn?.quality ?? -99;
    final wave = sn?.waveform() ?? const <double>[];
    final rate = sn?.breathRate;
    final (qText, qColor) = !running
        ? ('—', C.muted)
        : q >= 15
            ? ('bardzo dobry (${q.round()} dB)', C.gas)
            : q >= 6
                ? ('wystarczający (${q.round()} dB)', C.moon)
                : ('za słaby (${q.round()} dB)', C.danger);

    return Scaffold(
      appBar: AppBar(title: const Text('Test sonaru')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
          'Połóż telefon na szafce lub materacu 30–100 cm od klatki piersiowej, głośnikiem w Twoją stronę. '
          'Leż spokojnie i oddychaj normalnie przez ok. minutę. Ton 19 kHz jest dla większości dorosłych '
          'niesłyszalny (zwierzęta mogą go słyszeć).',
          style: TextStyle(color: C.muted, height: 1.4),
        ),
        const SizedBox(height: 16),
        TileGrid(columns: 2, children: [
          StatTile(label: 'Sygnał sonaru', value: qText, color: qColor),
          StatTile(
            label: 'Oddech',
            value: rate != null ? '${rate.toStringAsFixed(1)} /min' : (running ? 'liczę…' : '—'),
            color: C.light,
          ),
          StatTile(label: 'Ruch', value: running ? ((sn?.moving ?? false) ? 'tak' : 'spokój') : '—'),
          StatTile(label: 'Źródło mikrofonu', value: usedSource ?? s.sonarSource),
        ]),
        const SizedBox(height: 12),
        Section(
          title: 'Oddech na żywo (30 s)',
          child: wave.length < 50
              ? SizedBox(
                  height: 140,
                  child: Center(
                    child: Text(running ? 'Zbieram dane (ok. 10 s)…' : 'Naciśnij „Start”.',
                        style: const TextStyle(color: C.muted)),
                  ),
                )
              : LineSeriesChart(values: wave, color: C.light, height: 140, showAverage: false, zeroBased: false),
        ),
        const SizedBox(height: 12),
        Section(
          title: 'Siła ruchu oddechowego (2 min)',
          child: LineSeriesChart(
              values: ampHist.isEmpty ? const [] : List<double>.from(ampHist),
              color: C.gas,
              height: 110,
              showAverage: false),
        ),
        const SizedBox(height: 12),
        Section(
          title: 'Ustawienia sonaru',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('Źródło mikrofonu')),
              DropdownButton<String>(
                value: s.sonarSource,
                underline: const SizedBox(),
                items: const [
                  DropdownMenuItem(value: 'unprocessed', child: Text('Surowe (zalecane)')),
                  DropdownMenuItem(value: 'voiceRecognition', child: Text('Rozpoznawanie mowy')),
                  DropdownMenuItem(value: 'mic', child: Text('Mikrofon')),
                  DropdownMenuItem(value: 'defaultSource', child: Text('Domyślne')),
                ],
                onChanged: running ? null : (v) => setState(() => s.sonarSource = v ?? 'unprocessed'),
              ),
            ]),
            Text('Głośność tonu: ${(s.sonarVolume * 100).round()}%'),
            Slider(
              value: s.sonarVolume,
              min: 0.2,
              max: 0.95,
              onChanged: running ? null : (v) => setState(() => s.sonarVolume = v),
            ),
            const Text(
              'Głośność multimediów w telefonie też musi być podkręcona (min. ok. 60%). '
              'Jeśli sygnał jest za słaby, zmień źródło mikrofonu albo zwiększ głośność.',
              style: TextStyle(fontSize: 11, color: C.muted),
            ),
          ]),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(error!, style: const TextStyle(color: C.danger)),
          ),
        const SizedBox(height: 16),
        SizedBox(
          height: 54,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: running ? C.surface2 : const Color(0xFF5EC8F2), foregroundColor: running ? C.text : C.bg),
            onPressed: running ? _stop : _start,
            icon: Icon(running ? Icons.stop : Icons.sensors),
            label: Text(running ? 'Stop' : 'Start', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: 10),
        if (running && q >= 6 && rate != null)
          const Text('✓ Twój telefon obsługuje sonar. Włącz go w Ustawieniach → Sonar.',
              textAlign: TextAlign.center, style: TextStyle(color: C.gas)),
      ]),
    );
  }
}
