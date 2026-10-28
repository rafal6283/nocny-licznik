import 'package:flutter/material.dart';

import '../core/bus.dart';
import '../core/db.dart';
import '../core/fmt.dart';
import '../core/models.dart';
import '../core/settings.dart';
import 'theme.dart';

class HistoryScreen extends StatefulWidget {
  final void Function(int nightId) onOpenNight;
  const HistoryScreen({super.key, required this.onOpenNight});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Night>? nights;

  @override
  void initState() {
    super.initState();
    dataVersion.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    dataVersion.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final r = await Db.instance.nights();
    if (mounted) setState(() => nights = r);
  }

  @override
  Widget build(BuildContext context) {
    final list = nights;
    if (list == null) return const Center(child: CircularProgressIndicator());
    if (list.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('Tu pojawią się Twoje noce.\nPierwsza już dziś? 🌙',
              textAlign: TextAlign.center, style: TextStyle(color: C.muted, fontSize: 16)),
        ),
      );
    }
    // rekord wiatrów tylko przy włączonym liczeniu — inaczej żadnych śladów, także w historii
    final record = Settings.instance.detectFarts ? list.map((n) => n.fartCount).reduce((a, b) => a > b ? a : b) : 0;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: list.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (c, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('Historia', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          );
        }
        final n = list[i - 1];
        final isRecord = record > 0 && n.fartCount == record;
        final scoreColor = n.score >= 80 ? C.gas : (n.score >= 60 ? C.moon : C.danger);
        return Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => widget.onOpenNight(n.id!),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: scoreColor, width: 3),
                  ),
                  child: Text('${n.score}', style: TextStyle(fontWeight: FontWeight.w700, color: scoreColor)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(dayLabel(nightOf(n.start)), style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text('${hhmm(n.start)}–${n.end != null ? hhmm(n.end!) : '?'} · ${durHM(n.durationMin)} snu',
                        style: const TextStyle(color: C.muted, fontSize: 12)),
                    if (n.tags.isNotEmpty)
                      Text(n.tags.map((t) => '#$t').join(' '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: C.muted, fontSize: 12)),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (Settings.instance.detectFarts) ...[
                    Text('💨 ${n.fartCount}',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: C.gas)),
                    if (isRecord) const Text('🏆 rekord', style: TextStyle(fontSize: 11, color: C.moon)),
                  ] else
                    Text(durHM(n.durationMin), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  if (n.cpap) const Text('😷 CPAP', style: TextStyle(fontSize: 11, color: C.muted)),
                  if (n.snoreMin > 0) Text('😴 ${durHM(n.snoreMin)}', style: const TextStyle(fontSize: 11, color: C.muted)),
                  if (n.apneaIndex >= 5)
                    Text('🫁 ${n.apneaIndex.toStringAsFixed(1)}/h', style: const TextStyle(fontSize: 11, color: C.danger)),
                ]),
              ]),
            ),
          ),
        );
      },
    );
  }
}
