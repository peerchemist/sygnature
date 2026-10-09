import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:sygnature_ng/models/wallet_vault.dart';
import 'package:sygnature_ng/storage/hive_storage_initializer.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';
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
      await wallet.save(_vault);
      await roast.roomPersistence('setup').write('room', roomState);
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
      expect(keys.values, savedKeys);
      expect(keys.writes, 2);
    },
  );

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

      await expectLater(open(keys), throwsA(isA<StateError>()));
      expect(Hive.isBoxOpen(boxName), isFalse);
      expect(await file.readAsBytes(), before);
      expect(keys.writes, writes);
      expect(keys.values, isEmpty);

      keys.values[keyName] = savedKey;
      await open(keys);
      expect(Hive.isBoxOpen(boxName), isTrue);
    });

    test('rejects malformed $name keys without replacing them', () async {
      final keys = _MemorySecureKeyStore()..values[keyName] = 'invalid-base64!';
      await expectLater(open(keys), throwsA(isA<FormatException>()));
      expect(keys.values[keyName], 'invalid-base64!');
      expect(keys.writes, 0);
      expect(Hive.isBoxOpen(boxName), isFalse);
    });

    test('rejects $name keys with an invalid length', () async {
      final encoded = base64UrlEncode(Uint8List(31));
      final keys = _MemorySecureKeyStore()..values[keyName] = encoded;
      await expectLater(
        open(keys),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            roast
                ? 'Invalid encrypted ROAST storage key length.'
                : 'Invalid encrypted vault key length.',
          ),
        ),
      );
      expect(keys.values[keyName], encoded);
      expect(keys.writes, 0);
      expect(Hive.isBoxOpen(boxName), isFalse);
    });

    test('does not create a $name box if saving its key fails', () async {
      final keys = _MemorySecureKeyStore()..failWrites = true;
      await expectLater(open(keys), throwsA(isA<StateError>()));
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
