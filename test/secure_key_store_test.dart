import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'passes the native no-authentication-UI value to macOS Keychain',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final calls = <MethodCall>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return call.method == 'read' ? 'cipher-key' : null;
      });

      final store = PlatformSecureKeyStore();
      expect(await store.read('wallet-key'), 'cipher-key');
      await store.write('wallet-key', 'cipher-key');
      for (final call in calls) {
        final options = (call.arguments as Map)['options'] as Map;
        expect(options['usesDataProtectionKeychain'], 'false');
        expect(options['authenticationUIBehavior'], 'u_AuthUIF');
        expect(options['accessControlFlags'], isNull);
      }
    },
  );

  test(
    'Android device and automatic storage use isolated namespaces',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final records = <String, String>{};
      final calls = <MethodCall>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        final args = call.arguments as Map;
        final options = args['options'] as Map;
        final id = '${options['storageNamespace']}:${args['key']}';
        if (call.method == 'write') records[id] = args['value'] as String;
        return call.method == 'read' ? records[id] : null;
      });

      final system = PlatformSecureKeyStore();
      final device = PlatformSecureKeyStore.device();
      await system.write('same-key', 'automatic');
      await device.write('same-key', 'authenticated');
      expect(await system.read('same-key'), 'automatic');
      expect(await device.read('same-key'), 'authenticated');
      for (final call in calls) {
        final options = (call.arguments as Map)['options'] as Map;
        expect(options['resetOnError'], 'false');
        final authenticated =
            options['storageNamespace'] == 'sygnature_device_vault_v1';
        expect(options['enforceBiometrics'], '$authenticated');
        expect(options['requireBiometricsPerOperation'], '$authenticated');
        if (authenticated) {
          expect(options['biometricType'], 'biometricOrDeviceCredential');
          expect(options['biometricPromptTitle'], 'Unlock Sygnature');
        }
      }
    },
  );

  test('consolidates legacy secrets into one secure keyring record', () async {
    final backingStore = _MemorySecureKeyStore({
      'wallet-key': 'wallet-secret',
      'roast-key': 'roast-secret',
      'iroh-key': 'iroh-secret',
    });
    final keyring = KeyringSecureKeyStore(backingStore);

    expect(await keyring.read('wallet-key'), 'wallet-secret');
    expect(await keyring.read('roast-key'), 'roast-secret');
    expect(await keyring.read('iroh-key'), 'iroh-secret');
    expect(backingStore.values.keys, ['sygnature_secure_keyring_v1']);
    expect(
      jsonDecode(backingStore.values.values.single),
      containsPair('wallet-key', 'wallet-secret'),
    );

    backingStore.readKeys.clear();
    final restored = KeyringSecureKeyStore(backingStore);
    expect(await restored.read('wallet-key'), 'wallet-secret');
    expect(await restored.read('roast-key'), 'roast-secret');
    expect(await restored.read('iroh-key'), 'iroh-secret');
    expect(backingStore.readKeys, ['sygnature_secure_keyring_v1']);
  });
}

class _MemorySecureKeyStore(final Map<String, String> values)
    implements SecureKeyStore {
  final List<String> readKeys = [];

  @override
  Future<String?> read(String key) async {
    readKeys.add(key);
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
