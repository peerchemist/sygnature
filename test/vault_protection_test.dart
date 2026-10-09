import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/storage/secure_key_store.dart';
import 'package:sygnature_ng/storage/vault_protection.dart';

void main() {
  test('uses device protection only on Android', () {
    expect(
      deviceVaultAvailable(web: false, platform: TargetPlatform.android),
      isTrue,
    );
    for (final platform in [
      TargetPlatform.iOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    ]) {
      expect(deviceVaultAvailable(web: false, platform: platform), isFalse);
    }
  });

  test('trusts the system keyring on every desktop platform', () {
    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    ]) {
      expect(desktopVaultAvailable(web: false, platform: platform), isTrue);
    }
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      expect(desktopVaultAvailable(web: false, platform: platform), isFalse);
    }
    expect(
      desktopVaultAvailable(web: true, platform: TargetPlatform.linux),
      isFalse,
    );
  });

  test(
    'derives stable domain-separated keys from the device root key',
    () async {
      final rootKey = List<int>.generate(32, (index) => index);
      final store = _MemorySecureKeyStore(base64UrlEncode(rootKey));

      final first = await loadDeviceVaultKeys(keyStore: store);
      final second = await loadDeviceVaultKeys(keyStore: store);

      expect(first.walletKey, orderedEquals(second.walletKey));
      expect(first.roastKey, orderedEquals(second.roastKey));
      expect(first.walletKey, isNot(orderedEquals(first.roastKey)));
      expect(first.walletKey, hasLength(32));
      expect(first.roastKey, hasLength(32));
    },
  );
}

class _MemorySecureKeyStore(String value) implements SecureKeyStore {
  String? _value = value;

  @override
  Future<String?> read(String key) async => _value;

  @override
  Future<void> write(String key, String value) async => _value = value;

  @override
  Future<void> delete(String key) async => _value = null;
}
