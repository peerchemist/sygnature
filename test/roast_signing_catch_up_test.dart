import 'dart:async';
import 'dart:io';

import 'package:coinlib/coinlib.dart' show bytesToHex;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:noosphere_flutter/testing.dart';
import 'package:sygnature_ng/services/roast_runtime_manager.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';

import 'fixtures/native_dkg_fixture.dart';
import 'fixtures/wallet_backup_fixture.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(NoosphereFlutter.initializeNative);

  test('a connected signer catches up on a missed request and cancellation', () async {
    final directory = await Directory.systemTemp.createTemp(
      'signing-catch-up-',
    );
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (_) async => directory.path,
    );
    addTearDown(() async {
      await Hive.close();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathChannel,
        null,
      );
      debugDefaultTargetPlatformOverride = null;
      await directory.delete(recursive: true);
    });

    final fixture = WalletBackupFixture();
    final setup = fixture.setup;
    final signer = Identifier.fromHex(setup.localParticipant.identifierHex);
    final creatorId = Identifier.fromHex(setup.participants.last.identifierHex);
    final group = GroupConfig(
      id: setup.groupId,
      participants: {
        for (final participant in setup.participants)
          Identifier.fromHex(participant.identifierHex):
              ECCompressedPublicKey.fromHex(participant.publicKeyHex),
      },
    );
    final serverPersistence = InMemoryServerPersistence();
    final config = ServerConfig(group: group);
    final handler = ServerApiHandler(
      config: config,
      persistence: serverPersistence,
    );
    final server = await IrohServer.start(
      IrohConfig(server: config, relay: IrohRelayConfig.disabled()),
      handler: handler,
      secretKey: SecretKey.generate(),
      persistence: serverPersistence,
    );
    unawaited(server.serve());
    addTearDown(server.close);

    final creatorApi = server.openLocalApi(group.fingerprint);
    addTearDown(creatorApi.close);
    final creatorStore = InMemoryClientStorage();
    await creatorStore.addOrReplaceFrostKey(fixture.keys.last);
    final creator = await Client.login(
      config: ClientConfig(group: group, id: creatorId),
      api: creatorApi,
      store: creatorStore,
      getPrivateKey: (_) async => syntheticPrivateKey(10),
    );
    final subscription = creator.events.listen((_) {});
    addTearDown(() async {
      await creator.logout();
      await subscription.cancel();
    });

    final persistence = RoastPersistenceFactory(cipherKey: Uint8List(32));
    final storage = await persistence.open();
    await storage
        .clientStorage(setup.id)
        .addOrReplaceFrostKey(fixture.keys.first);
    final runtime = RoastRuntimeManager(
      persistence,
      getWalletSeed: () => throw StateError('Member has no server seed.'),
      initializeNative: () async {},
      startWorker: NoosphereWorker.startNativeForTesting,
      signingSyncInterval: const Duration(milliseconds: 100),
    );
    addTearDown(runtime.close);
    final address = server.address;
    final snapshot = await runtime.startSetup(
      setup.copyWith(
        coordinatorId: address.id.toZ32(),
        coordinatorIpAddrs: address.ipAddrs,
        coordinatorRelayUrls: const [],
      ),
    );
    expect(snapshot.connected, isTrue);
    final state = handler.debugState;
    final session = state.participantToSession[signer]!;

    Future<void> missLiveEvent(Future<void> Function() operation) async {
      // Omit the signer from the broadcast while keeping its Iroh stream open.
      state.clientSessions.remove(session.sessionID);
      try {
        await operation();
      } finally {
        state.clientSessions[session.sessionID] = session;
      }
    }

    final details = SignaturesRequestDetails.forMessage(
      text: 'Missed signing request',
      groupKey: fixture.keys.first.groupKey,
      expiry: Expiry(const Duration(minutes: 5)),
    );
    final requestId = bytesToHex(details.id.toBytes());
    final updates = <RoastRuntimeSigningRequestEvent>[];
    final updatesSubscription = runtime.events
        .where((event) => event is RoastRuntimeSigningRequestEvent)
        .cast<RoastRuntimeSigningRequestEvent>()
        .where((event) => event.request.idHex == requestId)
        .listen(updates.add);
    addTearDown(updatesSubscription.cancel);
    final recovered = nextEvent<RoastRuntimeSigningRequestEvent>(
      runtime.events,
      (event) => event.request.idHex == requestId,
    );
    await missLiveEvent(() => creator.requestSignatures(details));
    expect(
      (await recovered.timeout(const Duration(seconds: 10)))
          .request
          .signedMessageText,
      'Missed signing request',
    );

    await runtime.events
        .where((event) => event is RoastRuntimeSnapshotEvent)
        .take(2)
        .drain<void>()
        .timeout(const Duration(seconds: 10));
    expect(updates, hasLength(1));

    final cancelled = nextEvent<RoastRuntimeSigningRequestCancelledEvent>(
      runtime.events,
      (event) => event.requestIdHex == requestId,
    );
    await missLiveEvent(() => creator.cancelSignaturesRequest(details.id));
    await cancelled.timeout(const Duration(seconds: 10));
    expect(state.participantToSession[signer], same(session));
  }, timeout: const Timeout(Duration(minutes: 1)));
}
