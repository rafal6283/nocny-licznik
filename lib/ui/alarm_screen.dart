import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../core/fmt.dart';
import '../core/settings.dart';
import '../engine/night_engine.dart';
import 'theme.dart';

/// Dzwoniący budzik: drzemka albo wyłączenie (po zadaniu, jeśli ustawione).
class AlarmScreen extends StatefulWidget {
  final Future<void> Function() onDismissed;
  const AlarmScreen({super.key, required this.onDismissed});

  @override
  State<AlarmScreen> createState() => _AlarmScreenState();
}

class _AlarmScreenState extends State<AlarmScreen> {
  final e = NightEngine.instance;
  final s = Settings.instance;
  Timer? _tick;
  bool solving = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (solving) {
      return s.captcha == 'shake'
          ? ShakeTask(target: s.shakeCount, onDone: widget.onDismissed, onCancel: () => setState(() => solving = false))
          : MathTask(count: s.mathProblems, onDone: widget.onDismissed, onCancel: () => setState(() => solving = false));
    }
    final now = DateTime.now();
    return Scaffold(
      backgroundColor: C.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Spacer(),
            const Text('☀️', textAlign: TextAlign.center, style: TextStyle(fontSize: 56)),
            Text(hhmm(now),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 96, fontWeight: FontWeight.w200, color: C.moon, height: 1)),
            const SizedBox(height: 8),
            Text(e.ringReason, textAlign: TextAlign.center, style: const TextStyle(color: C.muted)),
            const SizedBox(height: 28),
            Text(s.detectFarts ? 'Tej nocy: 💨 ${fartsLabel(e.farts)}' : 'W łóżku ${durHM(e.elapsed.inMinutes)}',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, color: C.gas)),
            const Spacer(),
            SizedBox(
              height: 64,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: C.surface2, foregroundColor: C.text),
                onPressed: e.snooze,
                icon: const Icon(Icons.snooze),
                label: Text('Drzemka ${s.snoozeMin} min', style: const TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 64,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: C.moon, foregroundColor: C.bg),
                onPressed: () {
                  if (s.captcha == 'none') {
                    widget.onDismissed();
                  } else {
                    setState(() => solving = true);
                  }
                },
                icon: const Icon(Icons.alarm_off),
                label: Text(s.captcha == 'none' ? 'Wyłącz' : 'Wyłącz (zadanie)',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Zadanie: działania matematyczne.
class MathTask extends StatefulWidget {
  final int count;
  final Future<void> Function() onDone;
  final VoidCallback onCancel;
  const MathTask({super.key, required this.count, required this.onDone, required this.onCancel});

  @override
  State<MathTask> createState() => _MathTaskState();
}

class _MathTaskState extends State<MathTask> {
  final r = Random();
  late String q;
  late int answer;
  int solved = 0;
  String input = '';
  bool wrong = false;

  @override
  void initState() {
    super.initState();
    _next();
  }

  void _next() {
    final kind = r.nextInt(3);
    if (kind == 0) {
      final a = 12 + r.nextInt(80), b = 12 + r.nextInt(80);
      q = '$a + $b';
      answer = a + b;
    } else if (kind == 1) {
      final a = 40 + r.nextInt(60), b = 11 + r.nextInt(a - 12);
      q = '$a − $b';
      answer = a - b;
    } else {
      final a = 3 + r.nextInt(9), b = 6 + r.nextInt(9);
      q = '$a × $b';
      answer = a * b;
    }
    input = '';
  }

  void _key(String k) {
    setState(() {
      wrong = false;
      if (k == '⌫') {
        if (input.isNotEmpty) input = input.substring(0, input.length - 1);
      } else if (k == 'OK') {
        if (int.tryParse(input) == answer) {
          solved++;
          if (solved >= widget.count) {
            widget.onDone();
            return;
          }
          _next();
        } else {
          wrong = true;
          input = '';
        }
      } else if (input.length < 4) {
        input += k;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '⌫', '0', 'OK'];
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close), onPressed: widget.onCancel),
        title: Text('Zadanie ${solved + 1} z ${widget.count}'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            const Spacer(),
            Text('$q = ?', style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w300, color: C.text)),
            const SizedBox(height: 12),
            Text(input.isEmpty ? ' ' : input,
                style: TextStyle(fontSize: 40, fontWeight: FontWeight.w700, color: wrong ? C.danger : C.moon)),
            if (wrong) const Text('Spróbuj jeszcze raz', style: TextStyle(color: C.danger)),
            const Spacer(),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.7,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final k in keys)
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: k == 'OK' ? C.moon : C.surface2,
                      foregroundColor: k == 'OK' ? C.bg : C.text,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: () => _key(k),
                    child: Text(k, style: const TextStyle(fontSize: 24)),
                  ),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}

/// Zadanie: potrząśnij telefonem N razy.
class ShakeTask extends StatefulWidget {
  final int target;
  final Future<void> Function() onDone;
  final VoidCallback onCancel;
  const ShakeTask({super.key, required this.target, required this.onDone, required this.onCancel});

  @override
  State<ShakeTask> createState() => _ShakeTaskState();
}

class _ShakeTaskState extends State<ShakeTask> {
  final e = NightEngine.instance;
  int shakes = 0;
  bool done = false;

  @override
  void initState() {
    super.initState();
    e.resetShakes();
    e.onShake = (n) {
      if (!mounted || done) return;
      setState(() => shakes = n);
      if (n >= widget.target) {
        done = true;
        e.onShake = null;
        widget.onDone();
      }
    };
  }

  @override
  void dispose() {
    e.onShake = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = (shakes / widget.target).clamp(0.0, 1.0);
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(leading: IconButton(icon: const Icon(Icons.close), onPressed: widget.onCancel)),
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('📳', style: TextStyle(fontSize: 64)),
          const SizedBox(height: 16),
          const Text('Potrząśnij telefonem!', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
          const SizedBox(height: 24),
          SizedBox(
            width: 220,
            height: 220,
            child: Stack(fit: StackFit.expand, children: [
              CircularProgressIndicator(value: f, strokeWidth: 14, backgroundColor: C.surface2, color: C.gas),
              Center(
                child: Text('$shakes / ${widget.target}',
                    style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
