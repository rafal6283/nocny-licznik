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
import 'settings.dart';
import 'strap_analysis.dart';

/// Opaska na klatkę piersiową (Polar H10 albo inny pulsometr BLE) w czasie nocy: tętno i odstępy RR
/// ze standardowej usługi Heart Rate. Działa obok Polar EKG (opaska H10 obsługuje dwa połączenia).
/// Surowe dane trafiają na bieżąco do pliku, więc przerwana noc ich nie traci.
class Strap {
  Strap._();
  static final Strap instance = Strap._();

  static final _hrService = Guid('180d');
  static final _hrChar = Guid('2a37');

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
    try {
      _sink = (await fileFor(nightId)).openWrite(mode: FileMode.append);
      final dev = _dev = BluetoothDevice.fromId(Settings.instance.strapId);
      status.value = 'łączenie z opaską…';
      _connSub = dev.connectionState.listen((s) {
        if (s == BluetoothConnectionState.connected) {
          unawaited(_setup(dev));
        } else if (s == BluetoothConnectionState.disconnected && _nightId != null) {
          status.value = 'opaska rozłączona – czekam';
          lastHr.value = null;
        }
      });
      // autoConnect: Android sam łączy ponownie, gdy opaska wróci w zasięg (np. po zdjęciu i założeniu)
      await dev.connect(license: License.nonprofit, autoConnect: true, mtu: null);
    } catch (e) {
      status.value = 'opaska: $e';
    }
  }

  Future<void> _setup(BluetoothDevice dev) async {
    try {
      final services = await dev.discoverServices();
      final svc = services.where((s) => s.uuid == _hrService).firstOrNull;
      final ch = svc?.characteristics.where((c) => c.uuid == _hrChar).firstOrNull;
      if (ch == null) {
        status.value = 'opaska nie podaje tętna';
        return;
      }
      await _valSub?.cancel();
      _valSub = ch.onValueReceived.listen(_onValue);
      await ch.setNotifyValue(true);
      status.value = 'opaska połączona';
    } catch (e) {
      status.value = 'opaska: $e';
    }
  }

  void _onValue(List<int> v) {
    final m = parseHeartRate(v);
    if (m == null) return;
    lastHr.value = m.$1;
    final t = DateTime.now().millisecondsSinceEpoch;
    _sink?.writeln('$t,${m.$1},${m.$2.map((x) => x.round()).join(';')}');
  }

  /// Koniec nocy: rozłączenie i zamknięcie pliku.
  Future<void> stop() async {
    final id = _nightId;
    _nightId = null;
    if (id == null) return;
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
      if (p.length < 3 || p[2].isEmpty) continue;
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

  /// Wyniki z opaski do nocy: tętno minutowe, pauzy, pobudzenia dodatkowe, nieregularny rytm.
  static Future<StrapResult?> applyToNight(Night n) async {
    if (n.id == null) return null;
    final rr = await loadRr(n.id!);
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
