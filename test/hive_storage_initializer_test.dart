import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sygnature_ng/storage/hive_storage_initializer.dart';
import 'package:sygnature_ng/storage/legacy_hive_migration.dart';

void main() {
  test('uses the application support path on Linux', () async {
    final resolved = await HiveStorageInitializer.resolveHomePath(
      web: false,
      platform: TargetPlatform.linux,
      linuxSupportPath: () async => '/xdg/data/sygnature',
    );

    expect(resolved, '/xdg/data/sygnature');
  });

  test('leaves non-Linux and web storage to Hive Flutter', () async {
    var providerCalled = false;
    Future<String> provider() async {
      providerCalled = true;
      return '/should/not/be/used';
    }

    expect(
      await HiveStorageInitializer.resolveHomePath(
        web: false,
        platform: TargetPlatform.android,
        linuxSupportPath: provider,
      ),
      isNull,
    );
    expect(
      await HiveStorageInitializer.resolveHomePath(
        web: true,
        platform: TargetPlatform.linux,
        linuxSupportPath: provider,
      ),
      isNull,
    );
    expect(providerCalled, isFalse);
  });

  test('copies a legacy Linux Hive box without deleting the source', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'sygnature-hive-migration-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final legacy = Directory(path.join(temporary.path, 'Documents'))
      ..createSync();
    final target = Directory(path.join(temporary.path, 'xdg-data'));
    final source = File(path.join(legacy.path, 'wallet.hive'))
      ..writeAsStringSync('encrypted-vault');

    await migrateLegacyHiveBox(
      boxName: 'wallet',
      legacyDirectory: legacy.path,
      targetDirectory: target.path,
    );

    expect(source.existsSync(), isTrue);
    expect(
      File(path.join(target.path, 'wallet.hive')).readAsStringSync(),
      'encrypted-vault',
    );
    expect(File(path.join(target.path, 'wallet.lock')).existsSync(), isFalse);
  });
}
