import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bakometr_native/bakometr_native.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../core/audio_synth.dart';
import '../core/bus.dart';
import '../core/db.dart';
import '../core/fmt.dart';
import '../core/health_sync.dart';
import '../core/weather.dart';
import '../core/models.dart';
import '../core/night_log.dart';
import '../core/settings.dart';
import 'classifier.dart';
import 'sleep_analysis.dart';
import 'sonar.dart';

enum NightState { idle, tracking, ringing, snoozed, finishing }

/// Parametry startu nocy wybrane na ekranie głównym.
class NightPlan {
  final DateTime? alarmAt;
  final int smartWindowMin;
  final List<String> tags;
  final String lightManual;
  final String lullaby;
  final int lullabyMin;
  final int delayMin;
  final bool cpap;
  const NightPlan({
    this.alarmAt,
    this.smartWindowMin = 30,
    this.tags = const [],
    this.lightManual = '',
    this.lullaby = 'none',
    this.lullabyMin = 20,
    this.delayMin = 0,
    this.cpap = false,
  });
}

class _Pending {
  final SoundType type;
  final int startSample;
  int endSample;
  double conf;
  final DateTime ts;
  final bool withClip;
  final int maxLen;
  _Pending(this.type, this.startSample, this.endSample, this.conf, this.ts, this.withClip, this.maxLen);
}

/// Kandydat na przerwę w oddechu: cisza po słyszalnym oddychaniu, czekamy na dźwięk wznowienia.
class _ApneaCandidate {
  final int gapStart;
  final int gapEnd;
  final int deadline;
  _ApneaCandidate(this.gapStart, this.gapEnd, this.deadline);
}

/// Serce aplikacji: nasłuch, ruch, światło, detekcja, fazy snu i budzik.
class NightEngine extends ChangeNotifier {
  NightEngine._();
  static final NightEngine instance = NightEngine._();

  static const _sr = SoundClassifier.sampleRate;
  static const _hop = _sr ~/ 2; // analiza co 0,5 s
  static const _ringLen = _sr * 45; // bufor 45 s na klipy (przerwy w oddechu bywają długie)
  static const _preRoll = _sr * 3 ~/ 2;
  static const _postRoll = _sr * 3 ~/ 2;
  static const _maxClip = _sr * 8;
  static const _clipLimits = {
    SoundType.fart: 150,
    SoundType.snore: 12,
    SoundType.talk: 40,
    SoundType.cough: 30,
    SoundType.apnea: 60,
    SoundType.hypopnea: 40,
  };
  // Bezdech: cisza ≥10 s (definicja AASM: ustanie przepływu ≥10 s), maks. 2 min.
  static const _apneaMinSec = 10;
  static const _apneaMaxSec = 120;

  final Settings _s = Settings.instance;

  NightState state = NightState.idle;
  Night? night;
  String? lastError;
  String? classifierError;

  // Licznik na żywo
  int farts = 0;
  int snoreHitsTotal = 0;
  int talks = 0;
  int coughs = 0;
  int apneas = 0;
  int hypopneas = 0;
  bool micBlocked = false;
  // Sonar
  bool sonarActive = false;
  SonarProcessor? sonar;
  String? sonarNote;
  bool get cpap => night?.cpap ?? false;
  double? lastLux;
  double levelDb = -90;
  double noiseFloorDb = -60;
  String lastHeard = '';
  bool analysisActive = false;
  DateTime? analysisFrom;
  bool lullabyPlaying = false;
  bool canLuxInBackground = false;
  final List<MinuteSample> minutes = [];
  final List<SoundEvent> liveEvents = [];
  DateTime? ringingSince;
  String ringReason = '';
  DateTime? snoozeUntil;

  // Audio
  AudioRecorder? _rec;
  StreamSubscription<Uint8List>? _audioSub;
  SoundClassifier? _clf;
  final Float32List _ring = Float32List(_ringLen);
  int _total = 0; // łączna liczba próbek
  int _sinceHop = 0;
  final List<_Pending> _pending = [];
  final Map<SoundType, int> _clipsSaved = {};
  final Map<SoundType, DateTime> _lastHit = {};
  final List<DateTime> _snoreHits = [];
  DateTime? _lastNudge;
  DateTime? _muteUntil;
  Directory? _clipDir;
  final Uint8List _carry = Uint8List(1);
  bool _hasCarry = false;
  bool _classifying = false;
  bool _luxFresh = false;
  // Bezdech
  int _lastLoudSample = 0;
  double _gapMotion = 0;
  final List<int> _breathSamples = [];
  _ApneaCandidate? _apneaCand;
  // Zajęty mikrofon (cyfrowe zera)
  int _zeroHops = 0;
  int _blockedHops = 0;

  // Minuta
  double _minMotion = 0;
  double _minNoiseSum = 0; // suma mocy (rms²) — do Leq
  double _minNoiseMax = -200;
  int _minNoiseN = 0;
  int _minFarts = 0;
  bool _minSnore = false;
  int _minApneas = 0;
  int _minSounds = 0;
  int _minuteIdx = 0;

