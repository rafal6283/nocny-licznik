import 'dart:io';

import 'package:bakometr_native/bakometr_native.dart';
import 'package:flutter/material.dart';

import '../core/night_log.dart';
import 'theme.dart';

/// Diagnostyka: czy system pozwala aplikacji działać w nocy i dlaczego ostatnio ją zamknął.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> with WidgetsBindingObserver {
  bool? battOpt;
  Map<String, dynamic> dev = const {};
  List<ExitReason> exits = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final b = await BakometrNative.batteryOptimized();
    final d = await BakometrNative.deviceInfo();
    final e = [for (final m in await BakometrNative.exitReasons()) ExitReason.fromMap(m)];
    if (mounted) {
      setState(() {
        battOpt = b;
        dev = d;
        exits = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final maker = (dev['manufacturer'] as String? ?? '').toLowerCase();
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostyka')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Section(
          title: 'Praca w tle',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Telefon: ${dev['manufacturer'] ?? '?'} ${dev['model'] ?? ''} · Android SDK ${dev['sdk'] ?? '?'}',
                style: const TextStyle(color: C.muted, fontSize: 12)),
            const SizedBox(height: 10),
            Row(children: [
              Icon(battOpt == false ? Icons.check_circle : Icons.warning_amber,
                  color: battOpt == false ? C.gas : C.moon),
              const SizedBox(width: 8),
              Expanded(
                child: Text(battOpt == null
                    ? 'Nie da się sprawdzić optymalizacji baterii.'
                    : battOpt!
                        ? 'Optymalizacja baterii jest WŁĄCZONA — system może zamknąć nagrywanie w nocy.'
                        : 'Optymalizacja baterii wyłączona — dobrze.'),
              ),
            ]),
            if (battOpt == true) ...[
              const SizedBox(height: 10),
              FilledButton(
                onPressed: BakometrNative.requestIgnoreBatteryOptimizations,
                child: const Text('Wyłącz optymalizację baterii'),
              ),
            ],
            const SizedBox(height: 10),
            Text(_makerTip(maker), style: const TextStyle(fontSize: 12, height: 1.4)),
            TextButton(onPressed: BakometrNative.openAppSettings, child: const Text('Otwórz ustawienia aplikacji')),
          ]),
        ),
        const SizedBox(height: 12),
        Section(
          title: 'Ostatnie zamknięcia aplikacji (z Androida)',
          child: !Platform.isAndroid
              ? const Text('Dostępne tylko na Androidzie.', style: TextStyle(color: C.muted))
              : exits.isEmpty
                  ? const Text('Brak danych (Android 11+ zapisuje ostatnie ok. 16 zamknięć).',
                      style: TextStyle(color: C.muted))
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      for (final e in exits)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(e.text,
                                style: TextStyle(
                                    fontSize: 13, color: e.isKill ? C.text : C.muted, fontWeight: FontWeight.w600)),
                            if (e.tip.isNotEmpty)
                              Text(e.tip, style: const TextStyle(fontSize: 11, color: C.muted)),
                          ]),
                        ),
                      const SizedBox(height: 4),
                      const Text(
                        'Wpis „aktualizacja aplikacji” pojawia się przy instalowaniu nowej wersji — to normalne. '
                        'Szukaj wpisu z godziną, o której urwał się zapis nocy.',
                        style: TextStyle(fontSize: 11, color: C.muted),
                      ),
                    ]),
        ),
      ]),
    );
  }

  String _makerTip(String m) {
    if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) {
      return 'Xiaomi/Redmi/POCO (HyperOS/MIUI) zamyka aplikacje w tle najagresywniej. W ustawieniach aplikacji: '
          'Autostart → włącz; Oszczędzanie baterii → „Bez ograniczeń”. W ostatnich aplikacjach przytrzymaj '
          'Nocny Licznik i przypnij go (kłódka), żeby „wyczyść wszystko” go nie zamykało.';
    }
    if (m.contains('samsung')) {
      return 'Samsung: Ustawienia aplikacji → Bateria → „Bez ograniczeń”. W Pielęgnacji urządzenia → Bateria → '
          'Limity zużycia w tle usuń aplikację z „Uśpionych” i „Głęboko uśpionych”.';
    }
    if (m.contains('huawei') || m.contains('honor')) {
      return 'Huawei/Honor: Bateria → Uruchamianie aplikacji → Nocny Licznik → zarządzaj ręcznie i włącz wszystkie '
          'trzy przełączniki.';
    }
    if (m.contains('oneplus') || m.contains('oppo') || m.contains('realme') || m.contains('vivo')) {
      return 'OnePlus/OPPO/realme/vivo: Bateria → Optymalizacja baterii → Nocny Licznik → „Nie optymalizuj”; '
          'włącz też „Zezwalaj na działanie w tle” i przypnij aplikację w ostatnich.';
    }
    return 'Jeśli zapis nocy się urywa: wyłącz optymalizację baterii, nie czyść aplikacji z ostatnich w nocy '
        'i zostaw telefon na ładowarce.';
  }
}
