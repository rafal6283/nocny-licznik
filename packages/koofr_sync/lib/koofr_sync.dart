/// Kopia zapasowa i podgląd danych za zgodą na rodzinnym koncie Koofr.
///
/// Użycie w aplikacji Flutter (szczegóły w README pakietu):
/// ```dart
/// final sync = KoofrSync(appId: 'rytm-snu', store: MySecureStore());
/// await sync.load();
/// await sync.connect(KoofrConfig(email: '…', appPassword: '…'));
/// await sync.join(newName: 'Rafał', code: await RecoveryCode.generate());
/// await sync.backupNow(bytes);
/// ```
library;

export 'src/config.dart';
export 'src/crypto.dart' show KsCrypto, KsCryptoException;
export 'src/recovery_code.dart';
export 'src/sync.dart';
export 'src/webdav.dart' show KoofrException, DavEntry, WebDav;
