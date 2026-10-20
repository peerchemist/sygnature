import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
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
  mnemonic: 'test recovery phrase for encrypted storage',
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
      expect(latin1.decode(walletBytes), isNot(contains(_vault.mnemonic!)));
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
      await HiveStorageInitializer.initialize(boxName: _walletBox);
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
