import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sygnature_ng/storage/secure_key_store.dart';

const _systemKey = 'sygnature_integration_test_system_storage_v1';
const _firstValue = 'integration-test-value-1';
const _secondValue = 'integration-test-value-2';
const _runDeviceAuthenticationTests = bool.fromEnvironment(
  'RUN_DEVICE_AUTH_STORAGE_TESTS',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('system secure storage supports the complete lifecycle', (
    _,
  ) async {
    expect(
      defaultTargetPlatform,
      anyOf(TargetPlatform.android, TargetPlatform.iOS),
      reason: 'Run this integration test on an Android or iOS device.',
    );

    final store = PlatformSecureKeyStore();
    var deleted = false;
    addTearDown(() async {
      if (!deleted) await store.delete(_systemKey);
    });

    await store.delete(_systemKey);
    expect(await store.read(_systemKey), isNull);

    await store.write(_systemKey, _firstValue);
    expect(await store.read(_systemKey), _firstValue);
    expect(await PlatformSecureKeyStore().read(_systemKey), _firstValue);

    await store.write(_systemKey, _secondValue);
    expect(await store.read(_systemKey), _secondValue);

    await store.delete(_systemKey);
    deleted = true;
    expect(await store.read(_systemKey), isNull);
  });

  testWidgets(
    'Android device-authenticated storage supports write, read and delete',
    (_) async {
      final store = PlatformSecureKeyStore.device();
      final key =
          'sygnature_integration_test_device_storage_'
          '${DateTime.now().microsecondsSinceEpoch}';
      var written = false;
      var deleted = false;
      addTearDown(() async {
        if (written && !deleted) await store.delete(key);
      });

      debugPrint('Approve the device authentication prompt to write.');
      await store.write(key, _firstValue);
      written = true;

      debugPrint('Approve the device authentication prompt to read.');
      expect(await store.read(key), _firstValue);

      debugPrint('Approve the device authentication prompt to delete.');
      await store.delete(key);
      deleted = true;
    },
    skip:
        !_runDeviceAuthenticationTests ||
        defaultTargetPlatform != TargetPlatform.android,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
