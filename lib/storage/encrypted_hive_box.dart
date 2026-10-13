import 'dart:convert';
import 'dart:typed_data';

import 'package:hive_ce_flutter/hive_flutter.dart';

import 'hive_storage_initializer.dart';
import 'secure_key_store.dart';
import 'vault_protection.dart';

/// Opens encrypted storage using either an explicit key or system secure storage.
class const EncryptedHiveBox({
  required final String name,
  required final String cipherKeyName,
}) {
  Future<Box<dynamic>> open({
    SecureKeyStore? keyStore,
    Uint8List? cipherKey,
  }) async {
    await HiveStorageInitializer.initialize(boxName: name);
    final key =
        cipherKey ??
        await _loadOrCreateKey(keyStore ?? PlatformSecureKeyStore());
    return _open(key);
  }

  Future<bool> exists() async {
    await HiveStorageInitializer.initialize(boxName: name);
    return Hive.boxExists(name);
  }

  Future<Box<dynamic>?> openExisting({required SecureKeyStore keyStore}) async {
    if (!await exists()) return null;
    final encodedKey = await _keyStoreOperation(
      () => keyStore.read(cipherKeyName),
    );
    if (encodedKey == null) return null;
    return _open(_decodeKey(encodedKey));
  }

  Future<Uint8List> _loadOrCreateKey(SecureKeyStore keyStore) async {
    var encodedKey = await _keyStoreOperation(
      () => keyStore.read(cipherKeyName),
    );
    if (encodedKey == null) {
      if (await Hive.boxExists(name)) {
        throw VaultOpenFailure.keyMissing;
      }
      encodedKey = base64UrlEncode(Hive.generateSecureKey());
      await _keyStoreOperation(
        () => keyStore.write(cipherKeyName, encodedKey!),
      );
    }
    return _decodeKey(encodedKey);
  }

  Future<T> _keyStoreOperation<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on FormatException {
      throw VaultOpenFailure.keyInvalid;
    } on VaultOpenFailure {
      rethrow;
    } on Object {
      throw VaultOpenFailure.secureStorageUnavailable;
    }
  }

  Uint8List _decodeKey(String encoded) {
    late final Uint8List key;
    try {
      key = base64Url.decode(encoded);
    } on Object {
      throw VaultOpenFailure.keyInvalid;
    }
    if (key.length != 32) throw VaultOpenFailure.keyInvalid;
    return key;
  }

  Future<Box<dynamic>> _open(Uint8List key) async {
    if (key.length != 32) {
      throw VaultOpenFailure.keyInvalid;
    }
    try {
      return await Hive.openBox<dynamic>(
        name,
        encryptionCipher: HiveAesCipher(key),
      );
    } on HiveError {
      throw VaultOpenFailure.vaultCorrupt;
    } on Object {
      throw VaultOpenFailure.secureStorageUnavailable;
    }
  }
}
