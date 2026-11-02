// Zrzuty ekranów do przeglądu wyglądu (bez telefonu), uruchamiane w CI:
//   SCREENSHOTS=<katalog> flutter test test/screenshots_test.dart
// Bez zmiennej SCREENSHOTS test jest pomijany. Czcionki: Roboto z test/fonts + ikony Material z SDK Fluttera.
// Każda zakładka dolnej nawigacji w motywie jasnym i ciemnym.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bakometr/main.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _out = Platform.environment['SCREENSHOTS'];

Future<void> _loadFonts() async {
  final roboto = FontLoader('Roboto');
  for (final f in ['Regular', 'Bold']) {
    roboto.addFont(Future.value(ByteData.sublistView(File('test/fonts/Roboto-$f.ttf').readAsBytesSync())));
  }
  await roboto.load();
  final root = Platform.environment['FLUTTER_ROOT'];
  final icons = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (root != null && icons.existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())))).load();
  }
}

/// Czeka naprawdę (I/O, baza) i przesuwa zegar testu – bez pumpAndSettle, bo wskaźniki postępu kręcą się w kółko.
Future<void> _wait(WidgetTester t, {int ms = 600}) async {
  await t.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(WidgetTester t, String name) async {
  final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
  await t.runAsync(() async {
    final img = await boundary.toImage(pixelRatio: 1);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('$_out/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

String _slug(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9ąćęłńóśźż]+'), '-');

void main() {
  testWidgets('zrzuty ekranów', (t) async {
    final errors = <String>[];
    final onError = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.exceptionAsString());
    SharedPreferences.setMockInitialValues({});
    final dir = (await t.runAsync(() => Directory.systemTemp.createTemp('shots')))!;
    // path_provider bez wtyczki: wszystkie katalogi w jednym tymczasowym
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (c) async => dir.path);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    await t.runAsync(_loadFonts);
    await t.binding.setSurfaceSize(const Size(412, 892));
    t.view.devicePixelRatio = 1;

    for (final dark in [false, true]) {
      t.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
      await t.pumpWidget(RepaintBoundary(key: const ValueKey('shot'), child: const BakometrApp()));
      await _wait(t, ms: 2500);
      final tabs = find.byType(NavigationDestination);
      final n = tabs.evaluate().length;
      if (n == 0) await _shot(t, 'start_${dark ? 'ciemny' : 'jasny'}');
      for (var i = 0; i < n; i++) {
        final label = (tabs.at(i).evaluate().single.widget as NavigationDestination).label;
        await t.tap(tabs.at(i), warnIfMissed: false);
        await _wait(t);
        await _shot(t, '${i + 1}_${_slug(label)}_${dark ? 'ciemny' : 'jasny'}');
      }
      await t.pumpWidget(const SizedBox());
      await _wait(t, ms: 200);
    }
    t.platformDispatcher.clearPlatformBrightnessTestValue();
    await t.binding.setSurfaceSize(null);
    t.view.resetDevicePixelRatio();
    FlutterError.onError = onError;
    if (errors.isNotEmpty) File('$_out/bledy.txt').writeAsStringSync(errors.join('\n\n'));
  }, skip: _out == null);
}
