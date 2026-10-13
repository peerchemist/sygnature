// Cross-device coordinator-rotation harness. This is built only with the
// dedicated verification application ID and uses public deterministic keys.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart';
import 'package:flutter/material.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:noosphere_server/testing.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sygnature_ng/storage/hive_storage_initializer.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';

import 'roast_rotation_common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadCoinlib();
  await NoosphereFlutter.initialize();
  await HiveStorageInitializer.initialize(
    boxName: 'sygnature_roast_rotation_e2e',
  );
  final directory = await getApplicationSupportDirectory();
  final config = Map<String, dynamic>.from(
    jsonDecode(
      await File('${directory.path}/rotation_device_config.json')
          .readAsString(),
    ) as Map,
  );
  final harness = _RotationDeviceHarness(
    directory: directory,
    participant: config['participant'] as int,
    initialCoordinator: decodeEndpoint(config['coordinator'] as String),
  );
  await harness.start();
  runApp(_RotationDeviceApp(harness));
}

final class _RotationDeviceHarness({
  required this.directory,
  required this.participant,
  required this.initialCoordinator,
}) {
  final Directory directory;
  final int participant;
  final EndpointAddr initialCoordinator;
  final status = ValueNotifier<String>('Starting');

  late final NoosphereWorker _worker;
  Timer? _commandTimer;
  bool _acceptingDkg = false;
  bool _acceptingSignature = false;
  bool _startingCoordinator = false;
  bool _switching = false;
  bool _switched = false;
  bool _keyReady = false;
  int _onlinePeers = 0;

  File get _statusFile => File('${directory.path}/rotation_status.json');
  File get _switchFile => File('${directory.path}/rotation_switch.json');
  File get _newCoordinatorFile =>
      File('${directory.path}/rotation_new_coordinator.json');

  Future<void> start() async {
    _worker = await NoosphereWorker.start();
    _worker.events.listen(_handleEvent, onError: _fail);
    final persistence = RoastPersistenceFactory(
      cipherKey: Uint8List.fromList(List<int>.filled(32, participant)),
    );
    final storage = (await persistence.open()).clientStorage(rotationSetupId);
    final snapshot = await _worker.startSetup(
      setupId: rotationSetupId,
      client: rotationClientOptions(
        participant: participant,
        coordinator: initialCoordinator,
        storage: storage,
      ),
    );
    await _recordSnapshot(snapshot, phase: 'connected');
    _commandTimer = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) => unawaited(_checkSwitch()),
    );
  }

  Future<void> _handleEvent(NoosphereWorkerEvent event) async {
    if (event.setupId != rotationSetupId) return;
    if (event is WorkerSnapshotEvent) {
      await _recordSnapshot(event.snapshot);
    } else if (event is WorkerParticipantEvent) {
      final snapshot = await _worker.snapshot(rotationSetupId);
      await _recordSnapshot(snapshot);
    } else if (event is WorkerDkgEvent &&
        event.status.stage == 'waiting' &&
        !_acceptingDkg) {
      _acceptingDkg = true;
      try {
        await _worker.acceptDkg(rotationSetupId, event.status);
        await _writeStatus(phase: 'dkg-accepted');
      } finally {
        _acceptingDkg = false;
      }
    } else if (event is WorkerKeyUpdatedEvent) {
      _keyReady = true;
      await _writeStatus(phase: 'key-ready');
      if (participant == 3) await _startReplacementCoordinator();
    } else if (event is WorkerSigningRequestEvent &&
        participant == 2 &&
        event.request.status == 'waiting' &&
        !_acceptingSignature) {
      _acceptingSignature = true;
      try {
        await _worker.acceptSignatures(rotationSetupId, event.request);
        await _writeStatus(phase: 'signature-approved');
      } finally {
        _acceptingSignature = false;
      }
    }
  }

  Future<void> _startReplacementCoordinator() async {
    if (_startingCoordinator) return;
    _startingCoordinator = true;
    try {
      final snapshot = await _worker.startSetup(
        setupId: 'android-coordinator',
        server: EmbeddedServerOptions(
          serverConfig: ServerConfig(group: rotationGroup),
          getIrohSecretKey: SecretKey.generate,
          serverPersistence: InMemoryServerPersistence(),
        ),
      );
      final published = snapshot.coordinator;
      if (published == null) {
        throw StateError('Replacement coordinator did not publish an address.');
      }
      final address = endpointFromWorker(published);
      await _newCoordinatorFile.writeAsString(
        jsonEncode({
          'coordinator': encodeEndpoint(address),
          'id': address.id.toZ32(),
        }),
        flush: true,
      );
      await _writeStatus(phase: 'replacement-ready');
    } catch (error, stackTrace) {
      await _fail(error, stackTrace);
    }
  }

  Future<void> _checkSwitch() async {
    if (_switched || _switching || !await _switchFile.exists()) return;
    _switching = true;
    try {
      final payload = Map<String, dynamic>.from(
        jsonDecode(await _switchFile.readAsString()) as Map,
      );
      final address = decodeEndpoint(payload['coordinator'] as String);
      final snapshot = await _worker.switchCoordinator(
        rotationSetupId,
        newCoordinator: address,
        persist: (_) =>
            File('${directory.path}/rotation_selected_coordinator.json')
                .writeAsString(jsonEncode(payload), flush: true),
      );
      _switched = true;
      await _recordSnapshot(snapshot, phase: 'switched');
    } catch (error, stackTrace) {
      await _fail(error, stackTrace);
    } finally {
      _switching = false;
    }
  }

  Future<void> _recordSnapshot(
    NoosphereWorkerSnapshot snapshot, {
    String? phase,
  }) async {
    _keyReady = snapshot.keys.isNotEmpty;
    _onlinePeers = snapshot.onlineParticipants.length;
    await _writeStatus(
      phase: phase ?? (_switched ? 'switched' : 'connected'),
      connected: snapshot.connected,
    );
  }

  Future<void> _writeStatus({
    required String phase,
    bool connected = true,
    String? error,
  }) async {
    final value = {
      'participant': participant,
      'phase': phase,
      'connected': connected,
      'keyReady': _keyReady,
      'onlinePeers': _onlinePeers,
      'error': error,
    };
    status.value = jsonEncode(value);
    await _statusFile.writeAsString(status.value, flush: true);
  }

  Future<void> _fail(Object error, [StackTrace? stackTrace]) async {
    stderr.writeln('DEVICE $participant ERROR: $error');
    if (stackTrace != null) stderr.writeln(stackTrace);
    await _writeStatus(phase: 'error', connected: false, error: '$error');
  }

  Future<void> close() async {
    _commandTimer?.cancel();
    await _worker.close();
    status.dispose();
  }
}

final class _RotationDeviceApp extends StatelessWidget {
  const _RotationDeviceApp(this.harness);

  final _RotationDeviceHarness harness;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: Text('ROAST participant ${harness.participant}')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ValueListenableBuilder<String>(
            valueListenable: harness.status,
            builder: (_, value, _) => Text(value, textAlign: TextAlign.center),
          ),
        ),
      ),
    ),
  );
}
