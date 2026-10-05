import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';

import '../models/roast_signing_operation.dart';
import 'hive_storage_initializer.dart';
import 'wallet_repository.dart';

class RoastPersistence._(
  final Box<dynamic> _box,
  final SecureKeyStore _keyStore,
) {
  final Map<String, ClientStorageInterface> _clientStores = {};
  final Map<String, ServerPersistence> _serverStores = {};
  final Map<String, RoomPersistence> _roomStores = {};
}

abstract interface class RoastSigningOperationRepository {
  Future<List<RoastSigningOperation>> loadSigningOperations();
  Future<RoastSigningOperation?> getSigningOperation(String storageId);
  Future<void> putSigningOperation(RoastSigningOperation operation);
  Future<void> recordSigningResult(
    String storageId, {
    required String proposalHex,
    required List<String> signaturesHex,
  });
  Future<void> deleteSigningOperationsForSetup(String setupId);
}

class RoastPersistenceFactory implements RoastSigningOperationRepository {
  RoastPersistenceFactory({
    SecureKeyStore? secureKeyStore,
    Uint8List? cipherKey,
  }) : _keyStore =
           secureKeyStore ??
           (cipherKey == null
               ? PlatformSecureKeyStore()
               : const UnavailableSecureKeyStore()),
       _cipherKey = cipherKey;

  static const _boxName = 'sygnature_roast_private_v1';
  static const _cipherKeyName = 'sygnature_roast_hive_key_v1';
  static const _signingOperationsKey = 'wallet-signing-operations-v1';
  static const _serverStateStorageVersion = 1;

  final SecureKeyStore _keyStore;
  final Uint8List? _cipherKey;
  Future<RoastPersistence>? _opening;
  Future<void> _operationWrites = Future.value();

  Future<RoastPersistence> open() => _opening ??= _open();

  Future<RoastPersistence> _open() async {
    await HiveStorageInitializer.initialize(boxName: _boxName);
    var key = _cipherKey;
    if (key == null) {
      var encodedKey = await _keyStore.read(_cipherKeyName);
      if (encodedKey == null) {
        encodedKey = base64UrlEncode(Hive.generateSecureKey());
        await _keyStore.write(_cipherKeyName, encodedKey);
      }
      key = base64Url.decode(encodedKey);
    }
    if (key.length != 32) {
      throw StateError('Invalid encrypted ROAST storage key length.');
    }
    final box = await Hive.openBox<dynamic>(
      _boxName,
      encryptionCipher: HiveAesCipher(key),
    );
    return RoastPersistence._(box, _keyStore);
  }

