# koofr_sync

Wspólny moduł rodzinnych aplikacji: **kopia zapasowa** i **podgląd danych za zgodą obu stron**
na jednym koncie Koofr (WebDAV). Wszystko szyfrowane na telefonie.

## Użycie w innej aplikacji Flutter

```yaml
dependencies:
  koofr_sync:
    git:
      url: https://github.com/rafal6283/nocny-licznik
      path: packages/koofr_sync
  flutter_secure_storage: any
```

```dart
final sync = KoofrSync(appId: 'teczka', store: SecureStore()); // SecureStore: patrz lib/core/cloud.dart w Rytmie Snu
await sync.load();
if (await sync.backupDue()) await sync.backupNow(bytes);
```

Identyfikatory aplikacji: `rytm-snu`, `doba`, `teczka`, `portfel`, `znicz`, `dziennik-talerza`, `kreska`, `polar-ekg`.

## Format (do odtworzenia w Kotlinie — Doba, Kreska)

**Kod odzyskiwania** (jeden na osobę, wspólny dla aplikacji): 18 losowych bajtów + 2 bajty SHA-256(losowe),
base32 Crockford `0123456789ABCDEFGHJKMNPQRSTVWXYZ`, 32 znaki w grupach po 4.

**Klucze** (HKDF-SHA256, sól `koofr_sync v1`, 32 bajty):
- `master = HKDF(losowe, info="master")`
- `backup = HKDF(master, "backup/<appId>")` — AES-256-GCM
- `seed = HKDF(master, "x25519/<appId>")` — prywatny klucz X25519
- `codeCheck = hex(HKDF(master, "check")[0..8])`

**Plik `.ksy`**: `"KSY1" | rodzaj | …`, treść = gzip(dane), AAD = 5 bajtów nagłówka + utf8(appId).
- rodzaj 1 (kopia): `nonce(12) | szyfrogram | tag(16)`, klucz `backup`.
- rodzaj 2 (podgląd): `efemeryczny X25519 pub(32) | nonce(12) | szyfrogram | tag(16)`,
  klucz = `HKDF(X25519(eph, odbiorca) ‖ X25519(nadawca, odbiorca), info="share/<appId>" ‖ ephPub ‖ nadawcaPub ‖ odbiorcaPub)`.

**Układ folderów** (domyślnie `Rodzina/`):
```
_czlonkowie/<osoba>.json                         {"id","name","codeCheck","keys":{"<appId>":"<pub b64url>"}}
<appId>/kopie/<osoba>/RRRRMMDD-GGMM_<telefon>.ksy
<appId>/zgody/<właściciel>__<oglądający>/wlasciciel.json   {"scope":{…},"at":ms}
<appId>/zgody/<właściciel>__<oglądający>/ogladajacy.json   {"at":ms}
<appId>/dane/<właściciel>__<oglądający>.ksy
```
Podgląd jest aktywny tylko, gdy istnieją **oba** pliki zgody. Dane wysyła telefon, na którym właściciel
udzielił zgody (lokalny rejestr w bezpiecznym magazynie) — sam plik na Koofr nie wystarcza.
Po cofnięciu zgody przez którąkolwiek stronę dane są kasowane.

Rotacja kopii: najnowsza z każdego z 7 ostatnich dni + najnowsza z każdego z 4 wcześniejszych tygodni.
