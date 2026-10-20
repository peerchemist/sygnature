// Android half of the 2-of-2 process-death DKG harness. Build only with the
// isolated verification application ID. Uses deterministic test identities.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart';
import 'package:flutter/material.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sygnature_ng/storage/hive_storage_initializer.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';

import 'roast_2of2_crash_common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadCoinlib();
  await NoosphereFlutter.initialize();
  await HiveStorageInitializer.initialize(
    boxName: 'sygnature_2of2_crash_device_e2e',
  );
  final directory = await getApplicationSupportDirectory();
  final config = Map<String, dynamic>.from(
    jsonDecode(
      await File('${directory.path}/crash_device_config.json').readAsString(),
    ) as Map,
  );
  final harness = _CrashDeviceHarness(
    directory: directory,
    coordinator: decodeCrashEndpoint(config['coordinator'] as String),
  );
  await harness.start();
  runApp(_CrashDeviceApp(harness));
}

final class _CrashDeviceHarness({
  required this.directory,
  required this.coordinator,
}) {
  final Directory directory;
  final EndpointAddr coordinator;
  final status = ValueNotifier<String>('starting');

  late final NoosphereWorker _worker;
  late final RoastDkgSecretStorage _secretStorage;
  StreamSubscription<NoosphereWorkerEvent>? _events;
  Timer? _snapshotTimer;
  bool _acceptingDkg = false;
  bool _acceptingSignature = false;
  String _phase = 'starting';

  File get _statusFile => File('${directory.path}/crash_device_status.json');

  Future<void> start() async {
    _worker = await NoosphereWorker.start();
    _events = _worker.events.listen(_handleEvent, onError: _fail);
    final persistence = await RoastPersistenceFactory(
      cipherKey: Uint8List.fromList(List<int>.filled(32, 2)),
    ).open();
    _secretStorage = persistence.dkgSecretStorage(crashSetupId);
    var snapshot = await _worker.startSetup(
      setupId: crashSetupId,
      client: ClientNodeOptions(
        clientConfig: ClientConfig(group: crashGroup, id: crashIds[1]),
        bootstrapAddress: coordinator,
        pinnedServerId: coordinator.id,
        storage: persistence.clientStorage(crashSetupId),
        getPrivateKey: (_) async => crashIdentityKeys[1],
        persistDkgSecret: _secretStorage.write,
        reconnect: const IrohReconnectConfig(
          initialDelay: Duration(milliseconds: 100),
          maxDelay: Duration(seconds: 1),
          jitter: 0,
        ),
      ),
    );
    final secrets = await _secretStorage.loadAll();
    try {
      for (final dkg in snapshot.dkgs.where((item) => !item.canResume)) {
        final secret = secrets[dkg.name];
        if (secret == null) {
          throw StateError('Persisted DKG state is missing for ${dkg.name}.');
        }
        await _worker.importDkgSecret(crashSetupId, secret);
        _phase = 'dkg-restored';
        snapshot = await _worker.snapshot(crashSetupId);
      }
    } finally {
      for (final secret in secrets.values) {
        secret.fillRange(0, secret.length, 0);
      }
    }
    await _record(snapshot);
    _snapshotTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => unawaited(_refresh()),
    );
  }

  Future<void> _handleEvent(NoosphereWorkerEvent event) async {
    if (event.setupId != crashSetupId) return;
    try {
      if (event is WorkerDkgEvent &&
          event.status.stage == 'waiting' &&
          !_acceptingDkg) {
        _acceptingDkg = true;
        _phase = 'accepting-dkg';
        await _refresh();
        try {
          await _worker.acceptDkg(crashSetupId, event.status);
        } finally {
          _acceptingDkg = false;
        }
      } else if (event is WorkerKeyUpdatedEvent) {
        _phase = 'key-ready';
        await _secretStorage.delete(crashKeyName);
      } else if (event is WorkerSigningRequestEvent &&
          event.request.status == 'waiting' &&
          !_acceptingSignature) {
        _acceptingSignature = true;
        try {
          await _worker.acceptSignatures(crashSetupId, event.request);
          _phase = 'signature-approved';
        } finally {
          _acceptingSignature = false;
        }
      } else if (event is WorkerFailureEvent) {
        throw StateError('${event.operation}: ${event.message}');
      }
      await _refresh();
    } catch (error, stackTrace) {
      await _fail(error, stackTrace);
    }
  }

  Future<void> _refresh() async {
    try {
      await _record(await _worker.snapshot(crashSetupId));
    } catch (error, stackTrace) {
      await _fail(error, stackTrace);
    }
  }

  Future<void> _record(NoosphereWorkerSnapshot snapshot) async {
    final dkg = snapshot.dkgs.firstOrNull;
    if (_phase == 'starting' && snapshot.connected) _phase = 'connected';
    final payload = <String, Object?>{
      'phase': _phase,
      'connected': snapshot.connected,
      'keys': snapshot.keys.length,
      'dkgStage': dkg?.stage,
      'dkgCanResume': dkg?.canResume,
      'dkgCompletedParticipants': dkg?.completedParticipants.length ?? 0,
      'onlinePeers': snapshot.onlineParticipants.length,
      'error': null,
    };
    await _statusFile.writeAsString(jsonEncode(payload), flush: true);
    status.value = jsonEncode(payload);
  }

  Future<void> _fail(Object error, [StackTrace? stackTrace]) async {
    final payload = <String, Object?>{
      'phase': 'error',
      'error': error.toString(),
    };
    await _statusFile.writeAsString(jsonEncode(payload), flush: true);
    status.value = jsonEncode(payload);
    stderr.writeln('DEVICE ERROR: $error');
    if (stackTrace != null) stderr.writeln(stackTrace);
  }

  Future<void> close() async {
    _snapshotTimer?.cancel();
    await _events?.cancel();
    await _worker.close();
  }
}

final class _CrashDeviceApp extends StatelessWidget {
  const _CrashDeviceApp(this.harness);

  final _CrashDeviceHarness harness;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Sygnature 2-of-2 crash E2E')),
      body: Center(
        child: ValueListenableBuilder<String>(
          valueListenable: harness.status,
          builder: (_, value, _) => Padding(
            padding: const EdgeInsets.all(24),
            child: Text(value, textAlign: TextAlign.center),
          ),
        ),
      ),
    ),
  );
}
