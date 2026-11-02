import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart' hide SecretKey;
import 'package:coinlib/coinlib.dart' as cl;
import 'package:sygnature_ng/models/wallet_account.dart';
import 'package:sygnature_ng/services/peercoin_network_service.dart';
import 'package:sygnature_ng/services/wallet_key_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:sygnature_ng/models/wallet_vault.dart';
import 'package:sygnature_ng/storage/hive_storage_initializer.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';
import 'package:sygnature_ng/storage/vault_protection.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';

const _walletBox = 'sygnature_private_v1';
const _roastBox = 'sygnature_roast_private_v1';
const _walletKeyName = 'sygnature_hive_key_v1';
const _roastKeyName = 'sygnature_roast_hive_key_v1';
const _vault = WalletVault(
  rootSeedHex:
      '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
      '202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f',
  accounts: [],
  nextAccountIndex: 0,
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sygnature-encrypted-');
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (call) async => directory.path,
    );
  });

  tearDown(() async {
    await Hive.close();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
    debugDefaultTargetPlatformOverride = null;
    await directory.delete(recursive: true);
  });

  test(
    'generates separate keys and reuses them when reopening both stores',
    () async {
      final keys = _MemorySecureKeyStore();
      final wallet = await HiveWalletRepository.open(secureKeyStore: keys);
      final factory = RoastPersistenceFactory(secureKeyStore: keys);
      final opening = factory.open();
      expect(factory.open(), same(opening));
      final roast = await opening;
      final roomState = Uint8List.fromList(
        utf8.encode('private ROAST room state'),
      );
      final dkgState = Uint8List.fromList(
        utf8.encode('private resumable DKG state'),
      );
      await wallet.save(_vault);
      await roast.roomPersistence('setup').write('room', roomState);
      await roast.dkgSecretStorage('setup').write('wallet-key', dkgState);
      final savedKeys = Map.of(keys.values);
      expect(savedKeys.keys, unorderedEquals([_walletKeyName, _roastKeyName]));
      expect(base64Url.decode(savedKeys[_walletKeyName]!), hasLength(32));
      expect(base64Url.decode(savedKeys[_roastKeyName]!), hasLength(32));
      expect(savedKeys[_walletKeyName], isNot(savedKeys[_roastKeyName]));
      await Hive.close();

      final walletBytes = await File('${directory.path}/$_walletBox.hive')
          .readAsBytes();
      final roastBytes = await File('${directory.path}/$_roastBox.hive')
          .readAsBytes();
      expect(latin1.decode(walletBytes), isNot(contains(_vault.rootSeedHex)));
      expect(
        latin1.decode(roastBytes),
        isNot(contains(base64UrlEncode(roomState))),
      );
      expect(
        latin1.decode(roastBytes),
        isNot(contains(base64UrlEncode(dkgState))),
      );
      final restoredWallet = await HiveWalletRepository.openExisting(
        secureKeyStore: keys,
      );
      final restoredRoast = await RoastPersistenceFactory(secureKeyStore: keys)
          .open();
      expect((await restoredWallet!.load())!.toJson(), _vault.toJson());
      expect(
        (await restoredRoast.roomPersistence('setup').loadAll())['room'],
        roomState,
      );
      expect(
        (await restoredRoast.dkgSecretStorage('setup').loadAll())['wallet-key'],
        dkgState,
      );
      expect(keys.values, savedKeys);
      expect(keys.writes, 2);
    },
  );

  test(
    'opens existing account-key records without migration or key reset',
    () async {
      await cl.loadCoinlib();
      final keys = _MemorySecureKeyStore();
      final service = CoinlibWalletKeyService();
      final seed = cl.hexToBytes(_vault.rootSeedHex);
      final material = service.deriveAccount(
        network: PeercoinNetworks.mainnet,
        rootSeed: seed,
        accountIndex: 0,
      );
      final oldKey = service.deriveSpendKey(
        network: PeercoinNetworks.mainnet,
        rootSeed: seed,
        accountIndex: 0,
        addressIndex: 0,
      );
      addTearDown(() {
        seed.fillRange(0, seed.length, 0);
        oldKey.fillRange(0, oldKey.length, 0);
      });
      final account = WalletAccount(
        id: 'personal',
        name: 'Existing wallet',
        accountIndex: 0,
        blockchainId: 'peercoin',
        networkId: 'mainnet',
        derivationState: WalletDerivationState.ready,
        createdAt: DateTime.utc(2026),
        address: material.address,
        derivationPath: material.derivationPath,
        addressPathPrefix: "m/86'/6'/0'/0/",
        highestAllocatedAddressIndex: 4,
      );
      final vault = _vault.copyWith(accounts: [account], nextAccountIndex: 1);
      final oldRecord = {
        ...vault.toJson(),
        'schemaVersion': 3,
        'accounts': [
          {...account.toJson(), 'privateKeyHex': cl.bytesToHex(oldKey)},
        ],
      };
      await HiveWalletRepository.open(secureKeyStore: keys);
      await Hive.box<dynamic>(_walletBox).put('wallet_vault', oldRecord);
      await Hive.close();
      final savedKeys = Map.of(keys.values);

      final repository = (await HiveWalletRepository.openExisting(
        secureKeyStore: keys,
      ))!;
      final restored = (await repository.load())!;
      expect(restored.toJson(), vault.toJson());
      final raw = Hive.box<dynamic>(_walletBox).get('wallet_vault') as Map;
      expect((raw['accounts'] as List).single, contains('privateKeyHex'));
      final signingKey = service.deriveSpendKey(
        network: PeercoinNetworks.mainnet,
        rootSeed: seed,
        accountIndex: restored.accounts.single.accountIndex,
        addressIndex: 0,
      );
      expect(signingKey, oldKey);
      signingKey.fillRange(0, signingKey.length, 0);

      await repository.save(restored);
      final updated = Hive.box<dynamic>(_walletBox).get('wallet_vault') as Map;
      expect(updated['schemaVersion'], 3);
      expect(
        (updated['accounts'] as List).single,
        isNot(contains('privateKeyHex')),
      );
      await Hive.close();
      final reopened = (await HiveWalletRepository.openExisting(
        secureKeyStore: keys,
      ))!;
      expect((await reopened.load())!.toJson(), vault.toJson());
      expect(keys.values, savedKeys);
      expect(keys.writes, 1);
    },
  );

  test(
    'atomically replaces and deletes encrypted DKG recovery state',
    () async {
      final storage = (await RoastPersistenceFactory(
        cipherKey: Uint8List(32),
      ).open()).dkgSecretStorage('setup');
      await storage.write('wallet-key', Uint8List.fromList([1, 2, 3]));
      await storage.write('wallet-key', Uint8List.fromList([4, 5, 6]));

      expect(await storage.loadAll(), {
        'wallet-key': Uint8List.fromList([4, 5, 6]),
      });

      await storage.delete('wallet-key');
      expect(await storage.loadAll(), isEmpty);
    },
  );

  test('authenticates encrypted DKG recovery state and context', () async {
    final rootKey = Uint8List.fromList(List.filled(32, 7));
    final persistence = await RoastPersistenceFactory(cipherKey: rootKey)
        .open();
    final storage = persistence.dkgSecretStorage('setup');
    final state = Uint8List.fromList(utf8.encode('opaque Frosty DKG state'));
    await storage.write('wallet-key', state);

    final box = Hive.box<dynamic>(_roastBox);
    final records = Map<String, dynamic>.from(
      box.get('dkg-secrets:setup') as Map,
    );
    final record = Map<String, dynamic>.from(records['wallet-key'] as Map);
    expect(record['version'], 1);
    expect(record['nonce'], isA<Uint8List>().having((v) => v.length, '', 24));
    expect(record['mac'], isA<Uint8List>().having((v) => v.length, '', 16));
    expect(record['ciphertext'], isNot(orderedEquals(state)));
    await expectLater(
      Xchacha20.poly1305Aead().decrypt(
        SecretBox(
          record['ciphertext'] as Uint8List,
          nonce: record['nonce'] as Uint8List,
          mac: Mac(record['mac'] as Uint8List),
        ),
        secretKey: SecretKeyData(rootKey),
        aad: utf8.encode(
          jsonEncode(['sygnature:dkg-recovery', 1, 'setup', 'wallet-key']),
        ),
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );

    await box.put('dkg-secrets:setup', {'other-key': record});
    await expectLater(
      storage.loadAll(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'DKG recovery state authentication failed.',
        ),
      ),
    );

    await box.put('dkg-secrets:other-setup', {'wallet-key': record});
    await expectLater(
      persistence.dkgSecretStorage('other-setup').loadAll(),
      throwsA(isA<StateError>()),
    );
  });

  test('rejects tampered DKG recovery ciphertext', () async {
    final persistence = await RoastPersistenceFactory(
      cipherKey: Uint8List.fromList(List.filled(32, 8)),
    ).open();
    final storage = persistence.dkgSecretStorage('setup');
    await storage.write('wallet-key', Uint8List.fromList([1, 2, 3]));

    final box = Hive.box<dynamic>(_roastBox);
    final records = Map<String, dynamic>.from(
      box.get('dkg-secrets:setup') as Map,
    );
    final record = Map<String, dynamic>.from(records['wallet-key'] as Map);
    final ciphertext = Uint8List.fromList(record['ciphertext'] as Uint8List);
    ciphertext[0] ^= 1;
    record['ciphertext'] = ciphertext;
    await box.put('dkg-secrets:setup', {'wallet-key': record});

    await expectLater(storage.loadAll(), throwsA(isA<StateError>()));
  });

  test(
    'opens existing wallet and ROAST data with the original keys and format',
    () async {
      final walletKey = Uint8List.fromList(List.filled(32, 1));
      final roastKey = Uint8List.fromList(List.filled(32, 2));
      await HiveStorageInitializer.initialize();
      final walletBox = await Hive.openBox<dynamic>(
        _walletBox,
        encryptionCipher: HiveAesCipher(walletKey),
      );
      await walletBox.put('wallet_vault', _vault.toJson());
      final roastBox = await Hive.openBox<dynamic>(
        _roastBox,
        encryptionCipher: HiveAesCipher(roastKey),
      );
      await roastBox.put('rooms:setup', {
        'room': base64UrlEncode([3, 4, 5]),
      });
      await Hive.close();
      final keys = _MemorySecureKeyStore()
        ..values.addAll({
          _walletKeyName: base64UrlEncode(walletKey),
          _roastKeyName: base64UrlEncode(roastKey),
        });

      final wallet = await HiveWalletRepository.openExisting(
        secureKeyStore: keys,
      );
      final roast = await RoastPersistenceFactory(secureKeyStore: keys).open();
      expect((await wallet!.load())!.toJson(), _vault.toJson());
      expect((await roast.roomPersistence('setup').loadAll())['room'], [
        3,
        4,
        5,
      ]);
      expect(keys.writes, 0);
    },
  );

  test('opening a missing vault does not create a key or box', () async {
    final keys = _MemorySecureKeyStore()..failReads = true;
    expect(
      await HiveWalletRepository.openExisting(secureKeyStore: keys),
      isNull,
    );
    expect(await HiveWalletRepository.boxExists(), isFalse);
    expect(keys.reads, 0);
    expect(keys.writes, 0);
  });

  test(
    'opening an existing vault without its key preserves its data',
    () async {
      final key = Uint8List.fromList(List.filled(32, 3));
      final wallet = await HiveWalletRepository.openWithCipherKey(key);
      await wallet.save(_vault);
      await Hive.close();
      final keys = _MemorySecureKeyStore();

      expect(
        await HiveWalletRepository.openExisting(secureKeyStore: keys),
        isNull,
      );
      expect(await HiveWalletRepository.boxExists(), isTrue);
      expect(keys.writes, 0);
      keys.values[_walletKeyName] = base64UrlEncode(key);
      final restored = await HiveWalletRepository.openExisting(
        secureKeyStore: keys,
      );
      expect((await restored!.load())!.toJson(), _vault.toJson());
    },
  );

  test('distinguishes unsupported and corrupt wallet records', () async {
    final wallet = await HiveWalletRepository.openWithCipherKey(Uint8List(32));
    final box = Hive.box<dynamic>(_walletBox);

    await box.put('wallet_vault', {
      'schemaVersion': WalletVault.schemaVersion + 1,
    });
    await expectLater(
      wallet.load(),
      throwsA(VaultOpenFailure.unsupportedSchema),
    );

    await box.put('wallet_vault', {'schemaVersion': WalletVault.schemaVersion});
    await expectLater(wallet.load(), throwsA(VaultOpenFailure.vaultCorrupt));
  });

  test('reports encrypted data opened with the wrong key as corrupt', () async {
    final wallet = await HiveWalletRepository.openWithCipherKey(Uint8List(32));
    await wallet.save(_vault);
    await Hive.close();

    await expectLater(
      HiveWalletRepository.openWithCipherKey(
        Uint8List.fromList(List.filled(32, 1)),
      ),
      throwsA(VaultOpenFailure.vaultCorrupt),
    );
  });

  test('prepared operations survive restart and a failed mutation does not block later writes', () async {
    final key = Uint8List(32);
    var p = await RoastPersistenceFactory(cipherKey: key).open();
    var client = p.clientStorage('setup');
    final store = Hive.box<dynamic>(_roastBox);
    await client.pruneCancelledSignaturesRequests();
    expect(store.keys, isEmpty);
    final id = SignaturesRequestId.fromBytes(Uint8List(16));
    final expiry = Expiry.fromTime(
      DateTime.now().add(const Duration(hours: 1)),
    );
    final nonces = SignaturesNonces({}, expiry);
    await expectLater(
      client.addSignaturesNonces(id, nonces, -1),
      throwsStateError,
    );
    final operation = PreparedSignaturesOperation(
      id: id,
      kind: PreparedSignaturesOperationKind.replies,
      payloads: [],
      transcripts: [],
      nextNonces: nonces,
    );
    await client.prepareSignaturesOperation(operation, 0);
    await Hive.close();
    p = await RoastPersistenceFactory(cipherKey: key).open();
    client = p.clientStorage('setup');
    expect((await client.loadState()).preparedOperations.keys, [id]);
    await client.completeSignaturesOperation(id);
    final snapshot = await client.loadState();
    expect(snapshot.preparedOperations, isEmpty);
    expect(snapshot.sigNonces.keys, [id]);
  });

  test('ROAST open retries after secure storage becomes available', () async {
    final keys = _MemorySecureKeyStore()..failReads = true;
    final factory = RoastPersistenceFactory(secureKeyStore: keys);
    await expectLater(
      factory.open(),
      throwsA(VaultOpenFailure.secureStorageUnavailable),
    );
    keys.failReads = false;
    await factory.open();
    expect(keys.reads, 2);
  });

  test('concurrent first opens generate only one encryption key', () async {
    final keys = _MemorySecureKeyStore();
    await Future.wait(
      List.generate(4, (_) => HiveWalletRepository.open(secureKeyStore: keys)),
    );
    expect(keys.writes, 1);
    await Hive.close();
    await HiveWalletRepository.open(secureKeyStore: keys);
  });

  test(
    'corruption never truncates private storage or returns an older wallet',
    () async {
      final key = Uint8List(32);
      final wallet = await HiveWalletRepository.openWithCipherKey(key);
      await wallet.save(_vault);
      await wallet.save(_vault.copyWith(nextAccountIndex: 1));
      await Hive.close();
      final file = File('${directory.path}/$_walletBox.hive');
      final bytes = await file.readAsBytes();
      bytes[bytes.length - 1] ^= 1;
      await file.writeAsBytes(bytes, flush: true);
      await expectLater(
        HiveWalletRepository.openWithCipherKey(key),
        throwsA(VaultOpenFailure.vaultCorrupt),
      );
      expect(await file.readAsBytes(), bytes);
    },
  );

  test('setup deletion does not decrypt corrupted secrets', () async {
    final factory = RoastPersistenceFactory(cipherKey: Uint8List(32));
    final p = await factory.open();
    await p
        .dkgSecretStorage('setup')
        .write('secret', Uint8List.fromList([1, 2, 3]));
    final rawBox = Hive.box<dynamic>(_roastBox);
    final records = Map<String, dynamic>.from(
      rawBox.get('dkg-secrets:setup') as Map,
    );
    final record = Map<String, dynamic>.from(records['secret'] as Map);
    final bytes = Uint8List.fromList(record['mac'] as Uint8List);
    bytes[0] ^= 1;
    record['mac'] = bytes;
    await rawBox.put('dkg-secrets:setup', {'secret': record});
    await factory.deleteSetupData('setup');
    expect(rawBox.containsKey('dkg-secrets:setup'), isFalse);
  });

  test(
    'pruning removes expired signing state but preserves every live record',
    () async {
      final p = await RoastPersistenceFactory(cipherKey: Uint8List(32)).open();
      final store = Hive.box<dynamic>(_roastBox);
      final now = DateTime.now();
      final ids = [
        SignaturesRequestId.fromBytes(Uint8List(16)),
        SignaturesRequestId.fromBytes(Uint8List.fromList(List.filled(16, 1))),
      ];
      final expiries = [
        now.subtract(const Duration(hours: 1)),
        now.add(const Duration(hours: 1)),
      ];
      final data = <String, dynamic>{
        'keys': <String>[],
        'nonces': <String, dynamic>{},
        'prepared': <String, dynamic>{},
        'rejected': <String, dynamic>{},
        'cancelled': <String, dynamic>{},
      };
      for (var i = 0; i < 2; i++) {
        final id = base64UrlEncode(ids[i].toBytes());
        final expiry = Expiry.fromTime(expiries[i]);
        data['nonces'][id] = {
          'expiry': expiries[i].toUtc().toIso8601String(),
          'values': <String, dynamic>{},
        };
        data['prepared'][id] = base64UrlEncode(
          PreparedSignaturesOperation(
            id: ids[i],
            kind: PreparedSignaturesOperationKind.replies,
            payloads: [],
            transcripts: [],
            nextNonces: SignaturesNonces({}, expiry),
          ).toBytes(),
        );
        data['rejected'][id] = expiries[i].toUtc().toIso8601String();
        data['cancelled'][id] = expiries[i].toUtc().toIso8601String();
      }
      await store.put('client:setup', data);
      await p.clientStorage('setup').pruneCancelledSignaturesRequests();
      final pruned = store.get('client:setup') as Map;
      for (final field in ['nonces', 'prepared', 'rejected', 'cancelled']) {
        expect((pruned[field] as Map).keys, [
          base64UrlEncode(ids[1].toBytes()),
        ]);
        expect(
          pruned[field][base64UrlEncode(ids[1].toBytes())],
          data[field][base64UrlEncode(ids[1].toBytes())],
        );
      }
    },
  );

  for (final roast in [false, true]) {
    final name = roast ? 'ROAST' : 'wallet';
    final keyName = roast ? _roastKeyName : _walletKeyName;
    final boxName = roast ? _roastBox : _walletBox;
    Future<Object> open(_MemorySecureKeyStore keys) => roast
        ? RoastPersistenceFactory(secureKeyStore: keys).open()
        : HiveWalletRepository.open(secureKeyStore: keys);

    test('never replaces a missing key for existing $name data', () async {
      final keys = _MemorySecureKeyStore();
      await open(keys);
      await Hive.close();
      final file = File('${directory.path}/$boxName.hive');
      final before = await file.readAsBytes();
      final savedKey = keys.values.remove(keyName)!;
      final writes = keys.writes;

      await expectLater(open(keys), throwsA(VaultOpenFailure.keyMissing));
      expect(Hive.isBoxOpen(boxName), isFalse);
      expect(await file.readAsBytes(), before);
      expect(keys.writes, writes);
      expect(keys.values, isEmpty);

      keys.values[keyName] = savedKey;
      await open(keys);
      expect(Hive.isBoxOpen(boxName), isTrue);
    });

    for (final (description, encoded) in [
      ('malformed', 'invalid-base64!'),
      ('wrong-length', base64UrlEncode(Uint8List(31))),
    ]) {
      test('rejects $description $name keys without replacing them', () async {
        final keys = _MemorySecureKeyStore()..values[keyName] = encoded;
        await expectLater(open(keys), throwsA(VaultOpenFailure.keyInvalid));
        expect(keys.values[keyName], encoded);
        expect(keys.writes, 0);
        expect(Hive.isBoxOpen(boxName), isFalse);
      });
    }

    test('does not create a $name box if saving its key fails', () async {
      final keys = _MemorySecureKeyStore()..failWrites = true;
      await expectLater(
        open(keys),
        throwsA(VaultOpenFailure.secureStorageUnavailable),
      );
      expect(keys.values, isEmpty);
      expect(await Hive.boxExists(boxName), isFalse);
    });
  }
}

class _MemorySecureKeyStore implements SecureKeyStore {
  final Map<String, String> values = {};
  int reads = 0;
  int writes = 0;
  bool failReads = false;
  bool failWrites = false;

  @override
  Future<String?> read(String key) async {
    reads++;
    if (failReads) throw StateError('Secure storage unavailable.');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('Secure storage write failed.');
    writes++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}
