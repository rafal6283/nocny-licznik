import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// Wyniki jednej klasyfikacji (okno ~0,975 s).
class ClassScores {
  final double fart;
  final double snore;
  final double speech;
  final double cough;
  final String top;
  final double topScore;
  const ClassScores(this.fart, this.snore, this.speech, this.cough, this.top, this.topScore);
}

/// YAMNet (Google, AudioSet, 521 klas) uruchamiany lokalnie przez TensorFlow Lite.
/// Wejście: 15 600 próbek float, 16 kHz, mono, zakres [-1, 1].
class SoundClassifier {
  static const sampleRate = 16000;
  static const windowLen = 15600;

  final Interpreter _it;
  final List<String> _labels;
  final int _iFart, _iSnore, _iSpeech, _iCough;
  final List<int> _inShape;
  final int _scoresOutput;

  SoundClassifier._(this._it, this._labels, this._iFart, this._iSnore, this._iSpeech, this._iCough,
      this._inShape, this._scoresOutput);

  static Future<SoundClassifier> load() async {
    final it = await Interpreter.fromAsset('assets/yamnet.tflite');
    var inShape = it.getInputTensor(0).shape;
    // Pełny YAMNet z TF Hub ma wejście dynamiczne [-1] — ustawiamy długość okna.
    if (inShape.length == 1 && inShape[0] != windowLen) {
      it.resizeInputTensor(0, [windowLen]);
      it.allocateTensors();
      inShape = it.getInputTensor(0).shape;
    }
    final outs = it.getOutputTensors();
    final outShapes = [for (final t in outs) t.shape];
    var scores = 0;
    for (var i = 0; i < outShapes.length; i++) {
      if (outShapes[i].isNotEmpty && outShapes[i].last == 521) {
        scores = i;
        break;
      }
    }

    final csv = await rootBundle.loadString('assets/yamnet_class_map.csv');
    final labels = <String>[];
    for (final line in csv.split('\n').skip(1)) {
      if (line.trim().isEmpty) continue;
      // index,mid,display_name  (nazwa może być w cudzysłowie i zawierać przecinki)
      final parts = line.split(',');
      var name = parts.sublist(2).join(',').trim();
      if (name.startsWith('"') && name.endsWith('"')) name = name.substring(1, name.length - 1);
      labels.add(name);
    }
    int idx(String n, int fallback) {
      final i = labels.indexOf(n);
      return i >= 0 ? i : fallback;
    }

    return SoundClassifier._(it, labels, idx('Fart', 55), idx('Snoring', 38), idx('Speech', 0),
        idx('Cough', 42), inShape, scores);
  }

  ClassScores classify(Float32List window) {
    final samples = List<double>.generate(window.length, (i) => window[i]);
    final Object input = _inShape.length == 2 ? [samples] : samples;
    _it.runInference([input]);

    // Surowe bajty wyjścia → float32. Przy wielu ramkach bierzemy maksimum.
    final raw = _it.getOutputTensor(_scoresOutput).data;
    final bd = ByteData.sublistView(raw);
    final count = raw.lengthInBytes ~/ 4;
    const classes = 521;
    final s = List<double>.filled(classes, 0);
    for (var i = 0; i < count; i++) {
      final v = bd.getFloat32(i * 4, Endian.host);
      final c = i % classes;
      if (v > s[c]) s[c] = v;
    }

    var top = 0;
    for (var i = 1; i < s.length; i++) {
      if (s[i] > s[top]) top = i;
    }
    return ClassScores(s[_iFart], s[_iSnore], s[_iSpeech], s[_iCough],
        top < _labels.length ? _labels[top] : '?', s[top]);
  }

  void close() => _it.close();
}
