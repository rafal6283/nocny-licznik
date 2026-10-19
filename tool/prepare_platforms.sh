#!/usr/bin/env bash
# Generuje katalogi android/ i ios/ (flutter create) i nakłada na nie poprawki Bąkometru.
set -euo pipefail
cd "$(dirname "$0")/.."

flutter create --org pl.rafal --project-name bakometr --platforms "${PLATFORMS:-android,ios}" . >/dev/null
# Szablonowy test odwołuje się do nieistniejącego MyApp
rm -f test/widget_test.dart
rmdir test 2>/dev/null || true

python3 tool/patch_platforms.py
