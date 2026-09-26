import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../models/wallet_vault.dart';
import 'hive_storage_initializer.dart';

abstract interface class WalletRepository {
  Future<WalletVault?> load();
  Future<void> save(WalletVault vault);
  Future<void> delete();
}

abstract interface class SecureKeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PlatformSecureKeyStore implements SecureKeyStore {
  PlatformSecureKeyStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: !kDebugMode),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class HiveWalletRepository implements WalletRepository {
  HiveWalletRepository._(this._box);

  static const _boxName = 'sygnature_private_v1';
  static const _vaultKey = 'wallet_vault';
  static const _cipherKeyName = 'sygnature_hive_key_v1';

  final Box<dynamic> _box;

  static Future<HiveWalletRepository> open({
    SecureKeyStore? secureKeyStore,
  }) async {
    await HiveStorageInitializer.initialize(boxName: _boxName);
    final keyStore = secureKeyStore ?? PlatformSecureKeyStore();
    var encodedKey = await keyStore.read(_cipherKeyName);
    if (encodedKey == null) {
      encodedKey = base64UrlEncode(Hive.generateSecureKey());
      await keyStore.write(_cipherKeyName, encodedKey);
    }
    final key = base64Url.decode(encodedKey);
    if (key.length != 32) {
      throw StateError('Invalid encrypted vault key length.');
    }
    final box = await Hive.openBox<dynamic>(
      _boxName,
      encryptionCipher: HiveAesCipher(key),
    );
    return HiveWalletRepository._(box);
  }

  @override
  Future<WalletVault?> load() async {
    final raw = _box.get(_vaultKey);
    if (raw == null) return null;
    if (raw is! Map) {
      throw StateError('Wallet vault has an invalid format.');
    }
    return WalletVault.fromJson(raw);
  }

  @override
  Future<void> save(WalletVault vault) => _box.put(_vaultKey, vault.toJson());

  @override
  Future<void> delete() => _box.delete(_vaultKey);
}

class MemoryWalletRepository implements WalletRepository {
  WalletVault? value;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<WalletVault?> load() async => value;

  @override
  Future<void> save(WalletVault vault) async => value = vault;
}
