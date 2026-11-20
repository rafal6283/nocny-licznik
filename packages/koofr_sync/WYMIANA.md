# Wymiana danych między aplikacjami — kontrakt

Aplikacje tej samej osoby wymieniają pliki przez Koofr: `Rodzina/_wymiana/<osoba>/<nazwa>.ksy`
(szyfrowane kluczem osoby, format `.ksy` opisany w README). Ten plik mówi, **kto wysyła który plik,
w jakim formacie i kto go czyta**. W kodzie to samo jest w `lib/src/wymiana.dart` (`kontraktWymiany`),
a przykłady każdego pliku w `wymiana/*.json` (też jako stałe `wymianaPrzyklady` dla testów).

## Pliki

| Plik | Format | Nadawca | Czytają | Treść |
|---|---|---|---|---|
| `rytm-snu` | wymiana-zdarzen v1, source `rytm-snu` (dawniej `nocny-licznik`) | Rytm Snu | Kreska, Dziennik talerza, Doba | noce z nasłuchem (`windows`) i zdarzenia `fart`; tylko gdy dodatek FF jest włączony |
| `rytm-snu-rytm` | wymiana-zdarzen v1, source `rytm-snu-rytm` | Rytm Snu | Doba, Kreska | czas z tętnem z opaski, zdarzenia `af` (nieregularny rytm) |
| `czynniki-sen` | czynniki-dnia v1, source `rytm-snu` | Rytm Snu | Polar EKG, Forma, Doba | `sleep_min, score, awakenings, apnea_idx, snore_min, hr_avg, bed_h` |
| `polar-ekg` | wymiana-zdarzen v1, source `polar-ekg` | Polar EKG | Kreska, Doba, Rytm Snu | okna zapisu EKG, zdarzenia `af` |
| `polar-noce` | noc-polar v1 | Polar EKG | Rytm Snu | zapisy nocne minuta po minucie, kolumny `t, hr, rmssd, act, s, v, af` |
| `czynniki-polar` | czynniki-dnia v1, source `polar-ekg` | Polar EKG | Doba, Forma | `hrv, af_min, af_n` |
| `czynniki-posilki` | czynniki-dnia v1, source `dziennik-talerza` | Dziennik talerza | Polar EKG, Forma, Doba, Rytm Snu | `meals, kcal, big_meal_kcal, last_meal_h, eve_kcal, alcohol, alcohol_last_h, coffee, coffee_last_h` (pory jako godzina z ułamkiem) |
| `czynniki-leki` | czynniki-dnia v1, source `teczka` | Teczka | Polar EKG, Doba | `doses, taken, missed` (bez nazw leków) |
| `czynniki-portfel` | czynniki-dnia v1, source `portfel` | Portfel | Doba | `value` |
| `czynniki-forma` | czynniki-dnia v1, source `forma` | Forma | Doba, Rytm Snu, Polar EKG | `train_min, train_kcal, rpe_max, end_h, other_min` |
| `czynniki-ruch` | czynniki-dnia v1, source `doba` | Doba | Polar EKG | `steps, sport_min, walk_min, work_min, travel_min` |
| `kreska-<licznik>` | wymiana-zdarzen v1, source `kreska`, `counter` | Kreska | Dziennik talerza, Doba | kliknięcia `tap`, `day_totals` |
| `kreska-z-<zdarzenie>` | wymiana-zdarzen v1, source `kreska`, `kind: tracker` | Kreska | Polar EKG, Doba | odcinki `session` bez pauz, `day_totals` |

## Formaty

**wymiana-zdarzen v1**
```json
{"format": "wymiana-zdarzen", "version": 1, "source": "…", "exported_at": ms,
 "windows": [{"start": ms, "end": ms}],
 "events": [{"id": "…", "type": "fart|af|tap|session", "start": ms, "end": ms?, "confidence": 0.8?, "verified": true|false|null}],
 "counter": "…"?, "kind": "tracker"?, "day_totals": [{"date": "RRRR-MM-DD", "total": n}]?}
```
Czasy w ms od epoki (UTC). Plik zawiera całą historię źródła — import zastępuje poprzednie dane z tego źródła.

**czynniki-dnia v1**
```json
{"format": "czynniki-dnia", "version": 1, "source": "…", "exported_at": ms,
 "days": [{"date": "RRRR-MM-DD", "<pole>": liczba | null, …}]}
```
Jedna data najwyżej raz. Pola inne niż `date` są liczbami; odbiorca ignoruje pola, których nie zna.

**noc-polar v1** — `columns` (pierwsza `t` = ms), `recordings: [{start, end, minutes: [[…]], pauses}]`,
każdy wiersz `minutes` ma tyle wartości, ile `columns`.

## Zasady

1. **Źródła po przedrostku.** Aplikacja pobiera plik, gdy `nazwa == przedrostek` lub `nazwa` zaczyna się od
   `przedrostek-` (`zrodloPasuje`). Uwaga: `rytm-snu` pasuje też do `rytm-snu-rytm`, `kreska` do `kreska-z-…`,
   `czynniki` do wszystkich `czynniki-…`. **Każda aplikacja musi wczytać bez wyjątku każdy pasujący plik** —
   ten, którego nie potrzebuje, pomija. (Kreska na Androidzie rzucała wyjątek na `rytm-snu-rytm`, co
   zatrzymywało całą wymianę — naprawione w listopadzie 2026.)
2. **Zgodność wstecz.** Nowe pola można dodawać. Zmiana znaczenia lub usunięcie pola = nowa `version`
   albo nowy plik — najpierw aktualizacja odbiorców, potem nadawcy.
3. **Nowy plik** — dopisz go tutaj, w `lib/src/wymiana.dart` i dodaj przykład `wymiana/<nazwa>.json`,
   potem `python3 tool/gen_przyklady.py`.
4. **Testy.** `test/wymiana_test.dart` w każdej aplikacji Fluttera sprawdza: plik wysyłany przechodzi
   `sprawdzWymiane`, a każdy przykład pasujący do źródeł aplikacji wczytuje się bez wyjątku.
   Doba i Kreska (Kotlin) mają test JUnit `WymianaTest`, który w CI pobiera `wymiana/*.json` z tego repozytorium.
5. **Dziennik wymiany.** `KoofrSync.exchangeLog()` zapisuje na telefonie, kiedy plik wysłano/wczytano i ostatni błąd;
   pokazuje to ekran „Stan wymiany” (`ExchangeStatusScreen` w `koofr_backup_ui`, odpowiednik w Dobie i Kresce).
   Błąd jednego pliku nie blokuje pozostałych.
