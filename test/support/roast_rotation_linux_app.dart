// Native Linux half of the cross-device coordinator-rotation harness. Uses
// only public deterministic test identities and an isolated application data
// directory supplied by the runner.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart';
import 'package:flutter/material.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';
import 'package:noosphere_server/testing.dart';
import 'package:sygnature_ng/storage/hive_storage_initializer.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';

import 'roast_rotation_common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadCoinlib();
  await NoosphereFlutter.initialize();
  await HiveStorageInitializer.initialize(
    boxName: 'sygnature_roast_rotation_linux_e2e',
  );
  final harness = _LinuxRotationHarness();
  await harness.start();
  runApp(_LinuxRotationApp(harness));
  unawaited(harness.readCommands());
}

final class _LinuxRotationHarness {
  final status = ValueNotifier<String>('Starting');

  late final NoosphereWorker _worker;
  WorkerSigningResultEvent? _result;
  StreamSubscription<NoosphereWorkerEvent>? _events;

  Future<void> start() async {
    _worker = await NoosphereWorker.start();
    _events = _worker.events.listen((event) {
      if (event is WorkerSigningResultEvent &&
          event.setupId == rotationSetupId) {
        _result = event;
        final signed = event.toSignedMessage();
        final verified = signed.text == rotationMessage && signed.verify();
        stdout.writeln('SIGNATURE VERIFIED: $verified');
        _setStatus('signature-verified=$verified');
      } else if (event is WorkerKeyUpdatedEvent &&
          event.setupId == rotationSetupId) {
        stdout.writeln('LINUX KEY READY');
        _setStatus('key-ready');
      }
    }, onError: _fail);

    final server = await _worker.startSetup(
      setupId: 'linux-coordinator',
      server: EmbeddedServerOptions(
        serverConfig: ServerConfig(group: rotationGroup),
        getIrohSecretKey: SecretKey.generate,
        serverPersistence: InMemoryServerPersistence(),
      ),
    );
    final published = server.coordinator;
    if (published == null) {
      throw StateError('Linux coordinator did not publish an address.');
    }
    final address = endpointFromWorker(published);
    final persistence = RoastPersistenceFactory(
      cipherKey: Uint8List.fromList(List<int>.filled(32, 1)),
    );
    final storage = (await persistence.open()).clientStorage(rotationSetupId);
    await _worker.startSetup(
      setupId: rotationSetupId,
      client: rotationClientOptions(
        participant: 1,
        coordinator: address,
        storage: storage,
      ),
    );
    stdout.writeln(
      'INITIAL_COORDINATOR ${jsonEncode({'coordinator': encodeEndpoint(address), 'id': address.id.toZ32()})}',
    );
    _setStatus('linux-coordinator-ready');
  }

  Future<void> readCommands() async {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      try {
        if (line == 'dkg') {
          await _worker.requestDkg(
            rotationSetupId,
            NewDkgDetails(
              name: rotationKeyName,
              description: 'Cross-platform coordinator rotation test',
              threshold: 2,
              expiry: Expiry(const Duration(hours: 1)),
            ),
          );
          stdout.writeln('DKG REQUESTED');
        } else if (line.startsWith('switch ')) {
          final address = decodeEndpoint(line.substring('switch '.length));
          final snapshot = await _worker.switchCoordinator(
            rotationSetupId,
            newCoordinator: address,
            persist: (_) async {},
          );
          stdout.writeln(
            'LINUX SWITCHED connected=${snapshot.connected} coordinator=${snapshot.coordinator?.id}',
          );
          _setStatus('linux-switched');
        } else if (line == 'stop-old') {
          await _worker.stopSetup('linux-coordinator');
          stdout.writeln('OLD COORDINATOR STOPPED');
          _setStatus('old-coordinator-stopped');
        } else if (line == 'sign') {
          _result = null;
          final snapshot = await _worker.snapshot(rotationSetupId);
          if (snapshot.keys.isEmpty) throw StateError('DKG key is not ready.');
          await _worker.requestSignatures(
            rotationSetupId,
            SignaturesRequestDetails.forMessage(
              text: rotationMessage,
              groupKey: ECCompressedPublicKey.fromHex(
                snapshot.keys.single.groupKeyHex,
              ),
              expiry: Expiry(const Duration(minutes: 5)),
            ),
          );
          stdout.writeln('SIGNING REQUESTED');
        } else if (line == 'status') {
          final snapshot = await _worker.snapshot(rotationSetupId);
          stdout.writeln(
            'LINUX STATUS connected=${snapshot.connected} keys=${snapshot.keys.length} peers=${snapshot.onlineParticipants.length} result=${_result != null}',
          );
        } else if (line == 'quit') {
          await close();
          exit(0);
        }
      } catch (error, stackTrace) {
        _fail(error, stackTrace);
      }
    }
  }

  void _setStatus(String value) {
    status.value = value;
  }

  void _fail(Object error, [StackTrace? stackTrace]) {
    stderr.writeln('LINUX ERROR: $error');
    if (stackTrace != null) stderr.writeln(stackTrace);
    _setStatus('error: $error');
  }

  Future<void> close() async {
    await _events?.cancel();
    await _worker.close();
  }
}

final class _LinuxRotationApp extends StatelessWidget {
  const _LinuxRotationApp(this.harness);

  final _LinuxRotationHarness harness;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Sygnature Linux ROAST E2E')),
      body: Center(
        child: ValueListenableBuilder<String>(
          valueListenable: harness.status,
          builder: (_, value, _) => Text(value),
        ),
      ),
    ),
  );
}