  // Ruch
  StreamSubscription<AccelerometerEvent>? _accSub;
  double? _ax, _ay, _az;
  int _shakes = 0;
  DateTime _lastShake = DateTime.fromMillisecondsSinceEpoch(0);
  void Function(int)? onShake;

  // Sonar: wejście 48 kHz → decymacja do 16 kHz dla reszty analizy
  Decimator3? _decim;
  AudioPlayer? _tonePlayer;
  double _minSonarMotion = 0;

  // Timery i odtwarzacze
  Timer? _minuteTimer;
  Timer? _luxTimer;
  Timer? _alarmTimer;
  Timer? _rampTimer;
  Timer? _lullabyTimer;
  AudioPlayer? _lullabyPlayer;
  AudioPlayer? _alarmPlayer;

  bool get isActive => state != NightState.idle;

  /// Tekst powiadomienia w trakcie nocy.
  String statusText() {
    final parts = <String>[durHM(elapsed.inMinutes)];
    if (_s.detectFarts) parts.add('💨 $farts');
    final rate = sonar?.breathRate;
    if (sonarGood && rate != null) parts.add('🫁 ${rate.round()}/min');
    if (apneas + hypopneas > 0) parts.add('przerwy: ${apneas + hypopneas}');
    if (cpap) parts.add('CPAP');
    return parts.join(' · ');
  }

  Duration get elapsed => night == null ? Duration.zero : DateTime.now().difference(night!.start);

