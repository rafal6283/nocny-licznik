import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../core/audio_synth.dart';
import '../core/settings.dart';
import '../engine/night_engine.dart';
import '../engine/sonar.dart';
import 'theme.dart';

/// 30-sekundowy test przed snem: czy telefon czuje ruch materaca, jak głośno jest w sypialni
/// i (jeśli włączony) czy sonar ma dobry sygnał.
class PlacementCheckScreen extends StatefulWidget {
  const PlacementCheckScreen({super.key});

  @override
  State<PlacementCheckScreen> createState() => _PlacementCheckScreenState();
}

enum _Phase { idle, still, move, done }

class _Result {
  final String title, text;
  final bool ok;
  final bool warn;
  const _Result(this.title, this.text, {this.ok = false, this.warn = false});
}

class _PlacementCheckScreenState extends State<PlacementCheckScreen> {
  static const stillSec = 14, moveSec = 10;
  final s = Settings.instance;
  _Phase phase = _Phase.idle;
  int sec = 0;
  Timer? timer;
  AudioRecorder? rec;
  AudioPlayer? player;
  StreamSubscription<Uint8List>? audioSub;
  StreamSubscription<AccelerometerEvent>? accSub;
  SonarProcessor? sonar;
  int sr = 16000;
  bool toneOn = false;
  String? error;

  // pomiary
  double? _ax, _ay, _az;
  double stillMotion = 0, moveMotion = 0;
  int stillJitter = 0, stillSamples = 0;
  double noiseSum = 0;
  int noiseN = 0;
  final List<double> sonarQ = [];
  List<_Result> results = [];

