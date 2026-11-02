import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../engine/night_engine.dart';
import 'bus.dart';
import 'db.dart';
import 'models.dart';
import 'night_log.dart';
import 'settings.dart';
import '../engine/strap_minute.dart';
import 'strap_analysis.dart';
import 'strap_pmd.dart';

/// Opaska na klatkę piersiową (Polar H10 albo inny pulsometr BLE) w czasie nocy: tętno i odstępy RR
/// ze standardowej usługi Heart Rate. Działa obok Polar EKG (opaska H10 obsługuje dwa połączenia).
/// Surowe dane trafiają na bieżąco do pliku, więc przerwana noc ich nie traci.
class Strap {
  Strap._();
  static final Strap instance = Strap._();

  static final _hrService = Guid('180d');
  static final _hrChar = Guid('2a37');
  static final _pmdService = Guid('FB005C80-02E7-F387-1CAD-8ACD2D8DF0C8');
  static final _pmdControl = Guid('FB005C81-02E7-F387-1CAD-8ACD2D8DF0C8');
  static final _pmdData = Guid('FB005C82-02E7-F387-1CAD-8ACD2D8DF0C8');

  /// Dane bieżącej minuty (tętno, HRV, ruch tułowia, oddech) – odbierane przez silnik nocy co minutę.
  StrapMinuteProcessor _proc = StrapMinuteProcessor();
  StreamSubscription<List<int>>? _pmdSub;
  BluetoothCharacteristic? _pmdCtl;
  bool _accStartedByUs = false;
  bool accActive = false;
  int _accActiveNow = 0; // sekundy z ruchem od początku bieżącej minuty (budzik)

  /// Minuta danych z opaski (null, gdy opaska nic nie przysłała).
  StrapMinute? takeMinute() {
    final m = _proc.take();
    _accActiveNow = 0;
    if (m != null && m.posChange) {
      _sink?.writeln('P,${DateTime.now().millisecondsSinceEpoch}');
    }
    return m;
  }

  /// Czy tułów poruszał się w bieżącej minucie (inteligentny budzik).
  bool get movingNow => _accActiveNow >= 2;

  /// Stan dla ekranu nocy: null = opaska nieużywana.
  final status = ValueNotifier<String?>(null);
  final lastHr = ValueNotifier<int?>(null);

  BluetoothDevice? _dev;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _valSub;
  IOSink? _sink;
  int? _nightId;

