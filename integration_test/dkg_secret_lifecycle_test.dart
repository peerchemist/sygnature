import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logger/logger.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:noosphere_flutter/testing.dart';
import 'package:sygnature_ng/services/backup_envelope.dart';
import 'package:sygnature_ng/services/roast_runtime_manager.dart';
import 'package:sygnature_ng/services/wallet_backup_service.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';

import '../test/fixtures/native_dkg_fixture.dart';
import '../test/fixtures/wallet_backup_fixture.dart';

const _isolatedAndroidPackage = 'network.noosphere.sygnature.securestoragetest';
const _roastBox = 'sygnature_roast_private_v1';
const _runDkgSecretTests = bool.fromEnvironment(
  'RUN_DKG_SECRET_LIFECYCLE_TESTS',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(NoosphereFlutter.initializeNative);

  _deviceTest(
    'interrupted native DKG is recovered without retaining its secret',
    () async {
      final dkg = await _DeviceDkg.open('device-recovery');
      final logs = <String>[];
      void captureLog(OutputEvent event) => logs.addAll(event.lines);
      Logger.addOutputListener(captureLog);
      addTearDown(() => Logger.removeOutputListener(captureLog));

      await dkg.runtime.startSetup(dkg.coordinator.setup);
      await _startCosigner(
        dkg.coordinator,
        setupId: dkg.cosignerSetupId,
        fixture: dkg.fixture,
      );
      final proposalReceived = nextEvent<WorkerDkgEvent>(
        dkg.coordinator.worker.events,
        (event) =>
            event.setupId == dkg.cosignerSetupId &&
            event.status.name == dkg.fixture.setup.keyName &&
            !event.rejected,
      );

      await dkg.runtime.requestDkg(dkg.coordinator.setup);
      final cosignerProposal = await proposalReceived.timeout(
        const Duration(seconds: 20),
      );
      final saved = await dkg.storage.loadAll();
      expect(saved.keys, [dkg.fixture.setup.keyName]);
      final secret = Uint8List.fromList(saved.values.single);
      for (final value in saved.values) {
        value.fillRange(0, value.length, 0);
      }

      try {
        await _expectEncryptedAtRest(dkg.setupId, secret);
        await dkg.reopen();
        expect(_hasDkgSecretRecord(dkg.setupId), isTrue);

        final requesterKeyReady = nextEvent<RoastRuntimeKeyEvent>(
          dkg.runtime.events,
          (event) => event.setupId == dkg.setupId,
        );
        final cosignerKeyReady = nextEvent<WorkerKeyUpdatedEvent>(
          dkg.coordinator.worker.events,
          (event) => event.setupId == dkg.cosignerSetupId,
        );
        final restored = await dkg.runtime.startSetup(dkg.coordinator.setup);

        expect(restored.pendingDkgName, dkg.fixture.setup.keyName);
        expect(restored.pendingDkgStage, 'round1');
        await dkg.expectSecretDeleted();

        await dkg.coordinator.worker.acceptDkg(
          dkg.cosignerSetupId,
          cosignerProposal.status,
        );
        await Future.wait([
          requesterKeyReady.timeout(const Duration(seconds: 30)),
          cosignerKeyReady.timeout(const Duration(seconds: 30)),
        ]);
        await dkg.expectSecretDeleted();
        _expectSecretAbsent(utf8.encode(logs.join('\n')), secret);

        await dkg.reopen();
        await dkg.expectSecretDeleted();
      } finally {
        secret.fillRange(0, secret.length, 0);
      }
    },
    timeout: const Duration(minutes: 3),
  );

  _deviceTest(
    'rejected native DKG deletes its persisted recovery secret',
    () async {
      final dkg = await _DeviceDkg.open('device-rejection');

      await dkg.runtime.startSetup(dkg.coordinator.setup);
      final proposalReceived = nextEvent<RoastRuntimeDkgEvent>(
        dkg.runtime.events,
        (event) =>
            event.setupId == dkg.setupId &&
            event.name == dkg.fixture.setup.keyName &&
            !event.rejected,
      );
      await dkg.runtime.requestDkg(dkg.coordinator.setup);
      final proposal = await proposalReceived.timeout(
        const Duration(seconds: 20),
      );
      expect((await dkg.storage.loadAll()).keys, [dkg.fixture.setup.keyName]);
      expect(_hasDkgSecretRecord(dkg.setupId), isTrue);

      await dkg.runtime.rejectDkg(dkg.setupId, proposal.proposalHex);
      await dkg.expectSecretDeleted();

      await dkg.reopen();
      await dkg.expectSecretDeleted();
    },
  );

  _deviceTest(
    'backup export and Hive file never contain DKG secret plaintext',
    () async {
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final fixture = _fixture('device-backup', suffix);
      final repository = MemoryWalletRepository()..value = fixture.vault;
      final factory = RoastPersistenceFactory();
      final persistence = await factory.open();
      final storage = persistence.dkgSecretStorage(fixture.setup.id);
      final secret = Uint8List.fromList(
        utf8.encode('SYGNATURE_DKG_SECRET_CANARY_$suffix'),
      );
      addTearDown(() async {
        secret.fillRange(0, secret.length, 0);
        await factory.deleteSetupData(fixture.setup.id);
        await Hive.close();
      });

      await persistence
          .clientStorage(fixture.setup.id)
          .addOrReplaceFrostKey(fixture.keys.first);
      await storage.write(fixture.setup.keyName, secret);
      await _expectEncryptedAtRest(fixture.setup.id, secret);

      final encrypted = await WalletBackupService(
        repository,
        factory,
      ).exportEncrypted('device integration test passphrase');
      final plaintext = await BackupEnvelope.decrypt(
        encrypted,
        'device integration test passphrase',
      );
      try {
        _expectSecretAbsent(plaintext, secret);
      } finally {
        plaintext.fillRange(0, plaintext.length, 0);
      }
    },
  );
}

