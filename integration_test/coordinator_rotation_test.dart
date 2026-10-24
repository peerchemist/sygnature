// Run on an Android device with:
// ORG_GRADLE_PROJECT_publicFeedVerification=true flutter test --no-pub \
//   integration_test/coordinator_rotation_test.dart -d <device-id> \
//   --dart-define=RUN_COORDINATOR_ROTATION_TESTS=true
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:noosphere_flutter/testing.dart';

import '../test/support/roast_rotation_common.dart';

const _runCoordinatorRotationTests = bool.fromEnvironment(
  'RUN_COORDINATOR_ROTATION_TESTS',
);
const _expectedAndroidPackage = 'network.noosphere.sygnature.publicfeedtest';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(NoosphereFlutter.initializeNative);

  testWidgets(
    'signers recover when the roast coordinator goes offline',
    (_) async {
      void phase(String value) => debugPrint('Coordinator rotation: $value');

      phase('checking isolated package');
      await _expectIsolatedAndroidPackage();

      final workers = <NoosphereWorker>[];
      phase('starting original coordinator worker');
      final oldCoordinatorWorker =
          await NoosphereWorker.startNativeForTesting();
      workers.add(oldCoordinatorWorker);

      try {
        phase('publishing original coordinator');
        final oldCoordinator = await _startCoordinator(
          oldCoordinatorWorker,
          '${rotationSetupId}_old_coordinator',
        );

        final signers = <NoosphereWorker>[];
        phase('starting signer workers');
        for (
          var participant = 1;
          participant <= rotationIds.length;
          participant++
        ) {
          final worker = await NoosphereWorker.startNativeForTesting();
          workers.add(worker);
          signers.add(worker);
          await worker.startSetup(
            setupId: rotationSetupId,
            client: _clientOptions(participant, oldCoordinator),
          );
        }
        phase('waiting for the original group');
        await _waitForFullGroup(signers);

        phase('running DKG');
        final keyUpdateFutures = [
          for (final signer in signers)
            _nextEvent<WorkerKeyUpdatedEvent>(
              signer,
              (event) => event.setupId == rotationSetupId,
            ),
        ];
        final participant2Dkg = _nextEvent<WorkerDkgEvent>(
          signers[1],
          (event) =>
              event.setupId == rotationSetupId &&
              event.status.stage == 'waiting',
        );
        final participant3Dkg = _nextEvent<WorkerDkgEvent>(
          signers[2],
          (event) =>
              event.setupId == rotationSetupId &&
              event.status.stage == 'waiting',
        );

        phase('requesting DKG');
        await signers[0].requestDkg(
          rotationSetupId,
          NewDkgDetails(
            name: rotationKeyName,
            description: 'Coordinator offline recovery integration test',
            threshold: 2,
            expiry: Expiry(const Duration(hours: 1)),
            groupFingerprint: rotationGroup.fingerprint,
          ),
        );
        phase('waiting for DKG approvals');
        final dkgEvents = await Future.wait([participant2Dkg, participant3Dkg]);
        phase('accepting DKG');
        await Future.wait([
          signers[1].acceptDkg(rotationSetupId, dkgEvents[0].status),
          signers[2].acceptDkg(rotationSetupId, dkgEvents[1].status),
        ]);

        phase('waiting for DKG keys');
        final keyUpdates = await Future.wait(keyUpdateFutures);
        final groupKeyHex = keyUpdates.first.key.groupKeyHex;
        expect(groupKeyHex, isNotEmpty);
        expect(
          keyUpdates.map((event) => event.key.groupKeyHex),
          everyElement(groupKeyHex),
        );

        phase('starting replacement coordinator');
        final replacementCoordinatorWorker =
            await NoosphereWorker.startNativeForTesting();
        workers.add(replacementCoordinatorWorker);
        final replacementCoordinator = await _startCoordinator(
          replacementCoordinatorWorker,
          '${rotationSetupId}_replacement_coordinator',
        );
        expect(replacementCoordinator.id, isNot(oldCoordinator.id));

        phase('stopping original coordinator');
        await oldCoordinatorWorker.close();
        await _waitForDisconnected(signers);

        phase('switching signers to replacement coordinator');
        final persistedCoordinators = <EndpointAddr>[];
        for (final signer in signers) {
          final snapshot = await signer.switchCoordinator(
            rotationSetupId,
            newCoordinator: replacementCoordinator,
            persist: (coordinator) async {
              persistedCoordinators.add(coordinator);
            },
          );
          expect(snapshot.connected, isTrue);
        }
        expect(persistedCoordinators, hasLength(rotationIds.length));
        expect(
          persistedCoordinators.map((coordinator) => coordinator.id),
          everyElement(replacementCoordinator.id),
        );
        await _waitForFullGroup(signers);

        phase('signing through replacement coordinator');
        final signingRequest = _nextEvent<WorkerSigningRequestEvent>(
          signers[1],
          (event) => event.setupId == rotationSetupId,
        );
        final signingResult = _nextEvent<WorkerSigningResultEvent>(
          signers[0],
          (event) => event.setupId == rotationSetupId,
        );
        await signers[0].requestSignatures(
          rotationSetupId,
          SignaturesRequestDetails.forMessage(
            text: rotationMessage,
            groupKey: ECCompressedPublicKey.fromHex(groupKeyHex),
            expiry: Expiry(const Duration(minutes: 2)),
          ),
        );
        final request = await signingRequest;
        await signers[1].acceptSignatures(rotationSetupId, request.request);

        final signedMessage = (await signingResult).toSignedMessage();
        expect(signedMessage.text, rotationMessage);
        expect(signedMessage.verify(), isTrue);
        phase('signature verified');
      } catch (error, stackTrace) {
        phase('failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        rethrow;
      } finally {
        phase('closing workers');
        for (final worker in workers.reversed) {
          if (!worker.isClosed) {
            await worker.close();
          }
        }
      }
    },
    skip: !_runCoordinatorRotationTests,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

ClientNodeOptions _clientOptions(int participant, EndpointAddr coordinator) {
  return ClientNodeOptions(
    clientConfig: ClientConfig(
      group: rotationGroup,
      id: rotationIds[participant - 1],
    ),
    bootstrapAddress: coordinator,
    pinnedServerId: coordinator.id,
    relay: IrohRelayConfig.disabled(),
    storage: InMemoryClientStorage(),
    getPrivateKey: (_) async => rotationKeys[participant - 1],
    reconnect: const IrohReconnectConfig(
      initialDelay: Duration(milliseconds: 100),
      maxDelay: Duration(seconds: 1),
      jitter: 0,
    ),
  );
}

Future<EndpointAddr> _startCoordinator(
  NoosphereWorker worker,
  String setupId,
) async {
  await worker.startSetup(
    setupId: setupId,
    server: EmbeddedServerOptions(
      serverConfig: ServerConfig(group: rotationGroup),
      serverPersistence: InMemoryServerPersistence(),
      relay: IrohRelayConfig.disabled(),
      getIrohSecretKey: SecretKey.generate,
    ),
  );

  final snapshot = await _waitForSnapshot(
    worker,
    setupId,
    (value) => value.coordinator?.ipAddrs.isNotEmpty ?? false,
  );
  final coordinator = snapshot.coordinator!;
  return endpointFromWorker(coordinator);
}

Future<void> _waitForFullGroup(List<NoosphereWorker> signers) async {
  await Future.wait([
    for (final signer in signers)
      _waitForSnapshot(
        signer,
        rotationSetupId,
        (snapshot) =>
            snapshot.connected &&
            snapshot.onlineParticipants.length == rotationIds.length - 1,
      ),
  ]);
}

Future<void> _waitForDisconnected(List<NoosphereWorker> signers) async {
  await Future.wait([
    for (final signer in signers)
      _waitForSnapshot(
        signer,
        rotationSetupId,
        (snapshot) => !snapshot.connected,
      ),
  ]);
}

Future<NoosphereWorkerSnapshot> _waitForSnapshot(
  NoosphereWorker worker,
  String setupId,
  bool Function(NoosphereWorkerSnapshot snapshot) predicate,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  NoosphereWorkerSnapshot? latest;
  while (DateTime.now().isBefore(deadline)) {
    latest = await worker.snapshot(setupId);
    if (predicate(latest)) {
      return latest;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException(
    'Timed out waiting for setup $setupId; latest snapshot: $latest',
  );
}

Future<T> _nextEvent<T>(
  NoosphereWorker worker,
  bool Function(T event) predicate,
) {
  final future = worker.events
      .where((event) => event is T)
      .cast<T>()
      .firstWhere(predicate)
      .timeout(const Duration(seconds: 30));
  future.ignore();
  return future;
}

Future<void> _expectIsolatedAndroidPackage() async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    final cmdline = await File('/proc/self/cmdline').readAsBytes();
    final processName = utf8
        .decode(cmdline.takeWhile((byte) => byte != 0).toList())
        .trim();
    expect(
      processName,
      startsWith(_expectedAndroidPackage),
      reason:
          'Use the publicFeedVerification Android build property so this '
          'test does not access production app data.',
    );
  }
}
