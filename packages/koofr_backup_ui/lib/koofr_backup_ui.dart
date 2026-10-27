/// Kopia zapasowa na rodzinnym koncie Koofr — gotowa do wpięcia w aplikację Flutter.
///
/// ```dart
/// // przy starcie
/// await KoofrBackup.setup(MyAdapter());
/// // w ustawieniach
/// const KoofrBackupTile()
/// ```
library;

export 'package:koofr_sync/koofr_sync.dart';

export 'src/backup.dart';
export 'src/screen.dart';
