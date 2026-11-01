import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/storage/hive_storage_initializer.dart';

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
}
