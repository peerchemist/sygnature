import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:noosphere_flutter/testing.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';

import 'fixtures/native_dkg_fixture.dart';
import 'fixtures/wallet_backup_fixture.dart';

const _roastBox = 'sygnature_roast_private_v1';
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUpAll(NoosphereFlutter.initializeNative);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'sygnature-dkg-secret-lifecycle-',
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _pathChannel,
      (_) async => directory.path,
    );
  });

  tearDown(() async {
    await Hive.close();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_pathChannel, null);
    debugDefaultTargetPlatformOverride = null;
    await directory.delete(recursive: true);
  });

  test('startup deletes a DKG secret with no active ceremony', () async {
    final fixture = WalletBackupFixture(
      setupId: 'stale-secret-setup',
      groupId: 'stale-secret-group',
    );
    final coordinator = await startNativeDkgCoordinator(
      fixture.setup,
      setupId: 'dkg-secret-coordinator',
    );
    addTearDown(coordinator.worker.close);
    var persistence = RoastPersistenceFactory(cipherKey: Uint8List(32));
    var storage = (await persistence.open()).dkgSecretStorage(fixture.setup.id);
    await storage.write('orphaned-dkg', Uint8List.fromList([1, 2, 3, 4]));
    await Hive.close();

    persistence = RoastPersistenceFactory(cipherKey: Uint8List(32));
    storage = (await persistence.open()).dkgSecretStorage(fixture.setup.id);
    expect(_hasDkgSecretRecord(fixture.setup.id), isTrue);

    final runtime = nativeDkgRuntime(persistence);
    addTearDown(runtime.close);
    final snapshot = await runtime.startSetup(coordinator.setup);

    expect(snapshot.pendingDkgProposalHex, isNull);
    expect(await storage.loadAll(), isEmpty);
    expect(_hasDkgSecretRecord(fixture.setup.id), isFalse);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('startup deletes a DKG secret immediately after importing it', () async {
    final fixture = WalletBackupFixture(
      setupId: 'restored-secret-setup',
      groupId: 'restored-secret-group',
    );
    final coordinator = await startNativeDkgCoordinator(
      fixture.setup,
      setupId: 'dkg-secret-coordinator',
    );
    addTearDown(coordinator.worker.close);
    var persistence = RoastPersistenceFactory(cipherKey: Uint8List(32));
    var storage = (await persistence.open()).dkgSecretStorage(fixture.setup.id);
    var runtime = nativeDkgRuntime(persistence);
    addTearDown(() => runtime.close());
    await runtime.startSetup(coordinator.setup);

    await coordinator.worker.startSetup(
      setupId: 'restored-secret-cosigner',
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
    final proposalReceived = coordinator.worker.events
        .where((event) => event is WorkerDkgEvent)
        .cast<WorkerDkgEvent>()
        .firstWhere(
          (event) =>
              event.setupId == 'restored-secret-cosigner' &&
              event.status.name == fixture.setup.keyName &&
              !event.rejected,
        );
    await runtime.requestDkg(coordinator.setup);
    await proposalReceived.timeout(const Duration(seconds: 15));
    final saved = await storage.loadAll();
    try {
      expect(saved.keys, [fixture.setup.keyName]);
      expect(_hasDkgSecretRecord(fixture.setup.id), isTrue);
    } finally {
      for (final secret in saved.values) {
        secret.fillRange(0, secret.length, 0);
      }
    }

    await runtime.close();
    await Hive.close();
    persistence = RoastPersistenceFactory(cipherKey: Uint8List(32));
    storage = (await persistence.open()).dkgSecretStorage(fixture.setup.id);
    expect(_hasDkgSecretRecord(fixture.setup.id), isTrue);
    runtime = nativeDkgRuntime(persistence);
    final restored = await runtime.startSetup(coordinator.setup);

    expect(restored.pendingDkgName, fixture.setup.keyName);
    expect(restored.pendingDkgStage, 'round1');
    expect(await storage.loadAll(), isEmpty);
    expect(_hasDkgSecretRecord(fixture.setup.id), isFalse);
  }, timeout: const Timeout(Duration(minutes: 1)));
}

bool _hasDkgSecretRecord(String setupId) =>
    Hive.box<dynamic>(_roastBox).containsKey('dkg-secrets:$setupId');