void _deviceTest(
  String description,
  Future<void> Function() body, {
  Duration timeout = const Duration(minutes: 2),
}) {
  testWidgets(
    description,
    (_) async {
      await _expectIsolatedAndroidPackage();
      await body();
    },
    skip: !_runDkgSecretTests,
    timeout: Timeout(timeout),
  );
}

WalletBackupFixture _fixture(String prefix, int suffix) => WalletBackupFixture(
  setupId: '$prefix-$suffix',
  groupId: '$prefix-group-$suffix',
);

final class _DeviceDkg._(
  this.fixture,
  this.coordinator,
  this.factory,
  this.storage,
  this.runtime,
) {
  final WalletBackupFixture fixture;
  final NativeDkgCoordinator coordinator;
  RoastPersistenceFactory factory;
  RoastDkgSecretStorage storage;
  RoastRuntimeManager runtime;

  String get setupId => fixture.setup.id;
  String get cosignerSetupId => '$setupId-cosigner';

  static Future<_DeviceDkg> open(String prefix) async {
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final fixture = _fixture(prefix, suffix);
    final coordinator = await startNativeDkgCoordinator(
      fixture.setup,
      setupId: 'device-dkg-coordinator-$suffix',
      timeout: const Duration(seconds: 20),
    );
    final factory = RoastPersistenceFactory();
    final storage = (await factory.open()).dkgSecretStorage(fixture.setup.id);
    final dkg = _DeviceDkg._(
      fixture,
      coordinator,
      factory,
      storage,
      nativeDkgRuntime(factory),
    );
    addTearDown(dkg.close);
    return dkg;
  }

  Future<void> reopen() async {
    await runtime.close();
    await Hive.close();
    factory = RoastPersistenceFactory();
    storage = (await factory.open()).dkgSecretStorage(setupId);
    runtime = nativeDkgRuntime(factory);
  }

  Future<void> expectSecretDeleted() async {
    expect(await storage.loadAll(), isEmpty);
    expect(_hasDkgSecretRecord(setupId), isFalse);
  }

  Future<void> close() async {
    await runtime.close();
    await coordinator.worker.close();
    await factory.deleteSetupData(setupId);
    await Hive.close();
  }
}

bool _hasDkgSecretRecord(String setupId) =>
    Hive.box<dynamic>(_roastBox).containsKey('dkg-secrets:$setupId');

Future<void> _expectEncryptedAtRest(String setupId, Uint8List secret) async {
  final box = Hive.box<dynamic>(_roastBox);
  final records = Map<String, dynamic>.from(
    box.get('dkg-secrets:$setupId') as Map,
  );
  final record = Map<String, dynamic>.from(records.values.single as Map);
  final ciphertext = record['ciphertext'] as Uint8List;
  expect(ciphertext, isNot(orderedEquals(secret)));
  _expectSecretAbsent(ciphertext, secret);
  await box.flush();
  _expectSecretAbsent(await File(box.path!).readAsBytes(), secret);
}

void _expectSecretAbsent(List<int> bytes, Uint8List secret) {
  final base64Value = base64Encode(secret);
  final base64UrlValue = base64UrlEncode(secret);
  final hex = secret
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  final encodings = <List<int>>[
    secret,
    ...[
      base64Value,
      base64Value.replaceAll('=', ''),
      base64UrlValue,
      base64UrlValue.replaceAll('=', ''),
      hex,
      hex.toUpperCase(),
      secret.toString(),
    ].map(utf8.encode),
  ];
  for (final encoding in encodings) {
    expect(_containsBytes(bytes, encoding), isFalse);
  }
}

bool _containsBytes(List<int> bytes, List<int> candidate) {
  if (candidate.isEmpty || candidate.length > bytes.length) return false;
  for (var offset = 0; offset <= bytes.length - candidate.length; offset++) {
    var matches = true;
    for (var i = 0; i < candidate.length; i++) {
      if (bytes[offset + i] != candidate[i]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

Future<void> _expectIsolatedAndroidPackage() async {
  expect(
    defaultTargetPlatform,
    TargetPlatform.android,
    reason: 'This isolated storage test currently supports Android only.',
  );
  final commandLine = await File('/proc/self/cmdline').readAsBytes();
  final terminator = commandLine.indexOf(0);
  final processName = utf8.decode(
    commandLine.sublist(0, terminator < 0 ? commandLine.length : terminator),
  );
  expect(
    processName,
    _isolatedAndroidPackage,
    reason: 'Run with ORG_GRADLE_PROJECT_secureStorageVerification=true.',
  );
}

Future<void> _startCosigner(
  NativeDkgCoordinator coordinator, {
  required String setupId,
  required WalletBackupFixture fixture,
}) async {
  await coordinator.worker.startSetup(
    setupId: setupId,
    client: ClientNodeOptions(
      clientConfig: ClientConfig(
        group: coordinator.group,
        id: Identifier.fromHex(fixture.setup.participants[1].identifierHex),
      ),
      bootstrapAddress: coordinator.address,
      pinnedServerId: coordinator.address.id,
      relay: IrohRelayConfig.disabled(),
      storage: InMemoryClientStorage(),
      getPrivateKey: (_) async => syntheticPrivateKey(10),
    ),
  );
}
