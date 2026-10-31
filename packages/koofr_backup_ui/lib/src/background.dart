import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'backup.dart';

/// Kopia i wysyłka danych na Koofr w tle (Android, WorkManager), także gdy aplikacja jest zamknięta.
///
/// W aplikacji:
/// ```dart
/// @pragma('vm:entry-point')
/// void koofrCallback() => KoofrBackground.dispatch(() async {
///       await MojeDane.wczytaj();   // przygotowanie danych w osobnym procesie
///       return MojAdapter();
///     });
///
/// // po KoofrBackup.setup(...):
/// KoofrBackground.start(koofrCallback);
/// ```
/// W tle aplikacja tylko czyta swoje dane (kopia, wysyłka do moich aplikacji, podgląd);
/// pobieranie danych z innych aplikacji odbywa się po otwarciu, żeby nie nadpisać zmian.
class KoofrBackground {
  static const task = 'koofr-sync';
  static void Function()? _callback;

  /// Co ile Android ma uruchamiać pracę w tle (najmniej 15 min).
  static const every = Duration(hours: 3);

  static Future<void> start(void Function() callback) async {
    if (!Platform.isAndroid) return;
    _callback = callback;
    try {
      await Workmanager().initialize(callback);
      await refresh();
    } catch (e) {
      debugPrint('KoofrBackground: $e');
    }
  }

  /// Rejestracja (lub zmiana warunków po przełączeniu „tylko Wi-Fi”).
  static Future<void> refresh() async {
    if (!Platform.isAndroid || _callback == null) return;
    final kb = KoofrBackup.instance;
    final wifi = await kb.wifiOnly();
    final cfg = 'v1/${wifi ? 'wifi' : 'any'}';
    final prev = await kb.sync.store.read('ks.bg.cfg');
    if (prev != null && prev != cfg) await Workmanager().cancelByUniqueName(task);
    await Workmanager().registerPeriodicTask(
      task,
      task,
      frequency: every,
      constraints: Constraints(networkType: wifi ? NetworkType.unmetered : NetworkType.connected),
    );
    await kb.sync.store.write('ks.bg.cfg', cfg);
  }

  /// Dodatkowe zadanie okresowe aplikacji (np. alerty cenowe); obsługa w `dispatch(other:)`.
  /// Wywołać po [start].
  static Future<void> registerPeriodic(String name, Duration frequency, {bool network = true}) async {
    if (!Platform.isAndroid || _callback == null) return;
    try {
      await Workmanager().registerPeriodicTask(name, name,
          frequency: frequency,
          constraints: Constraints(networkType: network ? NetworkType.connected : NetworkType.notRequired));
    } catch (e) {
      debugPrint('KoofrBackground: $e');
    }
  }

  static Future<void> cancelPeriodic(String name) async {
    if (!Platform.isAndroid || _callback == null) return;
    try {
      await Workmanager().cancelByUniqueName(name);
    } catch (_) {}
  }

  /// Treść zadania — wywołać z funkcji `@pragma('vm:entry-point')` aplikacji.
  /// [other] obsługuje zadania zarejestrowane przez [registerPeriodic].
  static void dispatch(Future<BackupAdapter> Function() prepare, {Future<void> Function(String name)? other}) {
    Workmanager().executeTask((name, input) async {
      try {
        WidgetsFlutterBinding.ensureInitialized();
        if (name != task) {
          await other?.call(name);
          return true;
        }
        final adapter = await prepare();
        final b = await KoofrBackup.setup(adapter, autoRun: false);
        await b.autoRun(background: true);
      } catch (e) {
        debugPrint('KoofrBackground: $e');
      }
      return true;
    });
  }
}