  bool get useSonar => s.sonarEnabled && NightEngine.instance.isActive == false;

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
      results = [];
      stillMotion = moveMotion = noiseSum = 0;
      stillJitter = stillSamples = noiseN = 0;
      sonarQ.clear();
      _ax = null;
      sec = 0;
      phase = _Phase.still;
    });
    accSub = accelerometerEventStream(samplingPeriod: SensorInterval.normalInterval).listen(_onAccel);

    rec = AudioRecorder();
    if (await rec!.hasPermission()) {
      sr = useSonar ? SonarProcessor.fs : 16000;
      final sources = useSonar
          ? [NightEngine.sonarSourceOf(s.sonarSource), AndroidAudioSource.defaultSource]
          : [AndroidAudioSource.defaultSource];
      Stream<Uint8List>? stream;
      for (final src in sources) {
        try {
          stream = await rec!.startStream(RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: sr,
            numChannels: 1,
            androidConfig: AndroidRecordConfig(audioSource: src),
          ));
          break;
        } catch (_) {
          try {
            await rec!.stop();
          } catch (_) {}
        }
      }
      if (stream != null) {
        if (useSonar) sonar = SonarProcessor();
        audioSub = stream.listen(_onAudio);
      } else {
        error = 'Nie udało się uruchomić mikrofonu.';
      }
    } else {
      error = 'Brak dostępu do mikrofonu — pomijam pomiar dźwięku.';
    }

    timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    sec++;
    // ton sonaru po 5 s pomiaru ciszy
    if (useSonar && sec == 5 && !toneOn) unawaited(_tone());
    if (useSonar && toneOn && sec > 8 && phase == _Phase.still) sonarQ.add(sonar?.quality ?? -99);
    if (sec == stillSec) phase = _Phase.move;
    if (sec >= stillSec + moveSec) {
      _finish();
      return;
    }
    if (mounted) setState(() {});
  }

  Future<void> _tone() async {
    toneOn = true;
    try {
      player = AudioPlayer();
      await player!.setFilePath(await AudioSynth.sonarTone(s.sonarVolume));
      await player!.setLoopMode(LoopMode.one);
      unawaited(player!.play());
    } catch (_) {}
  }

  void _onAccel(AccelerometerEvent e) {
    if (_ax != null) {
      final d = sqrt(pow(e.x - _ax!, 2) + pow(e.y - _ay!, 2) + pow(e.z - _az!, 2));
      if (phase == _Phase.still && sec >= 2) {
        stillSamples++;
        if (d > 0.08) {
          stillMotion += d;
          stillJitter++;
        }
      } else if (phase == _Phase.move && d > 0.08) {
        moveMotion += d;
      }
    }
    _ax = e.x;
    _ay = e.y;
    _az = e.z;
  }

  void _onAudio(Uint8List b) {
    final n = b.length ~/ 2;
    final bd = ByteData.sublistView(b);
    final x = Float32List(n);
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final v = bd.getInt16(i * 2, Endian.little) / 32768.0;
      x[i] = v;
      sum += v * v;
    }
    // poziom otoczenia tylko przed włączeniem tonu sonaru
    if (phase == _Phase.still && sec >= 1 && !toneOn && n > 0) {
      noiseSum += sum / n;
      noiseN++;
    }
    sonar?.feed(x);
  }

  void _finish() {
    final out = <_Result>[];
    // Materac
    final stillRate = stillSamples == 0 ? 0.0 : stillJitter / stillSamples;
    if (moveMotion >= 1.0 && moveMotion >= 4 * stillMotion + 0.3) {
      out.add(const _Result('Telefon czuje ruch materaca',
          'Ruchy w łóżku są dobrze widoczne — fazy snu będą liczone z akcelerometru.', ok: true));
    } else if (moveMotion < 0.3) {
      out.add(const _Result('Telefon nie czuje ruchu',
          'Wygląda na to, że telefon leży na szafce albo na twardym podłożu. Połóż go na materacu przy poduszce '
              '(ekranem w dół lub w górę, bez etui-portfela). Jeśli wolisz szafkę — włącz sonar, wtedy ruch widać z echa.',
          warn: true));
    } else {
      out.add(const _Result('Ruch słabo widoczny',
          'Telefon wyczuł niewiele. Przesuń go bliżej siebie (np. pod kołdrę przy poduszce, nie pod nią).',
          warn: true));
    }
    if (stillRate > 0.5) {
      out.add(const _Result('Telefon drży w spoczynku',
          'Nawet przy leżeniu bez ruchu czujnik widział drgania (pralka, wentylator, wibrujące podłoże?). '
              'To może zawyżać płytki sen.',
          warn: true));
    }
    // Hałas
    if (noiseN > 0) {
      final db = s.spl(10 * log(noiseSum / noiseN + 1e-12) / ln10);
      if (db <= 40) {
        out.add(_Result('Cicho (${db.round()} dB)', 'Dobre warunki do wykrywania chrapania i oddechu.', ok: true));
      } else if (db <= 52) {
        out.add(_Result('Umiarkowany szum (${db.round()} dB)',
            'Wykrywanie działa, ale cichy oddech może ginąć w tle${s.cpapDefault ? ' (z maską CPAP to normalne)' : ''}.',
            ok: true));
      } else {
        out.add(_Result('Głośno (${db.round()} dB)',
            'Wentylator, oczyszczacz lub aparat CPAP mocno szumią. Połóż telefon dalej od źródła szumu, '
                'bliżej głowy.',
            warn: true));
      }
    }
    // Sonar
    if (useSonar) {
      final q = sonarQ.isEmpty ? -99.0 : (sonarQ..sort())[sonarQ.length ~/ 2];
      if (q >= 15) {
        out.add(_Result('Sonar: bardzo dobry sygnał (${q.round()} dB)', 'Oddech i ruch z echa będą wiarygodne.', ok: true));
      } else if (q >= 6) {
        out.add(_Result('Sonar: wystarczający (${q.round()} dB)', 'Działa; mocniejszy sygnał da głośność multimediów ≥60%.', ok: true));
      } else {
        out.add(_Result('Sonar: za słaby sygnał',
            'Skieruj głośnik w stronę klatki piersiowej (30–100 cm), podkręć głośność multimediów albo zmień '
                'źródło mikrofonu w Ustawienia → Sonar → Test.',
            warn: true));
      }
    } else {
      out.add(const _Result('Sonar wyłączony',
          'Opcjonalnie: sonar mierzy oddech i przerwy w oddechu także wtedy, gdy telefon leży na szafce.'));
    }
    _stop();
    if (mounted) {
      setState(() {
        results = out;
        phase = _Phase.done;
      });
    }
  }

  Future<void> _stop() async {
    timer?.cancel();
    timer = null;
    await accSub?.cancel();
    accSub = null;
    await audioSub?.cancel();
    audioSub = null;
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
    toneOn = false;
    sonar = null;
  }

  @override
  Widget build(BuildContext context) {
    final running = phase == _Phase.still || phase == _Phase.move;
    final total = stillSec + moveSec;
    final (title, hint) = switch (phase) {
      _Phase.idle => (
          'Połóż telefon tak jak na noc',
          'Na materacu przy poduszce (albo na szafce, jeśli używasz sonaru). Połóż się, naciśnij „Start” i leż spokojnie. '
              'Po kilkunastu sekundach poproszę Cię o ruch.'
        ),
      _Phase.still => ('Leż spokojnie…', 'Mierzę ciszę w sypialni${useSonar ? ' i sygnał sonaru' : ''}.'),
      _Phase.move => ('Teraz przewróć się na bok', 'Albo kilka razy porusz ramieniem i nogą — sprawdzam, czy telefon to czuje.'),
      _Phase.done => ('Wynik', 'Możesz powtórzyć test po przełożeniu telefonu.'),
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Ustawienie telefonu')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(hint, style: const TextStyle(color: C.muted, height: 1.4)),
        const SizedBox(height: 16),
        if (running) ...[
          LinearProgressIndicator(value: sec / total, minHeight: 8),
          const SizedBox(height: 6),
          Text('${total - sec} s', textAlign: TextAlign.center, style: const TextStyle(color: C.muted)),
        ],
        for (final r in results)
          Card(
            child: ListTile(
              leading: Icon(r.ok ? Icons.check_circle : (r.warn ? Icons.warning_amber_rounded : Icons.info_outline),
                  color: r.ok ? C.gas : (r.warn ? C.moon : C.muted)),
              title: Text(r.title),
              subtitle: Text(r.text, style: const TextStyle(height: 1.35)),
            ),
          ),
        if (error != null)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: C.danger))),
        const SizedBox(height: 16),
        SizedBox(
          height: 54,
          child: FilledButton.icon(
            onPressed: running ? null : _start,
            icon: const Icon(Icons.play_arrow),
            label: Text(phase == _Phase.done ? 'Powtórz test' : 'Start (${stillSec + moveSec} s)',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }
}
