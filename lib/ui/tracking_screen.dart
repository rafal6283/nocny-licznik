import 'dart:async';

import 'package:flutter/material.dart';

import '../core/fmt.dart';
import '../core/models.dart';
import '../engine/night_engine.dart';
import 'theme.dart';

/// Ekran w trakcie nocy — ciemny, z licznikiem na żywo.
class TrackingScreen extends StatefulWidget {
  final Future<void> Function() onStop;
  const TrackingScreen({super.key, required this.onStop});

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen> {
  final e = NightEngine.instance;
  Timer? _tick;
  bool dim = false;

  @override
  void initState() {
    super.initState();
    e.addListener(_r);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _r());
  }

  @override
  void dispose() {
    e.removeListener(_r);
    _tick?.cancel();
    super.dispose();
  }

  void _r() {
    if (mounted) setState(() {});
  }

  Future<void> _confirmStop() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Zakończyć noc?'),
        content: const Text('Nagrywanie się zatrzyma i zobaczysz podsumowanie.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Śpię dalej')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Zakończ')),
        ],
      ),
    );
    if (ok == true) await widget.onStop();
  }

  @override
  Widget build(BuildContext context) {
    final n = e.night;
    final now = DateTime.now();
    final finishing = e.state == NightState.finishing;
    final level = ((e.levelDb + 70) / 60).clamp(0.0, 1.0);
    final recent = e.liveEvents.reversed.where((x) => x.type != SoundType.snore).take(4).toList();
    final snoringNow = e.minutes.isNotEmpty && e.minutes.last.snore;

    String status;
    if (finishing) {
      status = 'Zapisuję noc i liczę fazy snu…';
    } else if (e.state == NightState.snoozed) {
      status = 'Drzemka do ${hhmm(e.snoozeUntil!)}';
    } else if (e.lullabyPlaying) {
      status = 'Gra kołysanka — liczenie ruszy po jej końcu';
    } else if (!e.analysisActive && e.analysisFrom != null) {
      status = 'Nasłuch od ${hhmm(e.analysisFrom!)}';
    } else {
      status = 'Nasłuchuję… śpij spokojnie';
    }

    final body = SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(status, style: const TextStyle(color: C.muted))),
            if (n?.alarmAt != null)
              Row(children: [
                const Icon(Icons.alarm, size: 16, color: C.moon),
                const SizedBox(width: 4),
                Text(
                  n!.smartWindowMin > 0
                      ? '${hhmm(n.alarmAt!.subtract(Duration(minutes: n.smartWindowMin)))}–${hhmm(n.alarmAt!)}'
                      : hhmm(n.alarmAt!),
                  style: const TextStyle(color: C.moon),
                ),
              ]),
          ]),
          const Spacer(),
          Text(hhmm(now),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 88, fontWeight: FontWeight.w200, color: C.text, height: 1)),
          Text('w łóżku ${durHM(e.elapsed.inMinutes)}',
              textAlign: TextAlign.center, style: const TextStyle(color: C.muted)),
          const SizedBox(height: 36),
          Text('${e.farts}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 72, fontWeight: FontWeight.w700, color: C.gas, height: 1)),
          Text('💨 ${plural(e.farts, 'bąk', 'bąki', 'bąków')} tej nocy',
              textAlign: TextAlign.center, style: const TextStyle(color: C.gas)),
          const SizedBox(height: 24),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _pill(snoringNow ? '😴 chrapanie' : '😴 cisza', snoringNow ? C.light : C.muted),
            const SizedBox(width: 8),
            _pill('💬 ${e.talks}', C.rem),
            const SizedBox(width: 8),
            _pill('🫁 ${e.apneas}', C.danger),
            const SizedBox(width: 8),
            _pill('☀️ ${luxLabel(e.lastLux)}', C.moon),
          ]),
          const SizedBox(height: 18),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
                value: level, minHeight: 6, backgroundColor: C.surface2, color: C.gas.withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 6),
          Text(
            e.classifierError ?? (e.lastHeard.isEmpty ? 'Głośność otoczenia' : 'Ostatnio: ${e.lastHeard}'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: e.classifierError != null ? C.danger : C.muted),
          ),
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final ev in recent)
              Text('${ev.type.emoji} ${hhmmss(ev.ts)} · ${ev.type.label} (${(ev.confidence * 100).round()}%)',
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: C.muted)),
          ],
          const Spacer(),
          if (e.micBlocked)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '⚠️ Mikrofon zajęty przez inną aplikację (np. inny tracker snu). Dźwięki nie są teraz liczone.',
                textAlign: TextAlign.center,
                style: TextStyle(color: C.moon),
              ),
            ),
          if (e.lastError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(e.lastError!, textAlign: TextAlign.center, style: const TextStyle(color: C.danger)),
            ),
          Row(children: [
            if (e.lullabyPlaying)
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: e.stopLullabyNow,
                  icon: const Icon(Icons.music_off),
                  label: const Text('Wycisz'),
                ),
              ),
            if (e.lullabyPlaying) const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: e.measureLuxNow,
                icon: const Icon(Icons.wb_sunny_outlined),
                label: const Text('Światło'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => setState(() => dim = !dim),
                icon: const Icon(Icons.brightness_2_outlined),
                label: const Text('Przyciemnij'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            height: 54,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: C.surface2, foregroundColor: C.text),
              onPressed: finishing ? null : _confirmStop,
              child: Text(e.state == NightState.snoozed ? 'Wstaję — zakończ noc' : 'Zakończ noc'),
            ),
          ),
        ]),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        body,
        if (dim)
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => dim = false),
              child: Container(
                color: Colors.black.withValues(alpha: 0.93),
                alignment: Alignment.center,
                child: Text('${hhmm(now)}\n💨 ${e.farts}',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 28, color: C.muted.withValues(alpha: 0.35))),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _pill(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(20)),
        child: Text(t, style: TextStyle(fontSize: 12, color: c)),
      );
}
