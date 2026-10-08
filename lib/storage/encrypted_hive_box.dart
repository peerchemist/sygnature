import 'dart:convert';
import 'dart:typed_data';

import 'package:hive_ce_flutter/hive_flutter.dart';

import 'hive_storage_initializer.dart';
import 'secure_key_store.dart';

/// Opens encrypted storage using either an explicit key or system secure storage.
class const EncryptedHiveBox({
  required final String name,
  required final String cipherKeyName,
  required final String invalidKeyMessage,
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
    final encodedKey = await keyStore.read(cipherKeyName);
    if (encodedKey == null) return null;
    return _open(base64Url.decode(encodedKey));
  }

  Future<Uint8List> _loadOrCreateKey(SecureKeyStore keyStore) async {
    var encodedKey = await keyStore.read(cipherKeyName);
    if (encodedKey == null) {
      encodedKey = base64UrlEncode(Hive.generateSecureKey());
      await keyStore.write(cipherKeyName, encodedKey);
    }
    return base64Url.decode(encodedKey);
  }

  Future<Box<dynamic>> _open(Uint8List key) {
    if (key.length != 32) throw StateError(invalidKeyMessage);
    return Hive.openBox<dynamic>(name, encryptionCipher: HiveAesCipher(key));
  }
}
