import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'hive_storage_initializer.dart';
import 'secure_key_store.dart';

enum VaultProtectionMode { system, device }

enum VaultOpenFailure implements Exception {
  authenticationCancelled,
  secureStorageUnavailable,
  keyMissing,
  keyInvalid,
  vaultCorrupt,
  unsupportedSchema;

  bool get canRetry =>
      this == authenticationCancelled || this == secureStorageUnavailable;
}

class const VaultProtectionConfig({required final VaultProtectionMode mode}) {
  static const _modeKey = 'mode';

  factory VaultProtectionConfig.fromJson(Map<dynamic, dynamic> json) {
    final modeName = json[_modeKey];
    final mode = VaultProtectionMode.values
        .where((value) => value.name == modeName)
        .firstOrNull;
    if (mode == null) throw VaultOpenFailure.vaultCorrupt;
    return VaultProtectionConfig(mode: mode);
  }

  Map<String, Object?> toJson() => {_modeKey: mode.name};
}

class const VaultKeyMaterial({
  required final Uint8List walletKey,
  required final Uint8List roastKey,
});

class VaultProtectionStore(final Box<dynamic> _box) {
  static const _boxName = 'sygnature_bootstrap_v1';
  static const _configKey = 'vault_protection';

  static Future<VaultProtectionStore> open() async {
    try {
      await HiveStorageInitializer.initialize(boxName: _boxName);
      return VaultProtectionStore(await Hive.openBox<dynamic>(_boxName));
    } on HiveError {
      throw VaultOpenFailure.vaultCorrupt;
    } on Object {
      throw VaultOpenFailure.secureStorageUnavailable;
    }
  }

  VaultProtectionConfig? get config {
    final raw = _box.get(_configKey);
    if (raw == null) return null;
    if (raw is! Map) {
      throw VaultOpenFailure.vaultCorrupt;
    }
    return VaultProtectionConfig.fromJson(raw);
  }

  Future<void> configureSystem() => _box.put(
    _configKey,
    const VaultProtectionConfig(mode: VaultProtectionMode.system).toJson(),
  );

  Future<void> configureDevice() => _box.put(
    _configKey,
    const VaultProtectionConfig(mode: VaultProtectionMode.device).toJson(),
  );
}

bool deviceVaultAvailable({bool? web, TargetPlatform? platform}) =>
    !(web ?? kIsWeb) &&
    (platform ?? defaultTargetPlatform) == TargetPlatform.android;

/// Reads one authenticated root key before either encrypted box is opened.
/// Derived keys stay in memory for this process; background work needs no prompt.
const _deviceVaultKeyName = 'sygnature_device_vault_key_v1';

Future<VaultKeyMaterial> createDeviceVaultKeys({
  required SecureKeyStore keyStore,
}) async {
  await _deviceKeyStoreOperation(
    () => keyStore.write(
      _deviceVaultKeyName,
      base64UrlEncode(Hive.generateSecureKey()),
    ),
  );
  // Verify the newly stored key through the authenticated read path. This is
  // deliberately called only when onboarding first persists the mnemonic.
  return loadDeviceVaultKeys(keyStore: keyStore);
}

Future<VaultKeyMaterial> loadDeviceVaultKeys({
  required SecureKeyStore keyStore,
}) async {
  final encoded = await _deviceKeyStoreOperation(
    () => keyStore.read(_deviceVaultKeyName),
  );
  if (encoded == null) {
    throw VaultOpenFailure.keyMissing;
  }
  try {
    return await _expandRootKey(base64Url.decode(encoded));
  } on VaultOpenFailure {
    rethrow;
  } on Object {
    throw VaultOpenFailure.keyInvalid;
  }
}

Future<VaultKeyMaterial> _expandRootKey(Uint8List rootKey) async {
  if (rootKey.length != 32) throw VaultOpenFailure.keyInvalid;
  final secretKey = SecretKeyData(rootKey, overwriteWhenDestroyed: true);
  try {
    return await _expandVaultKeyMaterial(secretKey);
  } finally {
    secretKey.destroy();
  }
}

Future<T> _deviceKeyStoreOperation<T>(Future<T> Function() operation) async {
  try {
    return await operation();
  } on PlatformException catch (error) {
    final cancelled = RegExp(r'Biometric authentication error \[(5|10|13)\]')
        .hasMatch(error.message ?? '');
    throw cancelled
        ? VaultOpenFailure.authenticationCancelled
        : VaultOpenFailure.secureStorageUnavailable;
  } on VaultOpenFailure {
    rethrow;
  } on Object {
    throw VaultOpenFailure.secureStorageUnavailable;
  }
}

bool desktopVaultAvailable({bool? web, TargetPlatform? platform}) =>
    !(web ?? kIsWeb) &&
    switch (platform ?? defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.windows ||
      TargetPlatform.macOS => true,
      _ => false,
    };

Future<VaultKeyMaterial> _expandVaultKeyMaterial(SecretKey rootKey) async =>
    VaultKeyMaterial(
      walletKey: await _deriveDomainKey(rootKey, 'wallet-v1'),
      roastKey: await _deriveDomainKey(rootKey, 'roast-v1'),
    );

Future<Uint8List> _deriveDomainKey(SecretKey rootKey, String domain) async {
  final mac = await Hmac.sha256().calculateMac(
    utf8.encode('sygnature:$domain'),
    secretKey: rootKey,
  );
  return Uint8List.fromList(mac.bytes);
}
