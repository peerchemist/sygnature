import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:pointycastle/export.dart';

import 'hive_storage_initializer.dart';
import 'secure_key_store.dart';

enum VaultProtectionMode { system, device }

class const VaultProtectionConfig({required final VaultProtectionMode mode}) {
  static const _modeKey = 'mode';

  factory VaultProtectionConfig.fromJson(Map<dynamic, dynamic> json) {
    final modeName = json[_modeKey];
    final mode = VaultProtectionMode.values
        .where((value) => value.name == modeName)
        .firstOrNull;
    if (mode == null) {
      throw StateError('The vault protection mode is invalid.');
    }
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
    await HiveStorageInitializer.initialize(boxName: _boxName);
    return VaultProtectionStore(await Hive.openBox<dynamic>(_boxName));
  }

  VaultProtectionConfig? get config {
    final raw = _box.get(_configKey);
    if (raw == null) return null;
    if (raw is! Map) {
      throw StateError('The vault protection settings are invalid.');
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
Future<VaultKeyMaterial> loadDeviceVaultKeys({
  required SecureKeyStore keyStore,
  bool create = false,
}) async {
  const keyName = 'sygnature_device_vault_key_v1';
  var encoded = await keyStore.read(keyName);
  if (encoded == null && create) {
    await keyStore.write(keyName, base64UrlEncode(Hive.generateSecureKey()));
    // Require an authenticated read even when provisioning a new vault.
    encoded = await keyStore.read(keyName);
  }
  if (encoded == null) {
    throw StateError('The device vault encryption key is unavailable.');
  }
  final rootKey = base64Url.decode(encoded);
  try {
    if (rootKey.length != 32) {
      throw StateError('Invalid device vault key length.');
    }
    return _expandVaultKeyMaterial(rootKey);
  } finally {
    rootKey.fillRange(0, rootKey.length, 0);
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

VaultKeyMaterial _expandVaultKeyMaterial(Uint8List rootKey) => VaultKeyMaterial(
  walletKey: _deriveDomainKey(rootKey, 'wallet-v1'),
  roastKey: _deriveDomainKey(rootKey, 'roast-v1'),
);

Uint8List _deriveDomainKey(Uint8List rootKey, String domain) {
  final hmac = HMac(SHA256Digest(), 64)..init(KeyParameter(rootKey));
  return hmac.process(Uint8List.fromList(utf8.encode('sygnature:$domain')));
}
