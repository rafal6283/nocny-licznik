import 'package:flutter/foundation.dart';

/// Sygnał „dane się zmieniły” — ekrany listy i statystyk przeładowują się.
final dataVersion = ValueNotifier<int>(0);

void dataChanged() => dataVersion.value++;
