// Test-only Android participant for the real cross-device Change Signers E2E.
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

import 'roast_change_signers_common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadCoinlib();
  await NoosphereFlutter.initialize();
  await HiveStorageInitializer.initialize(
    boxName: 'sygnature_change_signers_device_e2e',
  );
  final directory = await getApplicationSupportDirectory();
  final config = Map<String, dynamic>.from(
    jsonDecode(
      await File('${directory.path}/change_signers_config.json').readAsString(),
    ) as Map,
  );
  final harness = _DeviceHarness(
    directory: directory,
    participant: config['participant'] as int,
    oldCoordinator: decodeEndpoint(config['oldCoordinator'] as String),
    successorCoordinator: decodeEndpoint(
      config['successorCoordinator'] as String,
    ),
  );
  await harness.start();
  runApp(_DeviceApp(harness));
}

final class _DeviceHarness({
  required this.directory,
  required this.participant,
  required this.oldCoordinator,
  required this.successorCoordinator,
}) {
  final Directory directory;
  final int participant;
  final EndpointAddr oldCoordinator;
  final EndpointAddr successorCoordinator;
  final status = ValueNotifier<String>('starting');

  late final NoosphereWorker _worker;
  final Set<String> _acceptedDkgs = {};
  final Set<String> _acceptedSignatures = {};
  final Set<String> _verifiedMessages = {};
  String? _oldGroupKey;
  String? _successorGroupKey;
  bool _successorStarted = false;
  bool _transitionValidated = false;
  bool _approvalWritten = false;
  String? _error;

  File get _controlFile =>
      File('${directory.path}/change_signers_control.json');
  File get _statusFile => File('${directory.path}/change_signers_status.json');
  File get _approvalFile =>
      File('${directory.path}/change_signers_approval.json');

  Future<void> start() async {
    if (participant != 2 && participant != 3) {
      throw ArgumentError.value(participant, 'participant');
    }
    _worker = await NoosphereWorker.start();
    _worker.events.listen(_handleEvent, onError: _fail);
    final persistence = RoastPersistenceFactory(
      cipherKey: Uint8List.fromList(List<int>.filled(32, participant)),
    );
    await _worker.startSetup(
      setupId: oldSetupId,
      client: clientOptions(
        group: oldGroup,
        identifier: oldIds[participant - 1],
        identity: participant,
        coordinator: oldCoordinator,
        storage: await openStorage(persistence, oldSetupId),
      ),
    );
    Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(_tick()),
    );
    await _writeStatus();
  }

  Future<void> _handleEvent(NoosphereWorkerEvent event) async {
    try {
      if (event is WorkerDkgEvent && event.status.stage == 'waiting') {
        await _acceptDkg(event.setupId, event.status);
      } else if (event is WorkerKeyUpdatedEvent) {
        if (event.setupId == oldSetupId) {
          _oldGroupKey = event.key.groupKeyHex;
        } else if (event.setupId == successorSetupId) {
          _successorGroupKey = event.key.groupKeyHex;
        }
      } else if (event is WorkerSigningRequestEvent) {
        await _acceptSignatureIfAllowed(event.setupId, event.request);
      } else if (event is WorkerSigningResultEvent) {
        final signed = event.toSignedMessage();
        if (!signed.verify()) {
          throw StateError(
            'Invalid signed message on participant $participant',
          );
        }
        _verifiedMessages.add(signed.text);
      } else if (event is WorkerFailureEvent) {
        throw StateError('${event.operation}: ${event.message}');
      }
      await _writeStatus();
    } catch (error, stackTrace) {
      await _fail(error, stackTrace);
    }
  }

  Future<Map<String, dynamic>> _control() async {
    if (!await _controlFile.exists()) return {};
    return Map<String, dynamic>.from(
      jsonDecode(await _controlFile.readAsString()) as Map,
    );
  }

  Future<void> _tick() async {
    try {
      final control = await _control();
      if (control['transitionProposal'] case final String encoded) {
        await _validateTransition(
          GroupTransitionProposal.fromBytes(decodeBytes(encoded)),
          successorDkg: NewDkgDetails.fromBytes(
            decodeBytes(control['successorDkg'] as String),
          ),
        );
      }
      if (participant == 2 &&
          control['startSuccessor'] == true &&
          !_successorStarted) {
        _successorStarted = true;
        final persistence = RoastPersistenceFactory(
          cipherKey: Uint8List.fromList(List<int>.filled(32, participant)),
        );
        await _worker.startSetup(
          setupId: successorSetupId,
          client: clientOptions(
            group: successorGroup,
            identifier: successorIds[1],
            identity: 2,
            coordinator: successorCoordinator,
            storage: await openStorage(persistence, successorSetupId),
          ),
        );
      }
      for (final setupId in [
        oldSetupId,
        if (_successorStarted) successorSetupId,
      ]) {
        final snapshot = await _worker.snapshot(setupId);
        for (final dkg in snapshot.dkgs.where(
          (item) => item.stage == 'waiting',
        )) {
          await _acceptDkg(setupId, dkg);
        }
        for (final request in snapshot.signingRequests.where(
          (item) => item.status == 'waiting',
        )) {
          await _acceptSignatureIfAllowed(setupId, request, control: control);
        }
      }
      await _writeStatus();
    } catch (error, stackTrace) {
      await _fail(error, stackTrace);
    }
  }

  Future<void> _acceptDkg(String setupId, WorkerDkgStatus dkg) async {
    final token = '$setupId:${encodeBytes(dkg.proposalBytes)}';
    if (!_acceptedDkgs.add(token)) return;
    if (setupId == successorSetupId) {
      final control = await _control();
      final proposal = GroupTransitionProposal.fromBytes(
        decodeBytes(control['transitionProposal'] as String),
      );
      if (!proposal.keyPlans.single.matchesDkgDetails(dkg.decodeProposal())) {
        throw StateError('Successor DKG is outside the approved key plan.');
      }
    }
    await _worker.acceptDkg(setupId, dkg);
  }

  Future<void> _acceptSignatureIfAllowed(
    String setupId,
    WorkerSigningRequest request, {
    Map<String, dynamic>? control,
  }) async {
    control ??= await _control();
    final details = request.decodeProposal();
    if (details.metadata is! MessageSignatureMetadata) return;
    final text = (details.metadata as MessageSignatureMetadata).payload.text;
    final allowed = (control['approveMessages'] as List? ?? const [])
        .cast<String>();
    if (!allowed.contains(text)) return;
    final token = '$setupId:${encodeBytes(request.id)}';
    if (!_acceptedSignatures.add(token)) return;
    await _worker.acceptSignatures(setupId, request);
  }

  Future<void> _validateTransition(
    GroupTransitionProposal proposal, {
    required NewDkgDetails successorDkg,
  }) async {
    if (_transitionValidated) return;
    final expectedRemoved = ECCompressedPublicKey.fromPubkey(
      identityKeys[2].pubkey,
    );
    final expectedAdded = ECCompressedPublicKey.fromPubkey(
      identityKeys[3].pubkey,
    );
    if (encodeBytes(proposal.sourceGroup.toBytes()) !=
            encodeBytes(oldGroup.toBytes()) ||
        proposal.successorRoomId != successorGroupId ||
        proposal.removedParticipants.single != expectedRemoved ||
        proposal.addedParticipants.single != expectedAdded ||
        proposal.keyPlans.single.sourceGroupKey.hex != _oldGroupKey ||
        !proposal.keyPlans.single.matchesDkgDetails(successorDkg)) {
      throw StateError(
        'Transition proposal does not match the reviewed replacement.',
      );
    }
    _transitionValidated = true;
    if (participant == 2 && !_approvalWritten) {
      final approval = GroupTransitionApproval.forProposal(
        proposal: proposal,
        participantPublicKey: ECCompressedPublicKey.fromPubkey(
          identityKeys[1].pubkey,
        ),
        approvedAt: DateTime.now().toUtc(),
      ).sign(identityKeys[1]);
      await _approvalFile.writeAsString(
        jsonEncode({'approval': encodeBytes(approval.toBytes())}),
        flush: true,
      );
      _approvalWritten = true;
    }
  }

  Future<void> _writeStatus() async {
    final value = <String, Object?>{
      'participant': participant,
      'oldKey': _oldGroupKey,
      'successorKey': _successorGroupKey,
      'successorStarted': _successorStarted,
      'transitionValidated': _transitionValidated,
      'approvalWritten': _approvalWritten,
      'verifiedMessages': _verifiedMessages.toList()..sort(),
      'error': _error,
    };
    status.value = jsonEncode(value);
    await _statusFile.writeAsString(status.value, flush: true);
  }

  Future<void> _fail(Object error, [StackTrace? stackTrace]) async {
    _error = '$error';
    stderr.writeln('DEVICE $participant ERROR: $error');
    if (stackTrace != null) stderr.writeln(stackTrace);
    await _writeStatus();
  }
}

final class _DeviceApp extends StatelessWidget {
  const _DeviceApp(this.harness);

  final _DeviceHarness harness;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: Text('Change Signers P${harness.participant}')),
      body: Center(
        child: ValueListenableBuilder<String>(
          valueListenable: harness.status,
          builder: (_, value, _) => Text(value, textAlign: TextAlign.center),
        ),
      ),
    ),
  );
}
