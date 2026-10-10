import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/models/wallet_backup.dart';
import 'package:sygnature_ng/models/roast_setup.dart';
import 'package:sygnature_ng/models/wallet_vault.dart';
import 'package:sygnature_ng/services/backup_envelope.dart';
import 'package:sygnature_ng/services/roast_runtime_manager.dart';
import 'package:sygnature_ng/services/wallet_backup_service.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';

import 'backup_envelope_test.dart'
    show syntheticBackupVector, syntheticPassphrase;
import 'fixtures/wallet_backup_fixture.dart';

import 'package:coinlib/coinlib.dart' show hexToBytes;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory directory;
  late HiveWalletRepository repository;
  late RoastPersistenceFactory factory;
  late Uint8List encrypted;
  late WalletBackupFixture fixture;
  final cipherKey = Uint8List.fromList(List.filled(32, 7));

  setUpAll(() async {
    await NoosphereFlutter.initializeNative();
    fixture = WalletBackupFixture(roomHost: true);
    encrypted = await BackupEnvelope.encrypt(
      fixture.backup.encode(),
      'synthetic integration passphrase',
    );
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sygnature-backup-test-');
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (call) async => directory.path,
    );
    repository = await HiveWalletRepository.openWithCipherKey(cipherKey);
    factory = RoastPersistenceFactory(cipherKey: cipherKey);
    await factory.open();
  });
  tearDown(() async {
    await Hive.close();
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
    await directory.delete(recursive: true);
  });

  Future<WalletController> connectedController(_SnapshotRuntime runtime) async {
    await repository.save(fixture.vault);
    final p = await factory.open();
    await p
        .clientStorage(fixture.setup.id)
        .addOrReplaceFrostKey(fixture.keys.first);
    await p
        .roomPersistence(fixture.setup.id)
        .write(
          fixture.setup.groupId,
          fixture.room!.toSnapshot(fixture.backup.groups.single).toBytes(),
        );
    final controller = WalletController(
      repository,
      roastRuntime: runtime,
      backupService: WalletBackupService(repository, factory),
    );
    addTearDown(controller.dispose);
    await controller.load();
    return controller;
  }

  test(
    'first export waits for background connect and reconnects afterwards',
    () async {
      final gate = Completer<void>();
      final runtime = _SnapshotRuntime(fixture.setup, startGate: gate.future);
      final controller = await connectedController(runtime);
      expect(controller.roastOperationInProgress(fixture.setup.id), isTrue);
      final exporting = controller.exportEncryptedBackup('12345678');
      await Future<void>.delayed(Duration.zero);
      expect(runtime.pauses, 0);
      gate.complete();
      final file = await exporting;
      BackupEnvelope.validateHeader(file);
      expect(runtime.pauses, 1);
      expect(runtime.starts, 2);
      expect(runtime.paused, isFalse);
      expect(controller.roastSetups.single.isActive, isTrue);
      expect(controller.busy, isFalse);
    },
  );

  test(
    'expired cached signing request does not block the first export',
    () async {
      final runtime = _SnapshotRuntime(fixture.setup);
      final controller = await connectedController(runtime);
      final received = Completer<void>();
      controller.addListener(() {
        if (controller.roastSigningRequests.isNotEmpty &&
            !received.isCompleted) {
          received.complete();
        }
      });
      final expiry = DateTime.now().add(const Duration(seconds: 2));
      runtime.addRequest(expiry);
      await received.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(
        expiry.difference(DateTime.now()) + const Duration(milliseconds: 10),
      );
      expect(controller.roastSigningRequests, hasLength(1));
      final file = await controller.exportEncryptedBackup('12345678');
      BackupEnvelope.validateHeader(file);
      expect(runtime.pauses, 1);
      expect(runtime.starts, 2);
    },
  );

  for (final status in ['waiting', 'accepted', 'rejected']) {
    test(
      'export checks signing status rather than cached inbox presence ($status)',
      () async {
        final runtime = _SnapshotRuntime(fixture.setup);
        final controller = await connectedController(runtime);
        runtime.addRequest(
          DateTime.now().add(const Duration(minutes: 5)),
          status: status,
        );
        final exporting = controller.exportEncryptedBackup('12345678');
        if (status == 'rejected') {
          BackupEnvelope.validateHeader(await exporting);
          expect(runtime.pauses, 1);
        } else {
          await expectLater(exporting, throwsFormatException);
          expect(runtime.pauses, 0);
        }
        expect(controller.busy, isFalse);
      },
    );
  }

  test(
    'request arriving during pause aborts snapshot and reconnects',
    () async {
      final runtime = _SnapshotRuntime(fixture.setup);
      final controller = await connectedController(runtime);
      runtime.onPaused = () =>
          runtime.addRequest(DateTime.now().add(const Duration(minutes: 5)));
      await expectLater(
        controller.exportEncryptedBackup('12345678'),
        throwsFormatException,
      );
      expect(runtime.pauses, 1);
      expect(runtime.starts, 2);
      expect(runtime.paused, isFalse);
      expect(controller.busy, isFalse);
    },
  );

  test(
    'export validation failure still reconnects previously started groups',
    () async {
      final runtime = _SnapshotRuntime(fixture.setup);
      final controller = await connectedController(runtime);
      await Hive.box<dynamic>('sygnature_roast_private_v1')
          .delete('client:${fixture.setup.id}');
      await expectLater(
        controller.exportEncryptedBackup('12345678'),
        throwsFormatException,
      );
      expect(runtime.pauses, 1);
      expect(runtime.starts, 2);
      expect(runtime.paused, isFalse);
      expect(controller.busy, isFalse);
    },
  );

  test(
    'preview makes no writes, confirmed import durably restores all local data',
    () async {
      final service = WalletBackupService(repository, factory);
      final preview = await service.previewImport(
        encrypted,
        'synthetic integration passphrase',
      );
      expect(preview.accountCount, 2);
      expect(preview.walletCount, 1);
      expect(preview.groupCount, 1);
      expect(preview.networks, ['peercoin:testnet']);
      expect(await repository.load(), isNull);
      expect(Hive.box<dynamic>('sygnature_roast_private_v1').isEmpty, isTrue);
      await service.importEncrypted(
        encrypted,
        'synthetic integration passphrase',
        ImportOptions(preview),
      );
      final restored = (await repository.load())!;
      expect(restored.mnemonic, fixture.vault.mnemonic);
      final roastAccount = restored.accounts.singleWhere(
        (a) => a.sourceId == fixture.setup.id,
      );
      expect(roastAccount.keyId, fixture.setup.keyName);
      expect(roastAccount.address, fixture.vault.accounts.last.address);
      expect(
        restored.accounts.first.privateKeyHex,
        fixture.vault.accounts.first.privateKeyHex,
      );
      expect(restored.roastSetups.single.requiresBackupReconciliation, isTrue);
      final p = await factory.open();
      final state = await p.clientStorage(fixture.setup.id).loadState();
      expect(
        state.keys.single.keyInfo.toBytes(),
        fixture.keys.first.keyInfo.toBytes(),
      );
      expect(state.sigNonces, isEmpty);
      expect(state.preparedOperations, isEmpty);
      expect(state.rejectedRequests, isEmpty);
      expect(await factory.loadSigningOperations(), isEmpty);
      expect(
        await p.serverPersistence(fixture.setup.id).load(fixture.setup.groupId),
        isNull,
      );
      final rooms = await p.roomPersistence(fixture.setup.id).loadAll();
      final room = RoomSnapshot.fromBytes(rooms[fixture.setup.groupId]!);
      expect(room.lifecycle, RoomLifecycle.frozen);
      expect(room.invites, isEmpty);
      expect(room.participants, hasLength(2));
      await Hive.close();
      final reopened = await HiveWalletRepository.openWithCipherKey(cipherKey);
      final restarted = RoastPersistenceFactory(cipherKey: cipherKey);
      await restarted.recoverBackupImport(reopened);
      expect((await reopened.load())!.mnemonic, fixture.vault.mnemonic);
      expect(
        (await (await restarted.open())
                .clientStorage(fixture.setup.id)
                .loadState())
            .keys,
        hasLength(1),
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'controller exports an offline group while a Noosphere worker is alive',
    () async {
      await repository.save(
        fixture.vault.copyWith(
          roastSetups: [
            fixture.setup.copyWith(requiresBackupReconciliation: true),
          ],
        ),
      );
      final p = await factory.open();
      await p
          .clientStorage(fixture.setup.id)
          .addOrReplaceFrostKey(fixture.keys.first);
      await p
          .roomPersistence(fixture.setup.id)
          .write(
            fixture.setup.groupId,
            fixture.room!.toSnapshot(fixture.backup.groups.single).toBytes(),
          );
      final worker = await NoosphereWorker.startForTesting();
      final runtime = RoastRuntimeManager(
        factory,
        getWalletBip39Seed: () =>
            throw StateError('Offline shutdown needs no seed.'),
        startWorker: () async => worker,
      );
      await expectLater(
        runtime.updateCoordinatorAddress(
          fixture.setup,
          RoastCoordinatorAddress(
            id: fixture.setup.coordinatorId!,
            relayUrls: fixture.setup.coordinatorRelayUrls,
            ipAddrs: fixture.setup.coordinatorIpAddrs,
          ),
        ),
        throwsStateError,
      );
      final controller = WalletController(
        repository,
        roastRuntime: runtime,
        backupService: WalletBackupService(repository, factory),
      );
      addTearDown(() async {
        await runtime.close();
        controller.dispose();
      });
      await controller.load();
      final file = await controller.exportEncryptedBackup('12345678');
      expect(worker.isClosed, isTrue);
      final plaintext = await BackupEnvelope.decrypt(file, '12345678');
      final backup = WalletBackupV1.decode(plaintext);
      expect(
        backup.groups.single.keys.single.secretShare,
        fixture.keys.first.keyInfo.private.share.data,
      );
      expect(controller.busy, isFalse);
      backup.clearSecrets();
      plaintext.fillRange(0, plaintext.length, 0);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'snapshot export does not decode or export nonce/session records',
    () async {
      await repository.save(fixture.vault);
      final p = await factory.open();
      await p
          .clientStorage(fixture.setup.id)
          .addOrReplaceFrostKey(fixture.keys.first);
      await p
          .roomPersistence(fixture.setup.id)
          .write(
            fixture.setup.groupId,
            fixture.room!.toSnapshot(fixture.backup.groups.single).toBytes(),
          );
      final box = Hive.box<dynamic>('sygnature_roast_private_v1');
      final raw = Map<String, dynamic>.from(
        box.get('client:${fixture.setup.id}') as Map,
      );
      raw['nonces'] = {'not-a-real-nonce': 'SECRET-NONCE-SENTINEL'};
      raw['prepared'] = {'not-a-session': 'SECRET-SESSION-SENTINEL'};
      await box.put('client:${fixture.setup.id}', raw);
      final file = await WalletBackupService(
        repository,
        factory,
      ).exportEncrypted('synthetic export passphrase');
      final plaintext = await BackupEnvelope.decrypt(
        file,
        'synthetic export passphrase',
      );
      expect(
        latin1.decode(plaintext),
        isNot(contains('SECRET-NONCE-SENTINEL')),
      );
      expect(
        latin1.decode(plaintext),
        isNot(contains('SECRET-SESSION-SENTINEL')),
      );
      expect(
        WalletBackupV1.decode(plaintext).groups.single.keys.single.secretShare,
        fixture.keys.first.keyInfo.private.share.data,
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'wrong password and tampered input never modify either database',
    () async {
      final service = WalletBackupService(repository, factory);
      await expectLater(
        service.previewImport(encrypted, 'wrong'),
        throwsFormatException,
      );
      final changed = Uint8List.fromList(encrypted)..[60] ^= 1;
      await expectLater(
        service.previewImport(changed, 'synthetic integration passphrase'),
        throwsFormatException,
      );
      expect(await repository.load(), isNull);
      expect(Hive.box<dynamic>('sygnature_roast_private_v1').isEmpty, isTrue);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'existing wallet/group conflicts reject without modifying state',
    () async {
      await repository.save(fixture.vault);
      await expectLater(
        factory.commitBackupImport(repository, fixture.backup, 'conflict'),
        throwsFormatException,
      );
      expect((await repository.load())!.mnemonic, fixture.vault.mnemonic);
      await repository.delete();
      await (await factory.open())
          .clientStorage(fixture.setup.id)
          .addOrReplaceFrostKey(fixture.keys.first);
      await expectLater(
        factory.commitBackupImport(repository, fixture.backup, 'older'),
        throwsFormatException,
      );
      expect(await repository.load(), isNull);
      expect(
        (await (await factory.open())
                .clientStorage(fixture.setup.id)
                .loadState())
            .keys
            .single
            .keyInfo
            .toBytes(),
        fixture.keys.first.keyInfo.toBytes(),
      );
    },
  );
  test(
    'simulated wallet write failure rolls signing and room state back',
    () async {
      final failing = _FailingRepository(repository);
      await expectLater(
        factory.commitBackupImport(failing, fixture.backup, 'failed'),
        throwsStateError,
      );
      expect(await repository.load(), isNull);
      expect(Hive.box<dynamic>('sygnature_roast_private_v1').isEmpty, isTrue);
    },
  );
  test('startup rolls back a crash before the atomic wallet commit', () async {
    final box = Hive.box<dynamic>('sygnature_roast_private_v1');
    await box.put('backup-import-journal-v1', {
      'restoreId': 'interrupted',
      'keys': ['client:setup-1', 'rooms:setup-1'],
    });
    await box.put('client:setup-1', {
      'keys': ['partially staged'],
    });
    await box.flush();
    await Hive.close();
    repository = await HiveWalletRepository.openWithCipherKey(cipherKey);
    factory = RoastPersistenceFactory(cipherKey: cipherKey);
    await factory.recoverBackupImport(repository);
    expect(await repository.load(), isNull);
    expect(Hive.box<dynamic>('sygnature_roast_private_v1').isEmpty, isTrue);
  });
  test(
    'startup preserves a committed import and completes journal cleanup',
    () async {
      final box = Hive.box<dynamic>('sygnature_roast_private_v1');
      await box.put('backup-import-journal-v1', {
        'restoreId': 'committed',
        'keys': ['client:setup-1'],
      });
      await (await factory.open())
          .clientStorage(fixture.setup.id)
          .addOrReplaceFrostKey(fixture.keys.first);
      await repository.save(fixture.backup.toVault(restoreId: 'committed')!);
      await Hive.close();
      repository = await HiveWalletRepository.openWithCipherKey(cipherKey);
      factory = RoastPersistenceFactory(cipherKey: cipherKey);
      await factory.recoverBackupImport(repository);
      expect((await repository.load())!.backupRestoreId, 'committed');
      expect(
        (await (await factory.open())
                .clientStorage(fixture.setup.id)
                .loadState())
            .keys,
        hasLength(1),
      );
      expect(
        Hive.box<dynamic>('sygnature_roast_private_v1')
            .containsKey('backup-import-journal-v1'),
        isFalse,
      );
    },
  );
  test('empty wallet backup import', () async {
    final service = WalletBackupService(repository, factory);
    final file = hexToBytes(syntheticBackupVector);
    final preview = await service.previewImport(file, syntheticPassphrase);
    expect(preview.walletCount, 0);
    await service.importEncrypted(
      file,
      syntheticPassphrase,
      ImportOptions(preview),
    );
    expect(await repository.load(), isNull);
    expect(Hive.box<dynamic>('sygnature_roast_private_v1').isEmpty, isTrue);
  }, timeout: const Timeout(Duration(minutes: 5)));
  test(
    'missing signing material fails export instead of omitting group',
    () async {
      await repository.save(fixture.vault);
      await expectLater(
        WalletBackupService(repository, factory).exportEncrypted('irrelevant'),
        throwsFormatException,
      );
    },
  );
}

final class _SnapshotRuntime(
  final RoastSetup setup, {
  final Future<void>? startGate,
}) implements RoastRuntime {
  final _events = StreamController<RoastRuntimeEvent>.broadcast();
  int starts = 0;
  int pauses = 0;
  bool paused = false;
  void Function()? onPaused;

  @override
  Stream<RoastRuntimeEvent> get events => _events.stream;

  @override
  Future<RoastRuntimeSnapshot> startSetup(RoastSetup setup) async {
    starts++;
    await startGate;
    return RoastRuntimeSnapshot(
      connected: true,
      signerRunning: true,
      onlineParticipantIds: const [],
      coordinatorId: setup.coordinatorId,
      coordinatorRelayUrls: setup.coordinatorRelayUrls,
      coordinatorIpAddrs: setup.coordinatorIpAddrs,
      groupKeyHex: setup.groupKeyHex,
      pendingDkgProposalHex: null,
    );
  }

  @override
  Future<T> withPausedForBackup<T>(Future<T> Function() snapshot) async {
    pauses++;
    paused = true;
    try {
      onPaused?.call();
      return await snapshot();
    } finally {
      paused = false;
      await startSetup(setup);
      _events.add(
        RoastRuntimeSnapshotEvent(
          setup.id,
          connected: true,
          signerRunning: true,
          onlineParticipantIds: const [],
          coordinatorId: setup.coordinatorId,
          coordinatorRelayUrls: setup.coordinatorRelayUrls,
          coordinatorIpAddrs: setup.coordinatorIpAddrs,
        ),
      );
    }
  }

  void addRequest(DateTime expiry, {String status = 'waiting'}) {
    _events.add(
      RoastRuntimeSigningRequestEvent(
        setup.id,
        request: RoastSigningRequest(
          idHex: 'aa',
          proposalHex: 'bb',
          creator: setup.participants.last.identifierHex,
          expiry: expiry,
          kind: RoastSigningRequestKind.message,
          hasTransactionMetadata: false,
          usesSupportedSighash: false,
          usesExpectedTaprootTweak: false,
          usesUntweakedKey: true,
          status: status,
          progress: RoastSigningProgress(
            threshold: setup.threshold,
            contributingParticipants: const [],
            stage: 'collecting',
          ),
          inputSats: 0,
          transactionInputCount: 0,
          signedInputIndexes: const [],
          previousOutputScripts: const [],
          inputOutpoints: const [],
          outputs: const [],
          masterGroupKeys: [setup.groupKeyHex!],
          derivationPaths: const [[]],
          signedMessageText: 'Synthetic test message',
        ),
      ),
    );
  }

  @override
  Future<void> close() => _events.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FailingRepository(final WalletRepository inner)
    implements WalletRepository {
  @override
  Future<WalletVault?> load() => inner.load();
  @override
  Future<void> save(WalletVault vault) async =>
      throw StateError('Synthetic write failure');
  @override
  Future<void> delete() => inner.delete();
}
