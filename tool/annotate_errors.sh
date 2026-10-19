#!/usr/bin/env bash
# Wyciąga z logu buildu linie z błędami i publikuje je jako adnotacje GitHub
# (czytelne przez API nawet bez dostępu do pełnych logów).
LOG="${1:-build.log}"
[ -f "$LOG" ] || { echo "::error::Brak pliku $LOG"; exit 0; }
grep -n -E "error:|Error:|ERROR|What went wrong|FAILURE|e: file|\.java:[0-9]+|\.swift:[0-9]+|\.dart:[0-9]+|Exception|Could not|not found|failed" "$LOG" \
  | grep -v -i "warning" | head -60 > errs.txt || true
if [ ! -s errs.txt ]; then tail -40 "$LOG" > errs.txt; fi
# dzielimy na kawałki (limit długości adnotacji)
split -l 12 errs.txt chunk_
for f in chunk_*; do
  msg=$(sed 's/%/%25/g' "$f" | cut -c1-300 | awk '{printf "%s%%0A", $0}')
  echo "::error title=build ${f#chunk_}::$msg"
done
