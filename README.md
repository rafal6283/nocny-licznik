# 🌙 Nocny Licznik

Nocny monitor snu na Android i iOS w stylu Sleep Cycle / Sleep as Android — z opcjonalnym **liczeniem puszczanych wiatrów**, sonarem oddechu i trybem CPAP.

## Co potrafi

- **Liczenie wiatrów (opcja, domyślnie wyłączona)** — rozpoznawanie dźwięków modelem [YAMNet](https://github.com/tensorflow/models/tree/master/research/audioset/yamnet) (Google, AudioSet, klasa „Fart”) działającym offline na telefonie
- **Chrapanie, mówienie przez sen, kaszel** — z krótkimi nagraniami do odsłuchu i weryfikacji rano (✓ / ✗)
- **Fazy snu i ocena nocy** — ukryty model Markowa (Viterbi) na wzorcu ruchów w czasie: długie okresy bezruchu = sen głęboki, pojedyncze zmiany pozycji = płytki, częste drobne drgnięcia = REM, gęsty ruch = czuwanie; źródło ruchu: akcelerometr → sonar → dźwięki, a bez sygnału typowy przebieg cykli z wyraźną informacją; plus chrapanie, nieregularność oddechu i fizjologia cykli (estymacja, nie badanie medyczne)
- **Przerwy w oddechu (bezdech)** — wzorzec „oddech/chrapanie → cisza ≥10 s → westchnienie/chrapnięcie”, wskaźnik przerw na godzinę snu z progami 5/15/30 jak dla AHI, nagrania do odsłuchu. Orientacyjnie, nie diagnoza
- **Wykres snu w stylu Sleep Cycle** — płynna fala głębokości snu, pasy zdarzeń, kursor
- **Sonar oddechu (Android)** — niesłyszalny ton 19 kHz z głośnika, echo od klatki piersiowej demodulowane I/Q: częstość oddechu, ruch ciała, przerwy (spadek ≥70%) i spłycenia (≥50%) oddechu ≥10 s, także bez chrapania i przy szumie CPAP; ekran testowy z oddechem na żywo
- **Tryb CPAP** — tłumienie fałszywych wykryć od nieszczelności maski, dane z aparatu wpisywane ręcznie, importowane z CSV programu OSCAR albo **wprost z karty SD ResMed AirSense 10/11** (STR.edf + DATALOG: AHI z podziałem OAI/CAI/HI, nieszczelność 50/95%, ciśnienie, oddech, zdarzenia z godziną na wykresie nocy), statystyka AHI z aparatu
- **Diagnostyka przerwanych nocy** — powód zamknięcia aplikacji z Androida (ApplicationExitInfo), dziennik każdej nocy, ostrzeżenie o optymalizacji baterii z przyciskiem do jej wyłączenia i wskazówkami dla Xiaomi/Samsung/Huawei/OnePlus
- **Ostrzeżenie o zajętym mikrofonie** — gdy inna aplikacja przejmie mikrofon
- **Światło w sypialni** — Android: czujnik światła przez całą noc; iPhone: pomiar przednią kamerą przy starcie i przy otwarciu aplikacji + ręczny wybór
- **Inteligentny budzik** — okno 15/30/45 min, dzwoni w lekkiej fazie snu; narastająca głośność, drzemka, wibracje
- **Zadanie do wyłączenia budzika** — matematyka lub potrząśnięcie telefonem
- **Anty-chrapanie** — delikatne wibracje
- **Tagi nocy** (#fasola, #piwo, #kawa…) i porównanie, co daje najwięcej wiatrów i najgorszy sen
- **Dług snu, cel snu, przypomnienie o pójściu spać**
- **Kołysanki** — biały/różowy/brązowy szum, deszcz, fale, wentylator (generowane w aplikacji) z wygaszaniem
- **Hałas otoczenia** — równoważny poziom dźwięku (Leq) i szczyty co minutę, w dB, z kalibracją mikrofonu i odniesieniem do zaleceń WHO (~30 dB w sypialni)
- **Statystyki jak w Sleep Cycle** — Dni/Tygodnie/Miesiące/Wszystko: jakość snu, regularność, pora snu, pobudka, czas w łóżku, sen, zaśnięcie po, wiatry, chrapanie, kaszel, światło, hałas, przerwy w oddechu; ekran „Więcej” z podsumowaniem i listą nocy
- **Pogoda a sen** — dla każdej nocy temperatura, wilgotność, ciśnienie i jego zmiana w 24 h, wiatr, opady, zachmurzenie ([Open-Meteo](https://open-meteo.com), bez klucza; wysyłane są tylko współrzędne miejscowości) oraz faza Księżyca liczona lokalnie; porównanie nocy przy niskich i wysokich wartościach z korelacją do oceny, długości snu, zasypiania, przebudzeń i chrapania
- **Health Connect** (Android) — każda noc z fazami snu zapisuje się w Health Connect, skąd czytają ją inne aplikacje (np. Life Cycle); włączasz w Ustawieniach → Dane. Odczyt z Health Connect: tętno (krzywa nocy, wpływ na fazy snu), SpO₂ i ODI — np. z zegarka Huawei przez aplikację Health Sync lub z Gadgetbridge
- **Eksport do Kreski** — plik z wiatrami do porównania z ręcznymi wpisami FF
- Dodatkowo: godzina szczytu wiatrów, rekordy, wpływ tagów, światło i hałas a sen

Wszystkie dane i nagrania zostają na telefonie.

## Instalacja

Każdy push na `main` buduje aplikację w GitHub Actions i publikuje wydanie w zakładce **Releases**:

- **Android** — `nocny-licznik.apk`
- **iPhone** — `nocny-licznik.ipa` (niepodpisany), do wgrania przez Sideloadly / AltStore z darmowym Apple ID (ważny 7 dni)

## Jak używać

Połóż telefon na materacu obok poduszki, ekranem do góry, najlepiej na ładowarce. Ustaw budzik, zaznacz tagi, stuknij **Idę spać**.

## Budowanie lokalnie

```bash
bash tool/fetch_model.sh          # model YAMNet → assets/yamnet.tflite
bash tool/prepare_platforms.sh    # flutter create + poprawki (uprawnienia, ikony, tryb audio w tle)
flutter run
```

Kod natywny (usługa w tle, czujnik światła, pomiar kamerą, powiadomienia, wibracje) jest w lokalnym pluginie `packages/bakometr_native`.

### Klucz podpisu Androida

Stały klucz jest w `signing/` — dzięki temu każda nowa wersja instaluje się na poprzedniej bez utraty danych. Repo jest publiczne, więc klucz służy wyłącznie do prywatnego sideloadu.
