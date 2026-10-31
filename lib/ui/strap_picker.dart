import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/strap.dart';
import 'theme.dart';

/// Wyszukiwanie opaski z usługą tętna (Polar H10, Garmin HRM, Wahoo TICKR…). Zwraca (id, nazwa).
class StrapPicker extends StatefulWidget {
  const StrapPicker({super.key});
  @override
  State<StrapPicker> createState() => _StrapPickerState();
}

class _StrapPickerState extends State<StrapPicker> {
  List<ScanResult> _found = [];
  StreamSubscription<List<ScanResult>>? _sub;
  String? _err;

  @override
  void initState() {
    super.initState();
    _sub = FlutterBluePlus.scanResults.listen((r) => setState(() => _found = r));
    _scan();
  }

  Future<void> _scan() async {
    try {
      if (await FlutterBluePlus.isSupported == false) {
        setState(() => _err = 'Ten telefon nie obsługuje Bluetooth LE');
        return;
      }
      await strapScan();
    } catch (e) {
      if (mounted) setState(() => _err = 'Nie udało się wyszukać: $e. Sprawdź, czy Bluetooth jest włączony.');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Wybierz opaskę'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Załóż opaskę (zwilż elektrody) – wtedy się włącza i będzie widoczna.', style: TextStyle(color: C.muted, fontSize: 13)),
          const SizedBox(height: 8),
          if (_err != null) Text(_err!, style: const TextStyle(color: C.danger, fontSize: 13)),
          if (_found.isEmpty && _err == null)
            const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
          for (final r in _found)
            ListTile(
              leading: const Icon(Icons.monitor_heart_outlined),
              title: Text(r.device.platformName.isEmpty ? r.device.remoteId.str : r.device.platformName),
              subtitle: Text('sygnał ${r.rssi} dBm'),
              onTap: () => Navigator.pop(context, (r.device.remoteId.str, r.device.platformName)),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: _scan, child: const Text('Szukaj ponownie')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Anuluj')),
      ],
    );
  }
}
