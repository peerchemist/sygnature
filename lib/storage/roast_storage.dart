import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';

import 'hive_storage_initializer.dart';
import 'wallet_repository.dart';

class RoastPersistence._(
  final Box<dynamic> _box,
  final SecureKeyStore _keyStore,
);

class RoastPersistenceFactory {
  RoastPersistenceFactory({SecureKeyStore? secureKeyStore})
    : _keyStore = secureKeyStore ?? PlatformSecureKeyStore();

  static const _boxName = 'sygnature_roast_private_v1';
  static const _cipherKeyName = 'sygnature_roast_hive_key_v1';

  final SecureKeyStore _keyStore;
  Future<RoastPersistence>? _opening;

  Future<RoastPersistence> open() => _opening ??= _open();

  Future<RoastPersistence> _open() async {
    await HiveStorageInitializer.initialize(boxName: _boxName);
    var encodedKey = await _keyStore.read(_cipherKeyName);
    if (encodedKey == null) {
      encodedKey = base64UrlEncode(Hive.generateSecureKey());
      await _keyStore.write(_cipherKeyName, encodedKey);
    }
    final key = base64Url.decode(encodedKey);
    if (key.length != 32) {
      throw StateError('Invalid encrypted ROAST storage key length.');
    }
    final box = await Hive.openBox<dynamic>(
      _boxName,
      encryptionCipher: HiveAesCipher(key),
    );
    return RoastPersistence._(box, _keyStore);
  }
}

extension RoastPersistenceAccess on RoastPersistence {
  ClientStorageInterface clientStorage(String setupId) =>
      _HiveRoastClientStorage(_box, 'client:$setupId');

  ServerIdentityStore serverIdentity(String setupId) =>
      _SecureServerIdentityStore(_keyStore, 'sygnature_iroh_identity_$setupId');
}

final class _SecureServerIdentityStore(
  final SecureKeyStore _keyStore,
  final String _key,
) implements ServerIdentityStore {
  @override
  Future<Uint8List?> read() async {
    final encoded = await _keyStore.read(_key);
    return encoded == null ? null : base64Url.decode(encoded);
  }

  @override
  Future<void> write(Uint8List secret) =>
      _keyStore.write(_key, base64UrlEncode(secret));
}

