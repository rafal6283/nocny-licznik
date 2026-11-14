import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'settings.dart';

/// Odczyt z termometru Bluetooth (temperatura, wilgotność).
class RoomReading {
  final double temp, hum;
  final DateTime at;
  const RoomReading(this.temp, this.hum, this.at);
}

/// Termometr w sypialni: Xiaomi LYWSD03MMC (oryginalne oprogramowanie — połączenie co 5 min)
/// albo z oprogramowaniem ATC / pvvx / BTHome (odczyt z rozgłoszeń, bez łączenia).
class RoomSensor {
  RoomSensor._();
  static final instance = RoomSensor._();

  static final _svc181A = Guid('0000181a-0000-1000-8000-00805f9b34fb'); // ATC / pvvx
  static final _svcBtHome = Guid('0000fcd2-0000-1000-8000-00805f9b34fb'); // BTHome v2
  static final _xiaomiSvc = Guid('ebe0ccb0-7a0a-4b0c-8a1a-6ff2997da3a6');
  static final _xiaomiChar = Guid('ebe0ccc1-7a0a-4b0c-8a1a-6ff2997da3a6');

  final ValueNotifier<RoomReading?> last = ValueNotifier(null);
  Timer? _timer;
  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _running = false;

  bool get configured => Settings.instance.roomSensorOn && Settings.instance.roomSensorId.isNotEmpty;

  /// Aktualny odczyt (gdy nie starszy niż 12 min).
  (double, double)? current() {
    final r = last.value;
    if (r == null || DateTime.now().difference(r.at).inMinutes > 12) return null;
    return (r.temp, r.hum);
  }

  // ---------------------------------------------------------------- dekodowanie
  /// Rozgłoszenie → odczyt (ATC 13 B, pvvx 15 B, BTHome v2).
  static RoomReading? parseAdvert(AdvertisementData a) {
    final now = DateTime.now();
    final d = a.serviceData[_svc181A];
    if (d != null) {
      if (d.length == 13) {
        // ATC: MAC(6) temp int16 BE ×0.1, wilgotność %, bateria %, mV(2), licznik
        var t = (d[6] << 8) | d[7];
        if (t > 32767) t -= 65536;
        return RoomReading(t / 10, d[8].toDouble(), now);
      }
      if (d.length >= 15) {
        // pvvx: MAC(6 LE) temp int16 LE ×0.01, wilg. uint16 LE ×0.01, mV, %, licznik, flagi
        var t = d[6] | (d[7] << 8);
        if (t > 32767) t -= 65536;
        final h = d[8] | (d[9] << 8);
        return RoomReading(t / 100, h / 100, now);
      }
    }
    final b = a.serviceData[_svcBtHome];
    if (b != null && b.isNotEmpty && (b[0] & 0x01) == 0) {
      // BTHome v2 bez szyfrowania: [info][id][dane]…
      double? t, h;
      var i = 1;
      while (i < b.length) {
        final id = b[i];
        int len;
        switch (id) {
          case 0x00: // packet id
          case 0x01: // bateria %
            len = 1;
            break;
          case 0x02: // temperatura sint16 ×0.01
            if (i + 2 >= b.length) return null;
            var v = b[i + 1] | (b[i + 2] << 8);
            if (v > 32767) v -= 65536;
            t = v / 100;
            len = 2;
            break;
          case 0x03: // wilgotność uint16 ×0.01
            if (i + 2 >= b.length) return null;
            h = (b[i + 1] | (b[i + 2] << 8)) / 100;
            len = 2;
            break;
          case 0x0C: // napięcie
            len = 2;
            break;
          case 0x2E: // wilgotność uint8
            if (i + 1 >= b.length) return null;
            h = b[i + 1].toDouble();
            len = 1;
            break;
          case 0x45: // temperatura sint16 ×0.1
            if (i + 2 >= b.length) return null;
            var v = b[i + 1] | (b[i + 2] << 8);
            if (v > 32767) v -= 65536;
            t = v / 10;
            len = 2;
            break;
          default:
            i = b.length; // nieznany obiekt — dalej nie da się iść
            continue;
        }
        i += 1 + len;
      }
      if (t != null && h != null) return RoomReading(t, h, now);
    }
    return null;
  }

  static bool looksLikeThermometer(ScanResult r) {
    final n = r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : r.device.platformName;
    return n.startsWith('LYWSD03') ||
        n.startsWith('ATC_') ||
        n.startsWith('MJ_HT') ||
        n.contains('MHO-C401') ||
        r.advertisementData.serviceData.containsKey(_svc181A) ||
        r.advertisementData.serviceData.containsKey(_svcBtHome);
  }

  // ---------------------------------------------------------------- noc
  Future<void> start() async {
    if (!configured || _running) return;
    _running = true;
    last.value = null;
    unawaited(_poll());
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _poll());
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    await _scanSub?.cancel();
    _scanSub = null;
  }

  Future<void> _poll() async {
    if (!_running) return;
    try {
      final r = await readOnce(Settings.instance.roomSensorId);
      if (r != null) last.value = r;
    } catch (_) {}
  }

  /// Jeden odczyt: najpierw rozgłoszenia (12 s), potem — dla oryginalnego oprogramowania — połączenie.
  Future<RoomReading?> readOnce(String id) async {
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) return null;
    final got = Completer<RoomReading?>();
    // skan innej części aplikacji (opaska) — poczekaj, aż się skończy
    for (var i = 0; i < 20 && FlutterBluePlus.isScanningNow; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen((rs) {
      for (final r in rs) {
        if (r.device.remoteId.str != id) continue;
        final v = parseAdvert(r.advertisementData);
        if (v != null && !got.isCompleted) got.complete(v);
      }
    });
    try {
      await FlutterBluePlus.startScan(withRemoteIds: [id], timeout: const Duration(seconds: 12));
    } catch (_) {}
    final adv = await got.future.timeout(const Duration(seconds: 13), onTimeout: () => null);
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
    } catch (_) {}
    if (adv != null) return adv;
    return _readConnected(id);
  }

  /// Oryginalne oprogramowanie Xiaomi: powiadomienie z temperaturą po połączeniu.
  Future<RoomReading?> _readConnected(String id) async {
    final dev = BluetoothDevice.fromId(id);
    try {
      await dev.connect(license: License.nonprofit, timeout: const Duration(seconds: 15), mtu: null);
      final svcs = await dev.discoverServices();
      final ch = svcs
          .where((s) => s.uuid == _xiaomiSvc)
          .expand((s) => s.characteristics)
          .where((c) => c.uuid == _xiaomiChar)
          .firstOrNull;
      if (ch == null) return null;
      final got = Completer<RoomReading?>();
      final sub = ch.onValueReceived.listen((v) {
        if (v.length >= 3 && !got.isCompleted) {
          var t = v[0] | (v[1] << 8);
          if (t > 32767) t -= 65536;
          got.complete(RoomReading(t / 100, v[2].toDouble(), DateTime.now()));
        }
      });
      await ch.setNotifyValue(true);
      final r = await got.future.timeout(const Duration(seconds: 15), onTimeout: () => null);
      await sub.cancel();
      return r;
    } catch (_) {
      return null;
    } finally {
      try {
        await dev.disconnect();
      } catch (_) {}
    }
  }
}
