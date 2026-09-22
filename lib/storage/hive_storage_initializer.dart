import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'legacy_hive_migration.dart';

typedef StoragePathProvider = Future<String> Function();

abstract final class HiveStorageInitializer {
  static Future<void> initialize({required String boxName}) async {
    final homePath = await resolveHomePath();
    if (homePath == null) {
      await Hive.initFlutter();
      return;
    }

    try {
      final legacyDocumentsPath =
          (await getApplicationDocumentsDirectory()).path;
      await migrateLegacyHiveBox(
        boxName: boxName,
        legacyDirectory: legacyDocumentsPath,
        targetDirectory: homePath,
      );
    } on MissingPlatformDirectoryException {
      // A configured Documents directory is not required for new installations.
    }
    Hive.init(homePath);
  }

  @visibleForTesting
  static Future<String?> resolveHomePath({
    bool? web,
    TargetPlatform? platform,
    StoragePathProvider? linuxSupportPath,
  }) async {
    final isWeb = web ?? kIsWeb;
    final currentPlatform = platform ?? defaultTargetPlatform;
    if (isWeb || currentPlatform != TargetPlatform.linux) return null;

    final pathProvider =
        linuxSupportPath ??
        () async => (await getApplicationSupportDirectory()).path;
    return pathProvider();
  }
}