  static Future<File> fileFor(int nightId) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/opaska');
    await dir.create(recursive: true);
    return File('${dir.path}/night_$nightId.csv');
  }

  bool get configured => Settings.instance.strapOn && Settings.instance.strapId.isNotEmpty;

  Future<void> start(int nightId) async {
    if (!configured || _nightId != null) return;
    _nightId = nightId;
    _proc = StrapMinuteProcessor();
    accActive = false;
    _accStartedByUs = false;
    try {
      _sink = (await fileFor(nightId)).openWrite(mode: FileMode.append);
      final dev = _dev = BluetoothDevice.fromId(Settings.instance.strapId);
      _connSub = dev.connectionState.listen((s) {
        if (s == BluetoothConnectionState.connected) unawaited(_setup(dev));
      });
      unawaited(_connectLoop(dev, nightId));
    } catch (e) {
      _st('opaska: $e');
    }
  }

  void _st(String s) {
    if (status.value == s) return;
    status.value = s;
    unawaited(NightLog.add(_nightId, 'OPASKA: $s'));
  }

  /// Łączenie i ponawianie przez całą noc. Android łączy pewnie dopiero z urządzeniem widzianym
  /// w świeżym skanie (zna wtedy typ adresu), więc przed każdą próbą krótko szukamy opaski.
  Future<void> _connectLoop(BluetoothDevice dev, int nightId) async {
    var tries = 0;
    while (_nightId == nightId) {
      try {
        if (!dev.isConnected) {
          if (Platform.isAndroid && FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
            try {
              await FlutterBluePlus.turnOn();
            } catch (_) {}
          }
          if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.off) {
            _st('Bluetooth wyłączony');
          } else {
            _st(tries == 0 ? 'szukam opaski…' : 'opaska niedostępna – ponawiam');
            try {
              await FlutterBluePlus.startScan(withRemoteIds: [dev.remoteId.str], timeout: const Duration(seconds: 8));
              await FlutterBluePlus.isScanning.where((x) => !x).first.timeout(const Duration(seconds: 12));
            } catch (_) {}
            if (_nightId != nightId) break;
            _st('łączenie z opaską…');
            // także gdy skan jej nie widział: połączona z innym telefonem/aplikacją opaska może nie nadawać
            await dev.connect(license: License.nonprofit, timeout: const Duration(seconds: 20), mtu: null);
            tries = 0;
          }
        }
        if (dev.isConnected) {
          await dev.connectionState.where((x) => x == BluetoothConnectionState.disconnected).first;
          if (_nightId != nightId) break;
          lastHr.value = null;
          _st('opaska rozłączona – ponawiam');
        }
      } catch (e) {
        tries++;
        if (tries == 1 || tries % 10 == 0) unawaited(NightLog.add(nightId, 'OPASKA błąd: $e'));
      }
      if (_nightId != nightId) break;
      await Future<void>.delayed(Duration(seconds: tries == 0 ? 3 : (tries < 6 ? 15 : 60)));
    }
  }

  Future<void> _setup(BluetoothDevice dev) async {
    try {
      final services = await dev.discoverServices();
      final svc = services.where((s) => s.uuid == _hrService).firstOrNull;
      final ch = svc?.characteristics.where((c) => c.uuid == _hrChar).firstOrNull;
      if (ch == null) {
        _st('opaska nie podaje tętna');
        return;
      }
      await _valSub?.cancel();
      _valSub = ch.onValueReceived.listen(_onValue);
      await ch.setNotifyValue(true);
      _st('opaska połączona');
      await _startAcc(dev, services);
    } catch (e) {
      _st('opaska: $e');
    }
  }

  /// Akcelerometr Polar H10 (PMD). Gdy pomiar już trwa (np. nagrywa Polar EKG), tylko słuchamy ramek.
  Future<void> _startAcc(BluetoothDevice dev, List<BluetoothService> services) async {
    final pmd = services.where((s) => s.uuid == _pmdService).firstOrNull;
    if (pmd == null) return; // inny pulsometr – samo tętno
    try {
      if (Platform.isAndroid) {
        try {
          await dev.requestMtu(232);
        } catch (_) {}
      }
      final ctl = pmd.characteristics.firstWhere((c) => c.uuid == _pmdControl);
      final data = pmd.characteristics.firstWhere((c) => c.uuid == _pmdData);
      _pmdCtl = ctl;
      await _pmdSub?.cancel();
      _pmdSub = data.onValueReceived.listen((v) {
        final xyz = parseAccFrame(v);
        if (xyz == null) return;
        accActive = true;
        final now = DateTime.now().millisecondsSinceEpoch;
        _proc.addAcc(xyz, now);
        // ruch „teraz” do budzika: duża zmiana między pierwszą a ostatnią próbką ramki
        if (xyz.length >= 6) {
          final d = (xyz[xyz.length - 3] - xyz[0]).abs() + (xyz[xyz.length - 2] - xyz[1]).abs() + (xyz[xyz.length - 1] - xyz[2]).abs();
          if (d > 150) _accActiveNow++;
        }
      });
      await ctl.setNotifyValue(true);
      await data.setNotifyValue(true);
      final resp = Completer<List<int>>();
      final sub = ctl.onValueReceived.listen((v) {
        if (v.length > 3 && v[0] == 0xF0 && !resp.isCompleted) resp.complete(v);
      });
      await ctl.write(pmdStartAcc);
      final r = await resp.future.timeout(const Duration(seconds: 5), onTimeout: () => const [0xF0, 0, 0, 0]);
      await sub.cancel();
      _accStartedByUs = r[3] == 0; // 6 = pomiar już trwa (np. Polar EKG) – nie zatrzymujemy go potem
      _st('opaska połączona · tętno i ruch');
    } catch (e) {
      _st('opaska połączona (bez akcelerometru)');
    }
  }

  void _onValue(List<int> v) {
    final m = parseHeartRate(v);
    if (m == null) return;
    lastHr.value = m.$1;
    _proc.addHr(m.$1, m.$2);
    final t = DateTime.now().millisecondsSinceEpoch;
    _sink?.writeln('$t,${m.$1},${m.$2.map((x) => x.round()).join(';')}');
  }

  /// Próba połączenia z ustawień: (tętno albo null, opis). Nie w trakcie nocy.
  Future<(int?, String)> test() async {
    if (_nightId != null) return (lastHr.value, status.value ?? 'noc w toku');
    final id = Settings.instance.strapId;
    if (id.isEmpty) return (null, 'nie wybrano opaski');
    final dev = BluetoothDevice.fromId(id);
    try {
      if (Platform.isAndroid && FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) await FlutterBluePlus.turnOn();
      try {
        await FlutterBluePlus.startScan(withRemoteIds: [id], timeout: const Duration(seconds: 6));
        await FlutterBluePlus.isScanning.where((x) => !x).first.timeout(const Duration(seconds: 10));
      } catch (_) {}
      await dev.connect(license: License.nonprofit, timeout: const Duration(seconds: 20), mtu: null);
      final services = await dev.discoverServices();
      final ch = services.where((s) => s.uuid == _hrService).firstOrNull?.characteristics.where((c) => c.uuid == _hrChar).firstOrNull;
      if (ch == null) return (null, 'połączono, ale opaska nie podaje tętna');
      final got = Completer<int>();
      final sub = ch.onValueReceived.listen((v) {
        final m = parseHeartRate(v);
        if (m != null && m.$1 > 0 && !got.isCompleted) got.complete(m.$1);
      });
      await ch.setNotifyValue(true);
      final hr = await got.future.timeout(const Duration(seconds: 15), onTimeout: () => -1);
      await sub.cancel();
      final pmd = services.any((s) => s.uuid == _pmdService);
      return hr < 0
          ? (null, 'połączono, ale brak tętna – zwilż elektrody i załóż opaskę')
          : (hr, 'działa · tętno $hr${pmd ? ' · akcelerometr dostępny' : ''}');
    } catch (e) {
      return (null, 'nie udało się połączyć: $e');
    } finally {
      try {
        await dev.disconnect();
      } catch (_) {}
    }
  }

  /// Koniec nocy: rozłączenie i zamknięcie pliku.
  Future<void> stop() async {
    final id = _nightId;
    if (id == null) return;
    unawaited(NightLog.add(id, 'OPASKA: koniec nocy · ${accActive ? 'z akcelerometrem' : 'bez akcelerometru'}'));
    _nightId = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    if (_accStartedByUs) {
      try {
        await _pmdCtl?.write(pmdStopAcc);
      } catch (_) {}
    }
    await _pmdSub?.cancel();
    _pmdSub = null;
    _pmdCtl = null;
    accActive = false;
    await _valSub?.cancel();
    await _connSub?.cancel();
    _valSub = null;
    _connSub = null;
    try {
      await _dev?.disconnect();
    } catch (_) {}
    _dev = null;
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    status.value = null;
    lastHr.value = null;
  }

  /// Odstępy RR z pliku nocy: czas uderzenia liczony wstecz od chwili odebrania pakietu.
  static Future<List<(DateTime, double)>> loadRr(int nightId) async {
    final f = await fileFor(nightId);
    if (!await f.exists()) return const [];
    final out = <(DateTime, double)>[];
    for (final line in const LineSplitter().convert(await f.readAsString())) {
      final p = line.split(',');
      if (p.length < 3 || p[2].isEmpty || p[0] == 'P') continue;
      final t = int.tryParse(p[0]);
      if (t == null) continue;
      final rr = p[2].split(';').map(double.tryParse).whereType<double>().toList();
      var end = t.toDouble();
      final beats = <(DateTime, double)>[];
      for (final v in rr.reversed) {
        beats.add((DateTime.fromMillisecondsSinceEpoch(end.round()), v));
        end -= v;
      }
      out.addAll(beats.reversed);
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  /// Zmiany pozycji ciała zapisane w nocy (akcelerometr H10).
  static Future<List<DateTime>> loadPositionChanges(int nightId) async {
    final f = await fileFor(nightId);
    if (!await f.exists()) return const [];
    return [
      for (final line in const LineSplitter().convert(await f.readAsString()))
        if (line.startsWith('P,'))
          if (int.tryParse(line.substring(2)) case final t?) DateTime.fromMillisecondsSinceEpoch(t)
    ];
  }

  /// Wyniki z opaski do nocy: tętno minutowe, pauzy, pobudzenia dodatkowe, nieregularny rytm.
  static Future<StrapResult?> applyToNight(Night n) async {
    if (n.id == null) return null;
    final rr = await loadRr(n.id!);
    final pos = await loadPositionChanges(n.id!);
    if (rr.length < 300) return null;
    final r = analyzeStrap(rr);
    final ms = await Db.instance.minutes(n.id!);
    if (ms.isNotEmpty && r.hrByMinute.isNotEmpty) {
      // minuta próbki kończy się o m.ts
      final byIdx = <int, double?>{
        for (final m in ms)
          if (r.hrByMinute[m.ts.millisecondsSinceEpoch ~/ 60000 - 1] case final v?) m.idx: v
      };
      if (byIdx.isNotEmpty) await Db.instance.setMinuteHr(n.id!, byIdx);
    }
    await Db.instance.replaceExt(n.id!, 'h10', [
      for (final (a, b) in r.irregular) (a, 'h10af', null, b.difference(a).inSeconds / 60.0),
      for (final (t, s) in r.pauses) (t, 'h10pa', s, null),
      for (final t in r.ectopic) (t, 'h10pv', null, null),
      for (final t in pos) (t, 'h10po', null, null),
    ]);
    if (r.hrAvg != null) {
      n.hrAvg = r.hrAvg;
      n.hrMin = r.hrMin;
    }
    await Db.instance.updateNight(n);
    final fresh = await Db.instance.minutes(n.id!);
    final evs = await Db.instance.events(n.id!);
    await NightEngine.summarize(n, fresh, evs, push: false);
    dataChanged();
    return r;
  }
}

/// Wybór opaski: urządzenia z usługą tętna w pobliżu.
Future<void> strapScan() => FlutterBluePlus.startScan(withServices: [Guid('180d')], timeout: const Duration(seconds: 12));

/// Epizody AF z Polar EKG (plik wymiany pobrany przez Koofr): (początek, koniec).
class PolarAf {
  static Future<File> _file() async => File('${(await getApplicationDocumentsDirectory()).path}/polar_af.json');

  static Future<void> save(List<int> data) async => (await _file()).writeAsBytes(data, flush: true);

  static Future<List<(DateTime, DateTime)>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const [];
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['format'] != 'wymiana-zdarzen') return const [];
      return [
        for (final e in (j['events'] as List? ?? const []))
          if (e is Map && e['type'] == 'af' && e['start'] is num && e['end'] is num)
            (DateTime.fromMillisecondsSinceEpoch((e['start'] as num).toInt()), DateTime.fromMillisecondsSinceEpoch((e['end'] as num).toInt()))
      ];
    } catch (_) {
      return const [];
    }
  }
}

