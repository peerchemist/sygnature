import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

typedef StoragePathProvider = Future<String> Function();

abstract final class HiveStorageInitializer {
  static Future<void> initialize() async {
    final homePath = await resolveHomePath();
    if (homePath == null) {
      await Hive.initFlutter();
      return;
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
