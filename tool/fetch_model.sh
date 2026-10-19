#!/usr/bin/env bash
# Pobiera model YAMNet (TFLite, wejście 15600 próbek @16 kHz, 521 klas AudioSet).
set -euo pipefail
OUT="assets/yamnet.tflite"
if [ -s "$OUT" ] && [ "$(wc -c < "$OUT")" -gt 1000000 ]; then
  echo "Model już jest: $OUT"; exit 0
fi

URLS=(
  "https://storage.googleapis.com/download.tensorflow.org/models/tflite/task_library/audio_classification/android/lite-model_yamnet_classification_tflite_1.tflite"
  "https://storage.googleapis.com/mediapipe-models/audio_classifier/yamnet/float32/latest/yamnet.tflite"
  "https://storage.googleapis.com/mediapipe-models/audio_classifier/yamnet/float32/1/yamnet.tflite"
)
for u in "${URLS[@]}"; do
  echo "Próbuję: $u"
  if curl -fsSL --retry 3 -o "$OUT" "$u" && [ "$(wc -c < "$OUT")" -gt 1000000 ]; then
    echo "OK ($(wc -c < "$OUT") B)"; exit 0
  fi
done

# Ostatnia deska ratunku: Kaggle (archiwum tar.gz)
TMP=$(mktemp -d)
if curl -fsSL -o "$TMP/m.tgz" "https://www.kaggle.com/api/v1/models/google/yamnet/tfLite/classification-tflite/1/download"; then
  tar -xzf "$TMP/m.tgz" -C "$TMP" && cp "$(find "$TMP" -name '*.tflite' | head -1)" "$OUT" && exit 0
fi
echo "Nie udało się pobrać modelu YAMNet" >&2
exit 1