/// Noce z Polar EKG (plik „noc-polar” z Koofr): gdy w nocy opaska była połączona tylko z Polar EKG,
/// Rytm Snu bierze stamtąd tętno, HRV, ruch tułowia, pobudzenia dodatkowe i pauzy.
class PolarNights {
  static Future<File> _file() async => File('${(await getApplicationDocumentsDirectory()).path}/polar_noce.json');

  static Future<void> save(List<int> data) async => (await _file()).writeAsBytes(data, flush: true);

  /// Uzupełnia noce z ostatnich 21 dni bez własnych danych z opaski. Zwraca liczbę uzupełnionych nocy.
  static Future<int> applyAll() async {
    final f = await _file();
    if (!await f.exists()) return 0;
    List<Map> recs;
    try {
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['format'] != 'noc-polar') return 0;
      recs = (j['recordings'] as List? ?? const []).whereType<Map>().toList();
    } catch (_) {
      return 0;
    }
    if (recs.isEmpty) return 0;
    final since = DateTime.now().subtract(const Duration(days: 21));
    var done = 0;
    for (final n in await Db.instance.nights(limit: 40)) {
      if (n.id == null || n.end == null || n.start.isBefore(since)) continue;
      if (NightEngine.instance.night?.id == n.id) continue;
      final ext = await Db.instance.ext(n.id!);
      if (ext.any((r) => r.$2 == 'h10pe')) continue; // już uzupełniona z Polar EKG
      final ms = await Db.instance.minutes(n.id!);
      if (ms.isEmpty || ms.any((m) => m.hrv != null || m.strapAct != null)) continue; // własna opaska
      final a = n.start.millisecondsSinceEpoch, b = n.end!.millisecondsSinceEpoch;
      final rows = <int, List>{}; // minuta (od epoki) → wiersz
      final pauses = <(DateTime, double)>[];
      for (final r in recs) {
        if ((r['start'] as num) >= b || (r['end'] as num) <= a) continue;
        for (final row in (r['minutes'] as List? ?? const []).whereType<List>()) {
          rows[(row[0] as num).toInt() ~/ 60000] = row;
        }
        for (final p in (r['pauses'] as List? ?? const []).whereType<List>()) {
          final t = (p[0] as num).toInt();
          if (t >= a && t <= b) pauses.add((DateTime.fromMillisecondsSinceEpoch(t), (p[1] as num).toDouble()));
        }
      }
      if (rows.isEmpty) continue;
      final byIdx = <int, (double?, double?, int?)>{};
      final ect = <(DateTime, double)>[];
      for (final m in ms) {
        final k = m.ts.millisecondsSinceEpoch ~/ 60000;
        final row = rows[k] ?? rows[k + 1] ?? rows[k - 1];
        if (row == null) continue;
        byIdx[m.idx] = ((row[1] as num?)?.toDouble(), (row[2] as num?)?.toDouble(), (row[3] as num?)?.toInt());
        final sv = ((row[4] as num?) ?? 0) + ((row[5] as num?) ?? 0);
        if (sv > 0) ect.add((m.ts, sv.toDouble()));
      }
      if (byIdx.length < 0.5 * ms.length) continue; // za mało wspólnego czasu
      await Db.instance.setMinuteStrap(n.id!, byIdx);
      await Db.instance.replaceExt(n.id!, 'h10', [
        (n.start, 'h10pe', null, null),
        for (final (t, s) in pauses) (t, 'h10pa', s, null),
        for (final (t, c) in ect) (t, 'h10pv', c, null),
      ]);
      final hrs = [for (final v in byIdx.values) if (v.$1 != null) v.$1!];
      if (hrs.isNotEmpty) {
        n.hrAvg = hrs.reduce((x, y) => x + y) / hrs.length;
        n.hrMin = hrs.reduce(min);
      }
      await Db.instance.updateNight(n);
      final fresh = await Db.instance.minutes(n.id!);
      await NightEngine.summarize(n, fresh, await Db.instance.events(n.id!), push: false);
      done++;
    }
    if (done > 0) dataChanged();
    return done;
  }
}
