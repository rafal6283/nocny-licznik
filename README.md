# 🌙 Nocny Licznik

Nocny monitor snu na Android i iOS w stylu Sleep Cycle / Sleep as Android — z głównym naciskiem na **liczenie puszczanych wiatrów**.

## Co potrafi

- **Liczenie wiatrów** — rozpoznawanie dźwięków modelem [YAMNet](https://github.com/tensorflow/models/tree/master/research/audioset/yamnet) (Google, AudioSet, klasa „Fart”) działającym offline na telefonie
- **Chrapanie, mówienie przez sen, kaszel** — z krótkimi nagraniami do odsłuchu i weryfikacji rano (✓ / ✗)
- **Fazy snu i ocena nocy** — ukryty model Markowa (dekodowanie Viterbiego) łączący aktygrafię z ruchu telefonu na materacu, chrapanie, dźwięki i fizjologię cykli snu (estymacja, nie badanie medyczne)
- **Przerwy w oddechu (bezdech)** — wzorzec „oddech/chrapanie → cisza ≥10 s → westchnienie/chrapnięcie”, wskaźnik przerw na godzinę snu z progami 5/15/30 jak dla AHI, nagrania do odsłuchu. Orientacyjnie, nie diagnoza
- **Wykres snu w stylu Sleep Cycle** — płynna fala głębokości snu, pasy zdarzeń, kursor
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
