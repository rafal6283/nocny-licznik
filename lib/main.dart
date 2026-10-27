import 'dart:async';

import 'package:flutter/material.dart';

import 'core/cloud.dart';
import 'core/settings.dart';
import 'core/watch_data.dart';
import 'core/weather.dart';
import 'engine/night_engine.dart';
import 'ui/alarm_screen.dart';
import 'ui/history_screen.dart';
import 'ui/home_screen.dart';
import 'ui/night_detail_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/stats_screen.dart';
import 'ui/theme.dart';
import 'ui/tracking_screen.dart';

final navigatorKey = GlobalKey<NavigatorState>();

/// Błędy złapane w czasie działania — pokazywane na ekranie zamiast cichego zawieszenia.
final startupLog = ValueNotifier<List<String>>([]);

void _log(String s) {
  startupLog.value = [...startupLog.value, s];
  // Błędy w trakcie nocy trafiają też do dziennika nocy.
  if (s.startsWith('BŁĄD') && NightEngine.instance.isActive) {
    NightEngine.instance.journal(s.split('\n').take(3).join(' | '));
  }
}

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (d) {
      _log('BŁĄD UI: ${d.exceptionAsString()}\n${d.stack.toString().split('\n').take(6).join('\n')}');
    };
    ErrorWidget.builder = (d) => Container(
          color: const Color(0xFF3A1020),
          padding: const EdgeInsets.all(8),
          child: Text('Błąd widoku:\n${d.exceptionAsString()}',
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        );
    // Interfejs startuje od razu; inicjalizacja idzie w tle z podglądem kroków.
    runApp(const BakometrApp());
  }, (e, st) {
    _log('BŁĄD: $e\n${st.toString().split('\n').take(6).join('\n')}');
  });
}

class BakometrApp extends StatefulWidget {
  const BakometrApp({super.key});

  @override
  State<BakometrApp> createState() => _BakometrAppState();
}

class _BakometrAppState extends State<BakometrApp> {
  bool ready = false;
  String step = 'Start';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _run(String name, Future<void> Function() f, {bool required = true, int timeoutSec = 8}) async {
    setState(() => step = name);
    _log('→ $name');
    try {
      await f().timeout(Duration(seconds: timeoutSec));
      _log('✓ $name');
    } catch (e) {
      _log('✗ $name: $e');
      if (required) rethrow;
    }
  }

  Future<void> _init() async {
    try {
      await _run('Ustawienia', Settings.instance.load);
      await _run('Baza danych', NightEngine.recoverUnfinished, required: false);
      if (Settings.instance.stagingVersion < NightEngine.stagingVersion) {
        await _run('Przeliczanie faz snu (nowy algorytm)', () async {
          await NightEngine.reanalyzeAll();
          Settings.instance.stagingVersion = NightEngine.stagingVersion;
        }, required: false, timeoutSec: 120);
      }
      unawaited(WeatherService.backfill());
      unawaited(WatchNight.backfillRecent());
      // kopia/podgląd Koofr — w tle, bez wpływu na start
      unawaited(Future.delayed(const Duration(seconds: 5), Cloud.autoRun));
      setState(() => ready = true);
    } catch (_) {
      setState(() => step = 'Start nie powiódł się');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rytm Snu',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      navigatorKey: navigatorKey,
      home: ready ? const Root() : BootScreen(step: step),
    );
  }
}

/// Ekran startowy z diagnostyką — widać, na którym kroku coś utknęło.
class BootScreen extends StatelessWidget {
  final String step;
  const BootScreen({super.key, required this.step});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 40),
            const Center(child: Text('🌙', style: TextStyle(fontSize: 56))),
            const SizedBox(height: 12),
            Center(child: Text('Rytm Snu · $step', style: const TextStyle(color: C.muted))),
            const SizedBox(height: 12),
            const Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3))),
            const SizedBox(height: 24),
            Expanded(child: LogView()),
          ]),
        ),
      ),
    );
  }
}

class LogView extends StatelessWidget {
  const LogView({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: startupLog,
      builder: (c, log, _) => SingleChildScrollView(
        child: SelectableText(log.join('\n'),
            style: const TextStyle(fontSize: 11, color: C.muted, fontFamily: 'monospace')),
      ),
    );
  }
}

/// Przełącza między zakładkami a ekranami nocy/budzika zależnie od stanu silnika.
class Root extends StatefulWidget {
  const Root({super.key});

  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> with WidgetsBindingObserver {
  final engine = NightEngine.instance;
  int tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    engine.addListener(_onEngine);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    engine.removeListener(_onEngine);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      engine.onResumed();
      unawaited(Cloud.autoRun());
    }
    if (engine.isActive) engine.journal('aplikacja: ${s.name}');
  }

  void _onEngine() => setState(() {});

  /// Zakończenie nocy (z ekranu nocy lub po wyłączeniu budzika) → podsumowanie.
  Future<void> _finish({String reason = 'zakończona przez użytkownika'}) async {
    final n = await engine.finish(reason: reason);
    unawaited(Cloud.autoRun(afterNight: true));
    if (n?.id != null && mounted) {
      navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => NightDetailScreen(nightId: n!.id!)));
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (engine.state) {
      case NightState.ringing:
        return AlarmScreen(onDismissed: () => _finish(reason: 'budzik wyłączony'));
      case NightState.tracking:
      case NightState.snoozed:
      case NightState.finishing:
        return TrackingScreen(onStop: _finish);
      case NightState.idle:
        break;
    }
    final pages = [
      HomeScreen(onOpenNight: (id) => _open(id)),
      HistoryScreen(onOpenNight: (id) => _open(id)),
      const StatsScreen(),
      const SettingsScreen(),
    ];
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          ValueListenableBuilder<List<String>>(
            valueListenable: startupLog,
            builder: (c, log, _) {
              final errs = log.where((l) => l.startsWith('BŁĄD') || l.startsWith('✗')).toList();
              if (errs.isEmpty) return const SizedBox();
              return Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 160),
                color: const Color(0xFF3A1020),
                padding: const EdgeInsets.all(8),
                child: SingleChildScrollView(
                  child: SelectableText(errs.join('\n\n'),
                      style: const TextStyle(fontSize: 11, color: Colors.white)),
                ),
              );
            },
          ),
          Expanded(child: IndexedStack(index: tab, children: pages)),
        ]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bedtime_outlined), selectedIcon: Icon(Icons.bedtime), label: 'Noc'),
          NavigationDestination(icon: Icon(Icons.history), label: 'Historia'),
          NavigationDestination(icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: 'Statystyki'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Ustawienia'),
        ],
      ),
    );
  }

  void _open(int id) {
    navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => NightDetailScreen(nightId: id)));
  }
}
