import 'package:flutter/material.dart';

import 'core/settings.dart';
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Settings.instance.load();
  try {
    await NightEngine.recoverUnfinished();
  } catch (_) {}
  runApp(const BakometrApp());
}

class BakometrApp extends StatelessWidget {
  const BakometrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bąkometr',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      navigatorKey: navigatorKey,
      home: const Root(),
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
    if (s == AppLifecycleState.resumed) engine.onResumed();
  }

  void _onEngine() => setState(() {});

  /// Zakończenie nocy (z ekranu nocy lub po wyłączeniu budzika) → podsumowanie.
  Future<void> _finish() async {
    final n = await engine.finish();
    if (n?.id != null && mounted) {
      navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => NightDetailScreen(nightId: n!.id!)));
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (engine.state) {
      case NightState.ringing:
        return AlarmScreen(onDismissed: _finish);
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
      body: SafeArea(child: IndexedStack(index: tab, children: pages)),
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
