import 'package:flutter/material.dart';

import '../../core/settings.dart';
import '../../cpap/cpap_data.dart';
import '../../cpap/cpap_import.dart';
import '../theme.dart';
import 'cpap_day_view.dart';
import 'cpap_overview.dart';

/// Analiza danych z aparatu CPAP w stylu OSCAR: Dzień · Przegląd · Statystyki.
class CpapScreen extends StatefulWidget {
  final DateTime? initialDay;
  const CpapScreen({super.key, this.initialDay});

  @override
  State<CpapScreen> createState() => _CpapScreenState();
}

class _CpapScreenState extends State<CpapScreen> with SingleTickerProviderStateMixin {
  late final TabController tabs = TabController(length: 3, vsync: this);
  List<CardDay> days = [];
  List<DateTime> dates = [];
  Map<DateTime, CardDay> byDate = {};
  DateTime? day;
  CpapDevice? device;
  bool loading = true;
  bool importing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final d = await CpapStore.days();
    final folders = [for (final f in await CpapStore.dayFolders()) parseYmd(f)].whereType<DateTime>();
    final dev = await CpapStore.device();
    final all = {for (final x in d) x.date, ...folders}.toList()..sort();
    if (!mounted) return;
    setState(() {
      days = d;
      byDate = {for (final x in d) x.date: x};
      dates = all;
      device = dev;
      loading = false;
      final want = widget.initialDay == null
          ? null
          : DateTime(widget.initialDay!.year, widget.initialDay!.month, widget.initialDay!.day);
      if (day == null || !all.contains(day)) {
        day = (want != null && all.contains(want)) ? want : (all.isEmpty ? null : all.last);
      }
    });
  }

  Future<void> _import() async {
    setState(() => importing = true);
    String? msg;
    try {
      msg = await CardImport.run();
    } catch (e) {
      msg = 'Import z karty nie powiódł się: $e';
    }
    if (!mounted) return;
    setState(() => importing = false);
    if (msg != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 6)));
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final dev = device;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Analiza CPAP'),
          if (dev != null && dev.model.isNotEmpty)
            Text('${dev.model}${dev.serial.isNotEmpty ? ' · nr ${dev.serial}' : ''}',
                style: const TextStyle(fontSize: 11, color: C.muted)),
        ]),
        actions: [
          IconButton(
            tooltip: 'Importuj z karty SD',
            onPressed: importing ? null : _import,
            icon: importing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sd_card_outlined),
          ),
        ],
        bottom: TabBar(controller: tabs, tabs: const [Tab(text: 'Dzień'), Tab(text: 'Przegląd'), Tab(text: 'Statystyki')]),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : dates.isEmpty
              ? _empty()
              : TabBarView(controller: tabs, children: [
                  CpapDayView(
                    dates: dates,
                    summaries: byDate,
                    day: day!,
                    waveDays: Settings.instance.cpapWaveDays,
                    onDay: (d) => setState(() => day = d),
                  ),
                  CpapOverview(
                    days: days,
                    onOpenDay: (d) {
                      setState(() => day = d);
                      tabs.animateTo(0);
                    },
                  ),
                  CpapStatsView(days: days),
                ]),
    );
  }

  Widget _empty() => ListView(padding: const EdgeInsets.all(24), children: [
        const Icon(Icons.sd_card_outlined, size: 56, color: C.muted),
        const SizedBox(height: 12),
        const Text('Brak danych z aparatu', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Text(
          'Wyjmij kartę SD z aparatu ResMed AirSense 10/11, włóż ją do czytnika podłączonego do telefonu (USB-C/OTG) '
          'i wskaż jej główny folder. Aplikacja skopiuje dane i pokaże je jak OSCAR: każdą noc z przepływem oddechu, '
          'zdarzeniami, ciśnieniem i nieszczelnością, trendy i statystyki.',
          textAlign: TextAlign.center,
          style: TextStyle(color: C.muted, height: 1.4),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: importing ? null : _import,
          icon: const Icon(Icons.sd_card),
          label: const Text('Importuj z karty SD'),
        ),
      ]);
}
