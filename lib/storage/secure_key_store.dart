import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SecureKeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class const UnavailableSecureKeyStore() implements SecureKeyStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) =>
      Future.error(UnsupportedError('System secure storage is unavailable.'));

  @override
  Future<void> delete(String key) async {}
}

class PlatformSecureKeyStore({
  FlutterSecureStorage? storage,
  final bool allowUnavailablePlatform = false,
}) implements SecureKeyStore {
  final FlutterSecureStorage _storage =
      storage ??
      const FlutterSecureStorage(
        mOptions: MacOsOptions(usesDataProtectionKeychain: true),
      );

  static bool get isAvailable =>
      kIsWeb || defaultTargetPlatform != TargetPlatform.macOS;

  void _requireAvailable() {
    if (!allowUnavailablePlatform && !isAvailable) {
      throw UnsupportedError('System secure storage is disabled on macOS.');
    }
  }

  @override
  Future<String?> read(String key) {
    _requireAvailable();
    return _storage.read(key: key);
  }

  @override
  Future<void> write(String key, String value) {
    _requireAvailable();
    return _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) {
    _requireAvailable();
    return _storage.delete(key: key);
  }
}

class KeyringSecureKeyStore(final SecureKeyStore _storage)
    implements SecureKeyStore {
  static const _keyringKey = 'sygnature_secure_keyring_v1';

  Map<String, String>? _values;
  Future<void> _pending = Future.value();

  @override
  Future<String?> read(String key) => _synchronized((values) async {
    if (values.containsKey(key)) return values[key];
    final legacyValue = await _storage.read(key);
    if (legacyValue == null) return null;
    final updatedValues = {...values, key: legacyValue};
    await _persist(updatedValues);
    _values = updatedValues;
    await _storage.delete(key);
    return legacyValue;
  });

  @override
  Future<void> write(String key, String value) => _synchronized((values) async {
    if (values[key] == value) return;
    final updatedValues = {...values, key: value};
    await _persist(updatedValues);
    _values = updatedValues;
    await _storage.delete(key);
  });

  @override
  Future<void> delete(String key) => _synchronized((values) async {
    if (values.containsKey(key)) {
      final updatedValues = {...values}..remove(key);
      await _persist(updatedValues);
      _values = updatedValues;
    }
    await _storage.delete(key);
  });

  Future<Map<String, String>> _load() async {
    final cached = _values;
    if (cached != null) return cached;
    final encoded = await _storage.read(_keyringKey);
    if (encoded == null) return _values = {};
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map ||
          decoded.keys.any((key) => key is! String) ||
          decoded.values.any((value) => value is! String)) {
        throw const FormatException();
      }
      return _values = decoded.cast<String, String>();
    } on Object {
      throw StateError('The secure keyring has an invalid format.');
    }
  }

  Future<void> _persist(Map<String, String> values) =>
      _storage.write(_keyringKey, jsonEncode(values));

  Future<T> _synchronized<T>(
    Future<T> Function(Map<String, String> values) operation,
  ) {
    final completer = Completer<T>();
    _pending = _pending.then((_) async {
      try {
        completer.complete(await operation(await _load()));
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
