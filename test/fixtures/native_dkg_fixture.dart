import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:noosphere_flutter/testing.dart';
import 'package:sygnature_ng/models/roast_setup.dart';
import 'package:sygnature_ng/services/roast_runtime_manager.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';

typedef NativeDkgCoordinator = ({
  NoosphereWorker worker,
  RoastSetup setup,
  GroupConfig group,
  EndpointAddr address,
});

RoastRuntimeManager nativeDkgRuntime(RoastPersistenceFactory persistence) =>
    RoastRuntimeManager(
      persistence,
      getWalletBip39Seed: () => throw StateError('Member has no server seed.'),
      initializeNative: () async {},
      startWorker: NoosphereWorker.startNativeForTesting,
    );

Future<T> nextEvent<T>(Stream<dynamic> events, bool Function(T) matches) =>
    events.where((event) => event is T).cast<T>().firstWhere(matches);

Future<NativeDkgCoordinator> startNativeDkgCoordinator(
  RoastSetup setup, {
  required String setupId,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final group = GroupConfig(
    id: setup.groupId,
    participants: {
      for (final participant in setup.participants)
        Identifier.fromHex(participant.identifierHex):
            ECCompressedPublicKey.fromHex(participant.publicKeyHex),
    },
  );
  final worker = await NoosphereWorker.startNativeForTesting();
  try {
    final reachable = nextEvent<WorkerSnapshotEvent>(
      worker.events,
      (event) =>
          event.snapshot.setupId == setupId &&
          event.snapshot.coordinator?.ipAddrs.isNotEmpty == true,
    ).then((event) => event.snapshot);
    var snapshot = await worker.startSetup(
      setupId: setupId,
      server: EmbeddedServerOptions(
        serverConfig: ServerConfig(group: group),
        getIrohSecretKey: SecretKey.generate,
        serverPersistence: InMemoryServerPersistence(),
        relay: IrohRelayConfig.disabled(),
      ),
    );
    if (snapshot.coordinator!.ipAddrs.isEmpty) {
      snapshot = await reachable.timeout(timeout);
    }
    final coordinator = snapshot.coordinator!;
    return (
      worker: worker,
      setup: setup.copyWith(
        coordinatorId: coordinator.id,
        coordinatorRelayUrls: const [],
        coordinatorIpAddrs: coordinator.ipAddrs,
      ),
      group: group,
      address: EndpointAddr(
        PublicKey.fromZ32(coordinator.id),
        ipAddrs: coordinator.ipAddrs,
      ),
    );
  } catch (_) {
    await worker.close();
    rethrow;
  }
}