  // =====================================================================
  // START
  // =====================================================================
  Future<bool> start(NightPlan plan) async {
    if (isActive) return true;
    lastError = null;
    _reset();

    _rec = AudioRecorder();
    if (!await _rec!.hasPermission()) {
      lastError = 'Brak dostępu do mikrofonu. Włącz go w ustawieniach systemu.';
      notifyListeners();
      return false;
    }
    await BakometrNative.requestNotificationPermission();

    final now = DateTime.now();
    night = Night(
      start: now,
      alarmAt: plan.alarmAt,
      smartWindowMin: plan.smartWindowMin,
      tags: plan.tags,
      lightManual: plan.lightManual,
      cpap: plan.cpap,
    );
    night!.id = await Db.instance.insertNight(night!);
    final docs = await getApplicationDocumentsDirectory();
    _clipDir = Directory(p.join(docs.path, 'clips', 'night_${night!.id}'));
    await _clipDir!.create(recursive: true);

    state = NightState.tracking;
    notifyListeners();

    final fgsError = await BakometrNative.startTracking(title: 'Nocny Licznik nasłuchuje', text: 'Dobranoc 🌙');
    final dev = await BakometrNative.deviceInfo();
    final battOpt = await BakometrNative.batteryOptimized();
    journal('START noc #${night!.id} · ${dev['manufacturer'] ?? ''} ${dev['model'] ?? ''} (SDK ${dev['sdk'] ?? '?'}) · '
        'usługa w tle: ${fgsError ?? 'OK'} · optymalizacja baterii: ${battOpt == null ? '?' : (battOpt ? 'WŁĄCZONA (ryzyko)' : 'wyłączona')} · '
        'CPAP: ${plan.cpap} · wiatry: ${_s.detectFarts} · budzik: ${plan.alarmAt != null ? hhmm(plan.alarmAt!) : '—'}');
    if (fgsError != null) lastError = fgsError;
    if (_s.keepScreenOn) await BakometrNative.setKeepScreenOn(true);

    // Model ładujemy raz; jeśli go brak, noc i tak się nagrywa (ruch, światło, głośność).
    if (_clf == null) {
      try {
        _clf = await SoundClassifier.load();
        classifierError = null;
      } catch (e) {
        classifierError = 'Nie udało się załadować modelu dźwięków: $e';
      }
    }

    // Mikrofon startujemy od razu (iOS wymaga rozpoczęcia nagrywania na pierwszym planie).
    final wantSonar = Platform.isAndroid && _s.sonarEnabled;
    Stream<Uint8List>? stream;
    if (wantSonar) {
      for (final src in [sonarSourceOf(_s.sonarSource), AndroidAudioSource.defaultSource]) {
        try {
          stream = await _rec!.startStream(RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: SonarProcessor.fs,
            numChannels: 1,
            androidConfig: AndroidRecordConfig(audioSource: src),
          ));
          sonarActive = true;
          break;
        } catch (_) {
          try {
            await _rec!.stop();
          } catch (_) {}
        }
      }
      if (sonarActive) {
        _decim = Decimator3();
        sonar = SonarProcessor()
          ..onSecond = _onSonarSecond
          ..onEvent = _onSonarEvent;
        night!.sonar = true;
        try {
          _tonePlayer ??= AudioPlayer();
          await _tonePlayer!.setFilePath(await AudioSynth.sonarTone(_s.sonarVolume));
          await _tonePlayer!.setLoopMode(LoopMode.one);
          await _tonePlayer!.setVolume(1.0);
          unawaited(_tonePlayer!.play());
        } catch (e) {
          sonarNote = 'Nie udało się włączyć tonu sonaru: $e';
        }
      } else {
        sonarNote = 'Sonar niedostępny na tym telefonie — zwykły nasłuch.';
      }
    }
    try {
      stream ??= await _rec!.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sr,
        numChannels: 1,
      ));
      _audioSub = stream.listen(_onAudio, onError: (e) {
        lastError = 'Błąd mikrofonu: $e';
        notifyListeners();
      });
    } catch (e) {
      lastError = 'Nie udało się uruchomić mikrofonu: $e';
    }

    _accSub = accelerometerEventStream(samplingPeriod: SensorInterval.normalInterval).listen(_onAccel);

    // Analiza dźwięku rusza po opóźnieniu i po kołysance (żeby jej nie „słyszeć”).
    final delay = max(plan.delayMin, plan.lullaby != 'none' ? plan.lullabyMin : 0);
    analysisFrom = now.add(Duration(minutes: delay));
    analysisActive = delay == 0;
    if (plan.lullaby != 'none') await _startLullaby(plan.lullaby, plan.lullabyMin);

    // Światło
    canLuxInBackground = await BakometrNative.canMeasureLuxInBackground();
    unawaited(measureLuxNow());
    if (canLuxInBackground) {
      _luxTimer = Timer.periodic(Duration(seconds: _s.luxIntervalSec), (_) => measureLuxNow());
    }

    journal('mikrofon: ${_audioSub != null ? 'OK' : 'BŁĄD'}${sonarActive ? ' · sonar 48 kHz' : ''}'
        '${sonarNote != null ? ' · $sonarNote' : ''}${lastError != null ? ' · błąd: $lastError' : ''}');
    _minuteTimer = Timer.periodic(const Duration(minutes: 1), (_) => _flushMinute());
    _alarmTimer = Timer.periodic(const Duration(seconds: 15), (_) => _checkAlarm());

    // Zapasowe powiadomienie (gdyby system zamknął aplikację w nocy)
    if (plan.alarmAt != null) {
      await BakometrNative.scheduleNotification(
        id: 900,
        at: plan.alarmAt!.add(const Duration(minutes: 1)),
        title: 'Pobudka! ⏰',
        body: 'Budzik Nocnego Licznika — aplikacja została zamknięta w nocy.',
      );
    }
    notifyListeners();
    return true;
  }

  void _reset() {
    farts = 0;
    snoreHitsTotal = 0;
    talks = 0;
    coughs = 0;
    apneas = 0;
    hypopneas = 0;
    micBlocked = false;
    sonarActive = false;
    sonar = null;
    sonarNote = null;
    _decim = null;
    _minSonarMotion = 0;
    _lastLoudSample = 0;
    _gapMotion = 0;
    _breathSamples.clear();
    _apneaCand = null;
    _zeroHops = 0;
    _blockedHops = 0;
    lastLux = null;
    levelDb = -90;
    noiseFloorDb = -60;
    lastHeard = '';
    minutes.clear();
    liveEvents.clear();
    _pending.clear();
    _clipsSaved.clear();
    _lastHit.clear();
    _snoreHits.clear();
    _total = 0;
    _sinceHop = 0;
    _hasCarry = false;
    _minuteIdx = 0;
    _resetMinute();
    ringingSince = null;
    snoozeUntil = null;
    ringReason = '';
    _lastNudge = null;
    _muteUntil = null;
  }

  void _resetMinute() {
    _minMotion = 0;
    _minNoiseSum = 0;
    _minNoiseMax = -200;
    _minNoiseN = 0;
    _minFarts = 0;
    _minSnore = false;
    _minApneas = 0;
    _minSounds = 0;
  }

  // =====================================================================
  // AUDIO
  // =====================================================================
  void _onAudio(Uint8List bytes) {
    var data = bytes;
    if (_hasCarry) {
      data = Uint8List(bytes.length + 1)
        ..[0] = _carry[0]
        ..setRange(1, bytes.length + 1, bytes);
      _hasCarry = false;
    }
    final n = data.length ~/ 2;
    if (data.length.isOdd) {
      _carry[0] = data[data.length - 1];
      _hasCarry = true;
    }
    final bd = ByteData.sublistView(data);
    final dec = _decim;
    if (dec != null) {
      // 48 kHz: całość do sonaru, po filtrze co trzecia próbka do analizy dźwięków
      final x = Float32List(n);
      for (var i = 0; i < n; i++) {
        x[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
      }
      sonar?.feed(x);
      for (var i = 0; i < n; i++) {
        final y = dec.push(x[i]);
        if (y != null) _pushSample(y);
      }
    } else {
      for (var i = 0; i < n; i++) {
        _pushSample(bd.getInt16(i * 2, Endian.little) / 32768.0);
      }
    }
  }

  void _pushSample(double v) {
    _ring[_total % _ringLen] = v;
    _total++;
    _sinceHop++;
    if (_sinceHop >= _hop) {
      _sinceHop = 0;
      _onHop();
    }
  }

  // =====================================================================
  // SONAR
  // =====================================================================
  static AndroidAudioSource sonarSourceOf(String name) =>
      AndroidAudioSource.values.firstWhere((e) => e.name == name, orElse: () => AndroidAudioSource.unprocessed);

  bool get sonarGood => sonarActive && (sonar?.quality ?? -99) >= 6;

  void _onSonarSecond(SonarSecond s) {
    if (state == NightState.tracking) _minSonarMotion += s.motion;
    if (s.moving) _gapMotion += 3; // ruch z sonaru też unieważnia „ciszę” detektora dźwiękowego
  }

  void _onSonarEvent(SonarEvent e) {
    if (!analysisActive || state != NightState.tracking) return;
    final type = e.apnea ? SoundType.apnea : SoundType.hypopnea;
    if (e.apnea) {
      apneas++;
    } else {
      hypopneas++;
    }
    _minApneas++;
    final saved = _clipsSaved[type] ?? 0;
    final withClip = _s.recordClips && saved < (_clipLimits[type] ?? 40);
    final back = min(_ringLen - _sr, (e.seconds + 4) * _sr);
    _pending.add(_Pending(type, max(0, _total - back), _total, e.depth, e.start, withClip, _sr * 40));
    notifyListeners();
  }

  void _onHop() {
    // Głośność ostatnich 0,5 s
    var sum = 0.0;
    for (var i = _total - _hop; i < _total; i++) {
      final v = _ring[i % _ringLen];
      sum += v * v;
    }
    final rms = sqrt(sum / _hop);
    final db = 20 * log(rms + 1e-9) / ln10;
    levelDb = db;
    // Poziom tła: szybko w dół, bardzo powoli w górę.
    noiseFloorDb = db < noiseFloorDb ? noiseFloorDb * 0.7 + db * 0.3 : noiseFloorDb + (db - noiseFloorDb) * 0.004;
    // Hałas otoczenia: energia (Leq) i szczyt minuty; cyfrowej ciszy (zajęty mikrofon) nie liczymy.
    if (rms >= 1e-6) {
      _minNoiseSum += rms * rms;
      _minNoiseN++;
      if (db > _minNoiseMax) _minNoiseMax = db;
    }

    final now = DateTime.now();
    if (!analysisActive && analysisFrom != null && !now.isBefore(analysisFrom!) && !lullabyPlaying) {
      analysisActive = true;
    }

    _finalizePending();

    // --- Zajęty mikrofon: inna aplikacja nagrywa, my dostajemy idealne zera ---
    final digitalZero = rms < 1e-6;
    if (digitalZero) {
      _zeroHops++;
      if (micBlocked) _blockedHops++;
      if (!micBlocked && _zeroHops >= 240 && state == NightState.tracking) {
        micBlocked = true;
        journal('mikrofon zajęty przez inną aplikację (cyfrowa cisza)');
        _blockedHops += _zeroHops;
        BakometrNative.updateTracking('⚠️ Mikrofon zajęty przez inną aplikację — dźwięki nie są liczone');
        notifyListeners();
      }
    } else {
      _zeroHops = 0;
      if (micBlocked) {
        micBlocked = false;
        BakometrNative.updateTracking(statusText());
        notifyListeners();
      }
    }

    final muted = _muteUntil != null && now.isBefore(_muteUntil!);
    // Dźwiękowy detektor przerw: wyłączony przy CPAP (szum aparatu, brak chrapania) i gdy działa sonar.
    _trackApnea(db, muted || digitalZero || cpap || sonarGood);
    final loudEnough = db > noiseFloorDb + 5 || _recentSnore(now);
    if (analysisActive && !muted && state == NightState.tracking && loudEnough && _clf != null &&
        _total >= SoundClassifier.windowLen && !_classifying) {
      _classify(now);
    }
  }

  bool _recentSnore(DateTime now) =>
      _snoreHits.isNotEmpty && now.difference(_snoreHits.last).inSeconds < 20;

  /// Czułość 0..1 → próg wyniku YAMNet.
  double _thr(double sensitivity, double lo, double hi) => hi - (hi - lo) * sensitivity.clamp(0.0, 1.0);

  void _classify(DateTime now) {
    _classifying = true;
    try {
      final w = Float32List(SoundClassifier.windowLen);
      final start = _total - SoundClassifier.windowLen;
      for (var i = 0; i < w.length; i++) {
        w[i] = _ring[(start + i) % _ringLen];
      }
      final s = _clf!.classify(w);
      lastHeard = '${s.top} ${(s.topScore * 100).round()}%';

      if (_s.detectFarts) {
        // CPAP: nieszczelność maski daje krótkie „pyknięcia” — wymagamy pewniejszego i głośniejszego dźwięku.
        final thr = _thr(_s.fartSensitivity, 0.08, 0.5) + (cpap ? 0.15 : 0);
        final loudOk = !cpap || levelDb > noiseFloorDb + 8;
        if (s.fart >= thr && loudOk) _hit(SoundType.fart, s.fart, now, gapMs: 2500);
      }
      if (s.snore >= _thr(_s.snoreSensitivity, 0.15, 0.6)) _hit(SoundType.snore, s.snore, now, gapMs: 60000);
      if (_s.detectTalk && s.speech >= 0.6) _hit(SoundType.talk, s.speech, now, gapMs: 10000);
      if (_s.detectCough && s.cough >= 0.45) _hit(SoundType.cough, s.cough, now, gapMs: 3000);

      // Słyszalny oddech/chrapanie — warunek wstępny przerwy w oddechu.
      if (s.snore >= 0.2 || s.breathing >= 0.25 || s.snort >= 0.2) _breathSamples.add(_total);
      final cand = _apneaCand;
      if (cand != null && _total <= cand.deadline && s.recovery >= 0.15) {
        _apneaCand = null;
        _apneaHit(cand, s.recovery, now);
      }
    } catch (e) {
      classifierError = 'Błąd analizy: $e';
    } finally {
      _classifying = false;
    }
    notifyListeners();
  }

  void _hit(SoundType t, double conf, DateTime now, {required int gapMs}) {
    if (t == SoundType.snore) {
      _snoreHits.add(now);
      _snoreHits.removeWhere((d) => now.difference(d).inSeconds > 90);
      _minSnore = true;
      snoreHitsTotal++;
      _maybeNudge(now);
    }
    final last = _lastHit[t];
    _lastHit[t] = now;
    final open = _pending.where((e) => e.type == t).toList();
    if (last != null && now.difference(last).inMilliseconds < gapMs) {
      // To samo zdarzenie trwa dalej — wydłużamy je.
      if (open.isNotEmpty) {
        final e = open.last;
        e.endSample = min(_total, e.startSample + _maxClip - _postRoll);
        e.conf = max(e.conf, conf);
      }
      return;
    }
    switch (t) {
      case SoundType.fart:
        farts++;
        _minFarts++;
      case SoundType.talk:
        talks++;
        _minSounds++;
      case SoundType.cough:
        coughs++;
        _minSounds++;
      case SoundType.snore:
      case SoundType.apnea:
      case SoundType.hypopnea:
        break;
    }
    final saved = _clipsSaved[t] ?? 0;
    final withClip = _s.recordClips && saved < (_clipLimits[t] ?? 20);
    // Okno YAMNet obejmuje ~1 s wstecz.
    final startSample = max(0, _total - SoundClassifier.windowLen - _preRoll);
    _pending.add(_Pending(t, startSample, _total, conf, now, withClip, _maxClip));
    if (t == SoundType.fart) {
      BakometrNative.updateTracking(statusText());
    }
  }

  /// Wykrywanie przerw w oddechu (wzorzec „chrapanie → cisza ≥10 s → głośne wznowienie”),
  /// jak w metodach opartych na dźwiękach po bezdechu (post-apnea sounds).
  void _trackApnea(double db, bool ignore) {
    final cand = _apneaCand;
    if (cand != null && _total > cand.deadline) _apneaCand = null;
    _breathSamples.removeWhere((x) => _total - x > _sr * 180);

    final loud = db > noiseFloorDb + 6;
    if (!loud) return;
    final gapSec = (_total - _lastLoudSample) / _sr;
    final asleep = analysisActive && state == NightState.tracking && !ignore;
    if (asleep && gapSec >= _apneaMinSec && gapSec <= _apneaMaxSec && _gapMotion < 2.5) {
      // Przed ciszą musiało być słychać oddech/chrapanie — inaczej to zwykła cisza w pokoju.
      final before = _breathSamples.where((x) => x <= _lastLoudSample && _lastLoudSample - x <= _sr * 60).length;
      if (before >= 3) {
        _apneaCand = _ApneaCandidate(_lastLoudSample, _total, _total + _sr * 4);
      }
    }
    _lastLoudSample = _total;
    _gapMotion = 0;
  }

  void _apneaHit(_ApneaCandidate c, double conf, DateTime now) {
    apneas++;
    _minApneas++;
    final saved = _clipsSaved[SoundType.apnea] ?? 0;
    final withClip = _s.recordClips && saved < (_clipLimits[SoundType.apnea] ?? 60);
    final gapSec = (c.gapEnd - c.gapStart) / _sr;
    final ts = now.subtract(Duration(milliseconds: (gapSec * 1000).round()));
    _pending.add(_Pending(SoundType.apnea, max(0, c.gapStart - _sr * 3), _total, conf, ts, withClip, _sr * 40));
    notifyListeners();
  }

  void _maybeNudge(DateTime now) {
    if (!_s.antiSnore) return;
    final recent = _snoreHits.where((d) => now.difference(d).inSeconds <= 60).length;
    if (recent < 4) return;
    if (_lastNudge != null && now.difference(_lastNudge!).inMinutes < 5) return;
    _lastNudge = now;
    _muteUntil = now.add(const Duration(seconds: 4));
    // Trzy krótkie wibracje — zwykle wystarczy, żeby zmienić pozycję.
    BakometrNative.vibrate(500);
    Future.delayed(const Duration(milliseconds: 900), () => BakometrNative.vibrate(500));
    Future.delayed(const Duration(milliseconds: 1800), () => BakometrNative.vibrate(500));
  }

  void _finalizePending() {
    final ready = _pending.where((e) => _total >= e.endSample + _postRoll || _total - e.startSample > e.maxLen).toList();
    for (final e in ready) {
      _pending.remove(e);
      _saveEvent(e);
    }
  }

  Future<void> _saveEvent(_Pending e, {bool flush = false}) async {
    final n = night;
    if (n?.id == null) return;
    String? clip;
    final end = min(_total, e.endSample + _postRoll);
    final start = max(e.startSample, max(0, _total - _ringLen + 1));
    final len = min(end - start, e.maxLen);
    if (e.withClip && len > _sr ~/ 2 && _clipDir != null) {
      final pcm = Int16List(len);
      for (var i = 0; i < len; i++) {
        pcm[i] = (_ring[(start + i) % _ringLen] * 32767).round().clamp(-32767, 32767);
      }
      final path = p.join(_clipDir!.path, '${e.type.name}_${e.ts.millisecondsSinceEpoch}.wav');
      try {
        await File(path).writeAsBytes(AudioSynth.wav(pcm, _sr));
        clip = path;
        _clipsSaved[e.type] = (_clipsSaved[e.type] ?? 0) + 1;
      } catch (_) {}
    }
    final ev = SoundEvent(
      nightId: n!.id!,
      ts: e.ts,
      type: e.type,
      confidence: e.conf,
      clipPath: clip,
      durationMs: ((e.endSample - e.startSample) * 1000 / _sr).round(),
    );
    ev.id = await Db.instance.insertEvent(ev);
    liveEvents.add(ev);
    notifyListeners();
  }

  // =====================================================================
  // RUCH
  // =====================================================================
  void _onAccel(AccelerometerEvent e) {
    if (_ax != null) {
      final d = sqrt(pow(e.x - _ax!, 2) + pow(e.y - _ay!, 2) + pow(e.z - _az!, 2));
      final muted = _muteUntil != null && DateTime.now().isBefore(_muteUntil!);
      // Drobny szum czujnika pomijamy.
      if (d > 0.08 && !muted && state == NightState.tracking) {
        _minMotion += d;
        _gapMotion += d;
      }
      // Potrząśnięcia (wyłączanie budzika)
      if (d > 12 && onShake != null) {
        final now = DateTime.now();
        if (now.difference(_lastShake).inMilliseconds > 180) {
          _lastShake = now;
          _shakes++;
          onShake!(_shakes);
        }
      }
    }
    _ax = e.x;
    _ay = e.y;
    _az = e.z;
  }

  void resetShakes() => _shakes = 0;

  // =====================================================================
  // ŚWIATŁO
  // =====================================================================
  Future<void> measureLuxNow() async {
    final v = await BakometrNative.measureLux();
    if (v != null) {
      lastLux = v;
      _luxFresh = true;
      notifyListeners();
    }
  }

  /// Wywoływane, gdy aplikacja wraca na pierwszy plan (na iOS jedyna okazja do pomiaru kamerą).
  void onResumed() {
    if (state == NightState.tracking && !canLuxInBackground) measureLuxNow();
  }

  // =====================================================================
  // MINUTA
  // =====================================================================
  Future<void> _flushMinute() async {
    final n = night;
    if (n?.id == null || state == NightState.idle) return;
    final m = MinuteSample(
      idx: _minuteIdx,
      ts: DateTime.now(),
      motion: _minMotion,
      noiseDb: _minNoiseN > 0 ? 10 * log(_minNoiseSum / _minNoiseN + 1e-18) / ln10 : -200,
      noiseMax: _minNoiseN > 0 ? _minNoiseMax : null,
      // Na iOS światło znamy tylko z pomiarów na pierwszym planie — zapisujemy je
      // w minucie pomiaru zamiast powielać jedną wartość przez całą noc.
      lux: (canLuxInBackground || _luxFresh) ? lastLux : null,
      farts: _minFarts,
      snore: _minSnore,
      apneas: _minApneas,
      sounds: _minSounds,
      breathRate: sonarGood ? sonar!.minuteRate() : null,
      breathVar: sonarGood ? sonar!.breathVar : null,
      sonarMotion: sonarActive ? _minSonarMotion : null,
    );
    sonar?.clearMinute();
    _minSonarMotion = 0;
    _luxFresh = false;
    _resetMinute();
    minutes.add(m);
    _minuteIdx++;
    if (_minuteIdx % 15 == 0) {
      journal('żyje · minuta $_minuteIdx · ${Settings.instance.spl(m.noiseDb).round()} dB'
          '${sonarActive ? ' · sonar ${(sonar?.quality ?? -99).round()} dB' : ''}'
          '${micBlocked ? ' · mikrofon zajęty' : ''}');
    }
    await Db.instance.insertMinute(n!.id!, m);
    if (minutes.length % 5 == 0) {
      BakometrNative.updateTracking(statusText());
    }
    notifyListeners();
  }

  // =====================================================================
  // BUDZIK
  // =====================================================================
  void _checkAlarm() {
    final n = night;
    if (n == null) return;
    final now = DateTime.now();
    if (state == NightState.snoozed) {
      if (snoozeUntil != null && !now.isBefore(snoozeUntil!)) ring('Drzemka minęła');
      return;
    }
    if (state != NightState.tracking || n.alarmAt == null) return;
    final alarm = n.alarmAt!;
    if (!now.isBefore(alarm)) {
      ring('Godzina budzenia');
      return;
    }
    final windowStart = alarm.subtract(Duration(minutes: n.smartWindowMin));
    if (n.smartWindowMin > 0 && !now.isBefore(windowStart)) {
      if (SleepAnalysis.lightPhaseNow(minutes, _minMotion)) {
        ring('Inteligentny budzik — lekki sen');
      }
    }
  }

  Future<void> ring(String reason) async {
    if (state == NightState.ringing) return;
    state = NightState.ringing;
    journal('BUDZIK: $reason');
    ringReason = reason;
    ringingSince = DateTime.now();
    analysisActive = false;
    await _stopLullaby();
    notifyListeners();
    await BakometrNative.showAlarm(title: 'Pobudka! ☀️', body: statusText());
    await BakometrNative.cancelNotification(900);

    try {
      _alarmPlayer ??= AudioPlayer();
      await _alarmPlayer!.setFilePath(await AudioSynth.alarmFile());
      await _alarmPlayer!.setLoopMode(LoopMode.one);
      await _alarmPlayer!.setVolume(0.05);
      unawaited(_alarmPlayer!.play());
    } catch (e) {
      lastError = 'Nie udało się odtworzyć budzika: $e';
    }
    final rampSteps = max(1, _s.rampSec);
    var step = 0;
    _rampTimer?.cancel();
    _rampTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      step++;
      final v = min(1.0, 0.05 + 0.95 * step / rampSteps);
      _alarmPlayer?.setVolume(v);
      if (_s.alarmVibrate && step % 3 == 0) BakometrNative.vibrate(700);
    });
  }

  Future<void> _silenceAlarm() async {
    _rampTimer?.cancel();
    _rampTimer = null;
    try {
      await _alarmPlayer?.stop();
    } catch (_) {}
    await BakometrNative.cancelAlarm();
  }

  Future<void> snooze() async {
    await _silenceAlarm();
    snoozeUntil = DateTime.now().add(Duration(minutes: _s.snoozeMin));
    state = NightState.snoozed;
    await BakometrNative.scheduleNotification(
      id: 900,
      at: snoozeUntil!.add(const Duration(minutes: 1)),
      title: 'Pobudka! ⏰',
      body: 'Koniec drzemki.',
    );
    notifyListeners();
  }

  /// Budzik wyłączony (po zadaniu) albo noc zatrzymana ręcznie → zapis i analiza.
  /// Zapis do dziennika bieżącej nocy.
  void journal(String line) => NightLog.add(night?.id, line);

  Future<Night?> finish({String reason = 'zakończona przez użytkownika'}) async {
    if (state == NightState.idle) return null;
    journal('KONIEC: $reason · minut: ${minutes.length}');
    state = NightState.finishing;
    notifyListeners();
    await _silenceAlarm();
    await _stopLullaby();
    _minuteTimer?.cancel();
    _luxTimer?.cancel();
    _alarmTimer?.cancel();
    await _audioSub?.cancel();
    _audioSub = null;
    try {
      await _tonePlayer?.stop();
    } catch (_) {}
    try {
      await _rec?.stop();
      await _rec?.dispose();
    } catch (_) {}
    _rec = null;
    await _accSub?.cancel();
    _accSub = null;
    onShake = null;

    // Domknięcie oczekujących zdarzeń i bieżącej minuty
    for (final e in [..._pending]) {
      _pending.remove(e);
      await _saveEvent(e);
    }
    if (_minNoiseN > 0) await _flushMinute();

    await BakometrNative.cancelNotification(900);
    await BakometrNative.stopTracking();
    await BakometrNative.setKeepScreenOn(false);

    final n = night!;
    n.end = DateTime.now();
    n.micBlockedMin = _blockedHops ~/ 120;
    await summarize(n, minutes, liveEvents);
    unawaited(WeatherService.fetchFor(n).then((ok) {
      if (ok) dataChanged();
    }));

    state = NightState.idle;
    night = null;
    notifyListeners();
    return n;
  }

  /// Liczy podsumowanie nocy i zapisuje je (używane też przy edycji zdarzeń).
  static Future<void> summarize(Night n, List<MinuteSample> ms, List<SoundEvent> evs) async {
    final sum = SleepAnalysis.analyze(ms, goalMin: Settings.instance.sleepGoalMin);
    n.inBedMin = n.end != null ? n.end!.difference(n.start).inMinutes : sum.inBedMin;
    n.durationMin = sum.sleepMin;
    n.deepMin = sum.deepMin;
    n.lightMin = sum.lightMin;
    n.remMin = sum.remMin;
    n.awakeMin = sum.awakeMin;
    n.latencyMin = sum.latencyMin;
    n.awakenings = sum.awakenings;
    n.score = sum.score;
    n.fartCount = evs.where((e) => e.type == SoundType.fart && e.counts).length;
    n.talkCount = evs.where((e) => e.type == SoundType.talk && e.counts).length;
    n.coughCount = evs.where((e) => e.type == SoundType.cough && e.counts).length;
    n.apneaCount = evs.where((e) => e.type == SoundType.apnea && e.counts).length;
    n.hypopneaCount = evs.where((e) => e.type == SoundType.hypopnea && e.counts).length;
    n.apneaIndex = sum.sleepMin >= 60 ? (n.apneaCount + n.hypopneaCount) / (sum.sleepMin / 60.0) : 0;
    final rates = ms.map((m) => m.breathRate).whereType<double>().toList();
    n.breathRate = rates.isEmpty ? null : rates.reduce((a, b) => a + b) / rates.length;
    n.snoreMin = ms.where((m) => m.snore).length;
    final noise = ms.where((m) => m.noiseDb > -120).toList();
    if (noise.isNotEmpty) {
      final p = noise.map((m) => pow(10, m.noiseDb / 10)).reduce((a, b) => a + b) / noise.length;
      n.avgNoise = 10 * log(p) / ln10;
      n.maxNoise = noise.map((m) => m.noiseMax ?? m.noiseDb).reduce(max);
    }
    final lux = ms.map((m) => m.lux).whereType<double>().toList();
    if (lux.isNotEmpty) {
      n.avgLux = lux.reduce((a, b) => a + b) / lux.length;
      n.maxLux = lux.reduce(max);
    }
    await Db.instance.updateNight(n);
    if (n.id != null && ms.isNotEmpty) await Db.instance.saveStages(n.id!, ms);
    dataChanged();
    unawaited(HealthSync.pushNight(n, ms));
  }

  /// Przy starcie aplikacji: domyka noce przerwane przez system (np. ubicie procesu).
  static Future<void> recoverUnfinished() async {
    final unfinished = await Db.instance.unfinishedNights();
    if (unfinished.isEmpty) return;
    final exits = [for (final m in await BakometrNative.exitReasons()) ExitReason.fromMap(m)];
    for (final n in unfinished) {
      if (NightEngine.instance.night?.id == n.id) continue;
      final ms = await Db.instance.minutes(n.id!);
      final evs = await Db.instance.events(n.id!);
      n.end = ms.isNotEmpty ? ms.last.ts : n.start;
      // Powód: pierwsze zakończenie procesu po ostatniej zapisanej minucie.
      final after = exits.where((e) => e.isKill && e.ts.isAfter(n.end!.subtract(const Duration(minutes: 2)))).toList()
        ..sort((a, b) => a.ts.compareTo(b.ts));
      n.interruptReason = after.isNotEmpty
          ? after.first.text
          : 'ok. ${hhmm(n.end!)} — aplikacja przestała działać; Android nie podał przyczyny '
              '(zwykle oszczędzanie baterii albo wyczyszczenie z ostatnich aplikacji)';
      await NightLog.add(n.id, 'PRZERWANA: ${n.interruptReason}');
      await summarize(n, ms, evs);
    }
  }

  // =====================================================================
  // KOŁYSANKA
  // =====================================================================
  Future<void> _startLullaby(String kind, int minutesLen) async {
    try {
      _lullabyPlayer ??= AudioPlayer();
      await _lullabyPlayer!.setFilePath(await AudioSynth.noiseFile(kind));
      await _lullabyPlayer!.setLoopMode(LoopMode.one);
      final vol = _s.lullabyVolume;
      await _lullabyPlayer!.setVolume(vol);
      unawaited(_lullabyPlayer!.play());
      lullabyPlaying = true;
      final startAt = DateTime.now();
      final total = Duration(minutes: minutesLen);
      const fade = Duration(seconds: 90);
      _lullabyTimer = Timer.periodic(const Duration(seconds: 2), (t) {
        final left = total - DateTime.now().difference(startAt);
        if (left <= Duration.zero) {
          _stopLullaby();
        } else if (left < fade) {
          _lullabyPlayer?.setVolume(vol * left.inMilliseconds / fade.inMilliseconds);
        }
      });
    } catch (e) {
      lastError = 'Nie udało się odtworzyć kołysanki: $e';
      lullabyPlaying = false;
    }
    notifyListeners();
  }

  Future<void> _stopLullaby() async {
    _lullabyTimer?.cancel();
    _lullabyTimer = null;
    if (lullabyPlaying) {
      try {
        await _lullabyPlayer?.stop();
      } catch (_) {}
    }
    lullabyPlaying = false;
    // Poziom tła po wyciszeniu ustala się od nowa.
    noiseFloorDb = levelDb;
    notifyListeners();
  }

  Future<void> stopLullabyNow() => _stopLullaby();

  /// Ręczne sprawdzenie, czy klasyfikator działa (ekran nocy → „co słychać”).
  @visibleForTesting
  int get totalSamples => _total;
}
