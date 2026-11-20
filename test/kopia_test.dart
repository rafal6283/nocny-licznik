import 'dart:io';

import 'package:bakometr/core/cloud.dart';
import 'package:bakometr/core/db.dart';
import 'package:bakometr/core/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koofr_sync/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Kopia na Koofr → nowy telefon (tylko kod odzyskiwania) → przywrócenie: noce i ustawienia wracają.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('kopia');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (c) async => dir.path);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // serwer WebDAV w pamięci potrzebuje prawdziwego HttpClient (flutter_test podstawia atrapę)
    HttpOverrides.global = null;
  });

  test('przywrócenie kopii na czystym telefonie', () async {
    SharedPreferences.setMockInitialValues({'detectFarts': false, 'sensitivity': 0.7});
    final path = await Db.path;
    await Db.instance.close();
    if (await File(path).exists()) await File(path).delete();
    final start = DateTime(2026, 11, 18, 23);
    await Db.instance.insertNight(Night(start: start, end: start.add(const Duration(hours: 7)), durationMin: 420));
    await Db.instance.insertNight(Night(start: start.add(const Duration(days: 1)), end: start.add(const Duration(days: 1, hours: 6)), durationMin: 360));

    final bytes = await Cloud.buildBackupBytes();
    final restored = await kopiaNaNowyTelefon('rytm-snu', bytes);

    // „nowy telefon”: pusta baza i ustawienia
    await Db.instance.close();
    await File(path).delete();
    SharedPreferences.setMockInitialValues({});
    expect(await Db.instance.nights(), isEmpty);

    expect(await Cloud.restoreBytes(restored.data), 2);
    final nights = await Db.instance.nights();
    expect(nights.map((n) => n.durationMin), unorderedEquals([420, 360]));
    final p = await SharedPreferences.getInstance();
    expect(p.getDouble('sensitivity'), 0.7);
    expect(p.getBool('detectFarts'), isFalse);
  });
}
