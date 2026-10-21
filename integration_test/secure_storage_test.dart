import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sygnature_ng/storage/secure_key_store.dart';

const _systemKey = 'sygnature_integration_test_system_storage_v1';
const _firstValue = 'integration-test-value-1';
const _secondValue = 'integration-test-value-2';
const _runRestartTests = bool.fromEnvironment('RUN_IOS_KEYCHAIN_RESTART_TESTS');
const _restartKey = 'sygnature_integration_test_restart_storage_v1';
const _runDeviceAuthenticationTests = bool.fromEnvironment(
  'RUN_DEVICE_AUTH_STORAGE_TESTS',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (_runRestartTests) {
    test('iOS Keychain survives process restarts', () async {
      expect(defaultTargetPlatform, TargetPlatform.iOS);
      final directory = await getApplicationSupportDirectory();
      final marker = File('${directory.path}/secure_storage_restart_test.pid');
      final previousState = await marker.exists()
          ? (await marker.readAsString()).split(':')
          : null;
      final phase = previousState?.first ?? 'write';
      expect(phase, isIn(['write', 'read', 'cleanup']));
      final store = PlatformSecureKeyStore();

      if (phase == 'write') {
        expect(await marker.exists(), isFalse);
        // Reset only this synthetic key so an interrupted sequence is rerunnable.
        await store.delete(_restartKey);
        expect(await store.read(_restartKey), isNull);
        await store.write(_restartKey, _firstValue);
        expect(await store.read(_restartKey), _firstValue);
        await marker.writeAsString('read:$pid', flush: true);
      } else {
        // The sandbox marker proves application data survived process exit;
        // a different PID proves this is a new process, not a new Dart object.
        expect(await marker.exists(), isTrue);
        final previousPid = int.parse(previousState!.last);
        expect(pid, isNot(previousPid));
        if (phase == 'read') {
          try {
            expect(await store.read(_restartKey), _firstValue);
          } finally {
            await store.delete(_restartKey);
          }
          expect(await PlatformSecureKeyStore().read(_restartKey), isNull);
          await marker.writeAsString('cleanup:$pid', flush: true);
        } else {
          expect(await store.read(_restartKey), isNull);
          expect(await store.read(_systemKey), isNull);
          await marker.delete();
        }
      }
      debugPrint('Keychain restart phase $phase passed (PID $pid).');
    });
    return;
  }

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
