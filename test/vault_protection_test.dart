import 'dart:convert';

import 'package:flutter/services.dart';
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
      expect(
        base64UrlEncode(first.walletKey),
        'nuP2tgmGDZ3m8D1FpGzIRy9QT14IWsrcmuLVcdIxrgc=',
      );
      expect(
        base64UrlEncode(first.roastKey),
        '4bDwBm-g8H4Hop6xAYKw8nt9nbNr_SQR7PFJm7ByB8M=',
      );
    },
  );

  test('distinguishes missing and invalid device vault keys', () async {
    for (final (key, failure) in [
      (null, VaultOpenFailure.keyMissing),
      ('invalid-base64!', VaultOpenFailure.keyInvalid),
      (base64UrlEncode(List.filled(31, 0)), VaultOpenFailure.keyInvalid),
    ]) {
      await expectLater(
        loadDeviceVaultKeys(keyStore: _MemorySecureKeyStore(key)),
        throwsA(failure),
      );
    }
  });

  test(
    'distinguishes cancelled authentication from unavailable storage',
    () async {
      for (final (error, failure) in [
        (
          PlatformException(
            code: 'Exception encountered',
            message: 'Biometric authentication error [10]: cancelled',
          ),
          VaultOpenFailure.authenticationCancelled,
        ),
        (
          StateError('temporarily unavailable'),
          VaultOpenFailure.secureStorageUnavailable,
        ),
      ]) {
        await expectLater(
          loadDeviceVaultKeys(
            keyStore: _MemorySecureKeyStore(null, error: error),
          ),
          throwsA(failure),
        );
      }
    },
  );
}

class _MemorySecureKeyStore(String? value, {this.error})
    implements SecureKeyStore {
  String? _value = value;
  final Object? error;

  @override
  Future<String?> read(String key) async {
    if (error != null) throw error!;
    return _value;
  }

  @override
  Future<void> write(String key, String value) async => _value = value;

  @override
  Future<void> delete(String key) async => _value = null;
}
