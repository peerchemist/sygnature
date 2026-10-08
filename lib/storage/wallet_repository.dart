import 'dart:typed_data';

import 'package:hive_ce_flutter/hive_flutter.dart';

import '../models/wallet_vault.dart';
import 'encrypted_hive_box.dart';
import 'secure_key_store.dart';

export 'secure_key_store.dart';

abstract interface class WalletRepository {
  Future<WalletVault?> load();
  Future<void> save(WalletVault vault);
  Future<void> delete();
}

class HiveWalletRepository._(final Box<dynamic> _box)
    implements WalletRepository {
  static const _storage = EncryptedHiveBox(
    name: 'sygnature_private_v1',
    cipherKeyName: 'sygnature_hive_key_v1',
    invalidKeyMessage: 'Invalid encrypted vault key length.',
  );
  static const _vaultKey = 'wallet_vault';

  static Future<HiveWalletRepository> open({
    SecureKeyStore? secureKeyStore,
  }) async =>
      HiveWalletRepository._(await _storage.open(keyStore: secureKeyStore));

  static Future<bool> boxExists() => _storage.exists();

  static Future<HiveWalletRepository?> openExisting({
    required SecureKeyStore secureKeyStore,
  }) async {
    final box = await _storage.openExisting(keyStore: secureKeyStore);
    return box == null ? null : HiveWalletRepository._(box);
  }

  static Future<HiveWalletRepository> openWithCipherKey(Uint8List key) async =>
      HiveWalletRepository._(await _storage.open(cipherKey: key));

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