  Future<T> _mutateOperations<T>(
    T Function(Map<String, RoastSigningOperation>) operation,
  ) {
    final completer = Completer<T>();
    _operationWrites = _operationWrites.then((_) async {
      try {
        final persistence = await open();
        final operations = _readOperations(persistence._box);
        final result = operation(operations);
        await persistence._box.put(_signingOperationsKey, {
          for (final entry in operations.entries)
            entry.key: entry.value.toJson(),
        });
        completer.complete(result);
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  static Map<String, RoastSigningOperation> _readOperations(Box box) {
    final raw = box.get(_signingOperationsKey);
    if (raw == null) return {};
    if (raw is! Map) {
      throw StateError('Invalid ROAST signing operations record.');
    }
    return {
      for (final entry in raw.entries)
        entry.key as String: RoastSigningOperation.fromJson(entry.value as Map),
    };
  }

  @override
  Future<List<RoastSigningOperation>> loadSigningOperations() async {
    await _operationWrites;
    return _readOperations((await open())._box).values.toList(growable: false);
  }

  @override
  Future<RoastSigningOperation?> getSigningOperation(String storageId) async {
    await _operationWrites;
    return _readOperations((await open())._box)[storageId];
  }

  @override
  Future<void> putSigningOperation(RoastSigningOperation operation) =>
      _mutateOperations((operations) {
        operations[operation.storageId] = operation;
      });

  @override
  Future<void> recordSigningResult(
    String storageId, {
    required String proposalHex,
    required List<String> signaturesHex,
  }) => _mutateOperations((operations) {
    final operation = operations[storageId];
    if (operation == null || operation.proposalHex != proposalHex) {
      throw StateError('The completed ROAST proposal is not persisted.');
    }
    operations[storageId] = operation.copyWith(
      signaturesHex: signaturesHex,
      clearError: true,
    );
  });

  @override
  Future<void> deleteSigningOperationsForSetup(String setupId) =>
      _mutateOperations(
        (operations) => operations.removeWhere(
          (_, operation) => operation.setupId == setupId,
        ),
      );

  Future<void> deleteSetupData(String setupId) async {
    await _operationWrites;
    final persistence = await open();
    await persistence._box.deleteAll([
      'client:$setupId',
      'server-v$_serverStateStorageVersion:$setupId',
      'rooms:$setupId',
    ]);
    await _keyStore.delete('sygnature_iroh_identity_$setupId');
    persistence._clientStores.remove(setupId);
    persistence._serverStores.remove(setupId);
    persistence._roomStores.remove(setupId);
  }
}

final class MemoryRoastSigningOperationRepository
    implements RoastSigningOperationRepository {
  final Map<String, RoastSigningOperation> _operations = {};

  @override
  Future<List<RoastSigningOperation>> loadSigningOperations() async =>
      _operations.values.toList(growable: false);

  @override
  Future<RoastSigningOperation?> getSigningOperation(String storageId) async =>
      _operations[storageId];

  @override
  Future<void> putSigningOperation(RoastSigningOperation operation) async {
    _operations[operation.storageId] = operation;
  }

  @override
  Future<void> recordSigningResult(
    String storageId, {
    required String proposalHex,
    required List<String> signaturesHex,
  }) async {
    final operation = _operations[storageId];
    if (operation == null || operation.proposalHex != proposalHex) {
      throw StateError('The completed ROAST proposal is not persisted.');
    }
    _operations[storageId] = operation.copyWith(
      signaturesHex: signaturesHex,
      clearError: true,
    );
  }

  @override
  Future<void> deleteSigningOperationsForSetup(String setupId) async {
    _operations.removeWhere((_, operation) => operation.setupId == setupId);
  }
}

extension RoastPersistenceAccess on RoastPersistence {
  ClientStorageInterface clientStorage(String setupId) =>
      _clientStores.putIfAbsent(
        setupId,
        () => _HiveRoastClientStorage(_box, 'client:$setupId'),
      );

  Future<SecretKey?> legacyIrohSecretKey(String setupId) async {
    final encoded = await _keyStore.read('sygnature_iroh_identity_$setupId');
    if (encoded == null) return null;
    final bytes = base64Url.decode(encoded);
    if (bytes.length != SecretKey.lengthBytes) {
      throw StateError('Invalid legacy Iroh identity length.');
    }
    return SecretKey.fromBytes(bytes);
  }

  ServerPersistence serverPersistence(String setupId) =>
      _serverStores.putIfAbsent(
        setupId,
        () => _HiveServerPersistence(
          _box,
          'server-v${RoastPersistenceFactory._serverStateStorageVersion}:'
          '$setupId',
        ),
      );

  RoomPersistence roomPersistence(String setupId) => _roomStores.putIfAbsent(
    setupId,
    () => _HiveRoomPersistence(_box, 'rooms:$setupId'),
  );
}

final class _HiveServerPersistence(
  final Box<dynamic> _box,
  final String _storageKey,
) implements ServerPersistence {
  Future<void> _pendingWrite = Future.value();

  Map<String, String> _read() {
    final raw = _box.get(_storageKey);
    if (raw == null) return {};
    if (raw is! Map) throw StateError('Invalid ROAST server storage record.');
    return Map<String, String>.from(raw);
  }

  @override
  Future<ServerStateSnapshot?> load(String groupId) async {
    await _pendingWrite;
    final encoded = _read()[groupId];
    return encoded == null
        ? null
        : ServerStateSnapshot.fromBytes(base64Url.decode(encoded));
  }

  @override
  Future<void> write(String groupId, ServerStateSnapshot state) {
    final completer = Completer<void>();
    _pendingWrite = _pendingWrite.then((_) async {
      try {
        final records = _read();
        records[groupId] = base64UrlEncode(state.toBytes());
        await _box.put(_storageKey, records);
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

final class _HiveRoomPersistence(
  final Box<dynamic> _box,
  final String _storageKey,
) implements RoomPersistence {
  Future<void> _pendingWrite = Future.value();

  Map<String, Uint8List> _read() {
    final raw = _box.get(_storageKey);
    if (raw == null) return {};
    if (raw is! Map) throw StateError('Invalid ROAST room storage record.');
    return {
      for (final entry in raw.entries)
        entry.key as String: base64Url.decode(entry.value as String),
    };
  }

  @override
  Future<Map<String, Uint8List>> loadAll() async {
    await _pendingWrite;
    return _read();
  }

  @override
  Future<void> write(String roomId, Uint8List state) {
    final completer = Completer<void>();
    _pendingWrite = _pendingWrite.then((_) async {
      try {
        final records = _read();
        records[roomId] = Uint8List.fromList(state);
        await _box.put(_storageKey, {
          for (final entry in records.entries)
            entry.key: base64UrlEncode(entry.value),
        });
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
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
  Future<ClientStorageSnapshot> loadState() async {
    await _pendingWrite;
    final data = await _read();
    final nonces = <SignaturesRequestId, SignaturesNonces>{};
    for (final entry in (data['nonces'] as Map).entries) {
      final value = Map<String, dynamic>.from(entry.value as Map);
      final expiry = Expiry.fromTime(DateTime.parse(value['expiry'] as String));
      if (expiry.isExpired) continue;
      nonces[SignaturesRequestId.fromBytes(
        _decode(entry.key as String),
      )] = SignaturesNonces({
        for (final item in (value['values'] as Map).entries)
          int.parse(item.key as String): SigningNonces.fromBytes(
            _decode(item.value as String),
          ),
      }, expiry);
    }
    final prepared = <SignaturesRequestId, PreparedSignaturesOperation>{};
    for (final encoded in (data['prepared'] as Map).values.cast<String>()) {
      final operation = PreparedSignaturesOperation.fromBytes(_decode(encoded));
      if (!operation.expiry.isExpired) prepared[operation.id] = operation;
    }
    final rejected = <SignaturesRequestId, FinalExpirable>{};
    for (final entry in (data['rejected'] as Map).entries) {
      final expiry = Expiry.fromTime(DateTime.parse(entry.value as String));
      if (!expiry.isExpired) {
        rejected[SignaturesRequestId.fromBytes(_decode(entry.key as String))] =
            FinalExpirable(expiry);
      }
    }
    return ClientStorageSnapshot(
      keys: (data['keys'] as List).cast<String>().map(
        (value) => FrostKeyWithDetails.fromBytes(_decode(value)),
      ),
      sigNonces: nonces,
      preparedOperations: prepared,
      rejectedRequests: rejected,
    );
  }

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
}