final class _HiveRoastClientStorage(
  final Box<dynamic> _box,
  final String _storageKey,
) implements ClientStorageInterface {
  Future<void> _pendingWrite = Future.value();

  Future<Map<String, dynamic>> _read() async {
    final raw = _box.get(_storageKey);
    if (raw == null) {
      return <String, dynamic>{
        'keys': <String>[],
        'nonces': <String, Object?>{},
        'prepared': <String, String>{},
        'rejected': <String, String>{},
      };
    }
    if (raw is! Map) throw StateError('Invalid ROAST client storage record.');
    return Map<String, dynamic>.from(raw);
  }

  Future<T> _mutate<T>(T Function(Map<String, dynamic>) operation) {
    final completer = Completer<T>();
    _pendingWrite = _pendingWrite.then((_) async {
      try {
        final data = await _read();
        final result = operation(data);
        await _box.put(_storageKey, data);
        completer.complete(result);
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  static String _id(SignaturesRequestId id) => base64UrlEncode(id.toBytes());
  static String _bytes(Uint8List bytes) => base64UrlEncode(bytes);
  static Uint8List _decode(String value) => base64Url.decode(value);

  @override
  Future<void> addOrReplaceFrostKey(FrostKeyWithDetails newKey) =>
      _mutate((data) {
        final keys = (data['keys'] as List).cast<String>();
        final next = [
          for (final encoded in keys)
            if (FrostKeyWithDetails.fromBytes(_decode(encoded)).groupKey !=
                newKey.groupKey)
              encoded,
          _bytes(newKey.toBytes()),
        ];
        data['keys'] = next;
      });

  @override
  Future<void> addSignaturesNonces(
    SignaturesRequestId id,
    SignaturesNonces nonces,
    int capacity,
  ) => _mutate((data) {
    final all = Map<String, dynamic>.from(data['nonces'] as Map);
    final key = _id(id);
    final existing = all[key] == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(all[key] as Map);
    final values = Map<String, dynamic>.from(
      (existing['values'] as Map?) ?? const {},
    );
    for (final entry in nonces.map.entries) {
      values['${entry.key}'] = _bytes(entry.value.toBytes());
    }
    all[key] = {
      'expiry': nonces.expiry.time.toUtc().toIso8601String(),
      'values': values,
    };
    data['nonces'] = all;
  });

  @override
  Future<void> prepareSignaturesOperation(
    PreparedSignaturesOperation operation,
    int capacity,
  ) => _mutate((data) {
    _putNonces(data, operation.id, operation.nextNonces);
    final prepared = Map<String, dynamic>.from(data['prepared'] as Map);
    prepared[_id(operation.id)] = _bytes(operation.toBytes());
    data['prepared'] = prepared;
  });

  static void _putNonces(
    Map<String, dynamic> data,
    SignaturesRequestId id,
    SignaturesNonces nonces,
  ) {
    final all = Map<String, dynamic>.from(data['nonces'] as Map);
    final key = _id(id);
    final existing = all[key] == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(all[key] as Map);
    final values = Map<String, dynamic>.from(
      (existing['values'] as Map?) ?? const {},
    );
    for (final entry in nonces.map.entries) {
      values['${entry.key}'] = _bytes(entry.value.toBytes());
    }
    all[key] = {
      'expiry': nonces.expiry.time.toUtc().toIso8601String(),
      'values': values,
    };
    data['nonces'] = all;
  }

  @override
  Future<void> completeSignaturesOperation(SignaturesRequestId id) =>
      _mutate((data) {
        final prepared = Map<String, dynamic>.from(data['prepared'] as Map);
        prepared.remove(_id(id));
        data['prepared'] = prepared;
      });

  @override
  Future<void> addRejectedSigsRequest(
    SignaturesRequestId id,
    FinalExpirable expirable,
  ) => _mutate((data) {
    final rejected = Map<String, dynamic>.from(data['rejected'] as Map);
    rejected[_id(id)] = expirable.expiry.time.toUtc().toIso8601String();
    data['rejected'] = rejected;
  });

  @override
  Future<void> removeRejectionOfSigsRequest(SignaturesRequestId id) =>
      _mutate((data) {
        final rejected = Map<String, dynamic>.from(data['rejected'] as Map);
        rejected.remove(_id(id));
        data['rejected'] = rejected;
      });

  @override
  Future<void> removeSigsRequest(SignaturesRequestId id) => _mutate((data) {
    final key = _id(id);
    for (final field in ['nonces', 'prepared', 'rejected']) {
      final values = Map<String, dynamic>.from(data[field] as Map);
      values.remove(key);
      data[field] = values;
    }
  });

  @override
  Future<Set<FrostKeyWithDetails>> loadKeys() async {
    final data = await _read();
    return (data['keys'] as List)
        .cast<String>()
        .map((value) => FrostKeyWithDetails.fromBytes(_decode(value)))
        .toSet();
  }

  @override
  Future<Map<SignaturesRequestId, SignaturesNonces>> loadSigNonces() async {
    final data = await _read();
    final all = Map<String, dynamic>.from(data['nonces'] as Map);
    final result = <SignaturesRequestId, SignaturesNonces>{};
    for (final entry in all.entries) {
      final value = Map<String, dynamic>.from(entry.value as Map);
      final expiry = Expiry.fromTime(DateTime.parse(value['expiry'] as String));
      if (expiry.isExpired) continue;
      final nonces = <int, SigningNonces>{};
      for (final item in (value['values'] as Map).entries) {
        nonces[int.parse(item.key as String)] = SigningNonces.fromBytes(
          _decode(item.value as String),
        );
      }
      result[SignaturesRequestId.fromBytes(_decode(entry.key))] =
          SignaturesNonces(nonces, expiry);
    }
    return result;
  }

  @override
  Future<Map<SignaturesRequestId, PreparedSignaturesOperation>>
  loadPreparedSignaturesOperations() async {
    final data = await _read();
    final result = <SignaturesRequestId, PreparedSignaturesOperation>{};
    for (final encoded in (data['prepared'] as Map).values.cast<String>()) {
      final operation = PreparedSignaturesOperation.fromBytes(_decode(encoded));
      if (!operation.expiry.isExpired) result[operation.id] = operation;
    }
    return result;
  }

  @override
  Future<Map<SignaturesRequestId, FinalExpirable>>
  loadRejectedSigsRequests() async {
    final data = await _read();
    final result = <SignaturesRequestId, FinalExpirable>{};
    for (final entry in (data['rejected'] as Map).entries) {
      final expiry = Expiry.fromTime(DateTime.parse(entry.value as String));
      if (!expiry.isExpired) {
        result[SignaturesRequestId.fromBytes(_decode(entry.key as String))] =
            FinalExpirable(expiry);
      }
    }
    return result;
  }
}
