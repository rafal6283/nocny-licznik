#!/usr/bin/env bash
# Wyciąga z logu buildu fragmenty z błędami i publikuje je jako adnotacje GitHub
# (czytelne przez API nawet bez dostępu do pełnych logów).
LOG="${1:-build.log}"
[ -f "$LOG" ] || { echo "::error::Brak pliku $LOG"; exit 0; }
{
  # Gradle: blok „What went wrong” do „Try:”
  awk '/What went wrong/{f=1} /^\* Try:/{f=0} f' "$LOG"
  # Kotlin/Java/Swift/Dart: linie błędów kompilatora
  grep -E "^e: |error:|error •|\.java:[0-9]+: error|\.swift:[0-9]+:[0-9]+: error|\.dart:[0-9]+:[0-9]+: Error" "$LOG"
} | awk '!seen[$0]++' | head -80 > errs.txt
[ -s errs.txt ] || tail -40 "$LOG" > errs.txt
split -l 10 errs.txt chunk_
for f in chunk_*; do
  msg=$(sed 's/%/%25/g' "$f" | cut -c1-400 | awk '{printf "%s%%0A", $0}')
  echo "::error title=build ${f#chunk_}::$msg"
done
