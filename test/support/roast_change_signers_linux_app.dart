// Test-only Linux coordinator/requester for the real Change Signers E2E.
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

import 'roast_change_signers_common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadCoinlib();
  await NoosphereFlutter.initialize();
  await HiveStorageInitializer.initialize(
    boxName: 'sygnature_change_signers_linux_e2e',
  );
  final harness = _LinuxHarness();
  await harness.start();
  runApp(_LinuxApp(harness));
  unawaited(harness.readCommands());
}

final class _LinuxHarness {
  final status = ValueNotifier<String>('starting');

  late final NoosphereWorker _worker;
  late final EndpointAddr _oldCoordinator;
  late final EndpointAddr _successorCoordinator;
  final Set<String> _acceptedDkgs = {};
  final Set<String> _verifiedMessages = {};
  String? _oldGroupKey;
  String? _successorGroupKey;
  NewDkgDetails? _successorDkg;
  GroupTransitionProposal? _proposal;
  bool _successorStarted = false;
  String? _autoAcceptMessage;

  Future<void> start() async {
    _worker = await NoosphereWorker.start();
    _worker.events.listen(_handleEvent, onError: _fail);
    _oldCoordinator = await _startServer('old-server', oldGroup);
    _successorCoordinator = await _startServer(
      'successor-server',
      successorGroup,
    );
    final persistence = RoastPersistenceFactory(
      cipherKey: Uint8List.fromList(List<int>.filled(32, 1)),
    );
    await _worker.startSetup(
      setupId: oldSetupId,
      client: clientOptions(
        group: oldGroup,
        identifier: oldIds[0],
        identity: 1,
        coordinator: _oldCoordinator,
        storage: await openStorage(persistence, oldSetupId),
      ),
    );
    stdout.writeln(
      'COORDINATORS ${jsonEncode({'oldCoordinator': encodeEndpoint(_oldCoordinator), 'successorCoordinator': encodeEndpoint(_successorCoordinator)})}',
    );
    _setStatus('old-client-ready');
  }

  Future<EndpointAddr> _startServer(String setupId, GroupConfig group) async {
    final snapshot = await _worker.startSetup(
      setupId: setupId,
      server: EmbeddedServerOptions(
        serverConfig: ServerConfig(group: group),
        getIrohSecretKey: SecretKey.generate,
        serverPersistence: InMemoryServerPersistence(),
      ),
    );
    final address = snapshot.coordinator;
    if (address == null) throw StateError('$setupId has no coordinator.');
    return endpointFromWorker(address);
  }

  Future<void> _handleEvent(NoosphereWorkerEvent event) async {
    try {
      if (event is WorkerDkgEvent && event.status.stage == 'waiting') {
        final isReplacement = event.setupId == '$successorSetupId-p4';
        if (isReplacement) await _acceptDkg(event.setupId, event.status);
      } else if (event is WorkerKeyUpdatedEvent) {
        if (event.setupId == oldSetupId) {
          _oldGroupKey = event.key.groupKeyHex;
          stdout.writeln('OLD KEY READY ${event.key.groupKeyHex}');
        } else if (event.setupId.startsWith(successorSetupId)) {
          _successorGroupKey = event.key.groupKeyHex;
          stdout.writeln('SUCCESSOR KEY READY ${event.key.groupKeyHex}');
        }
      } else if (event is WorkerSigningRequestEvent &&
          event.setupId == '$successorSetupId-p1') {
        final details = event.request.decodeProposal();
        final metadata = details.metadata;
        if (metadata is MessageSignatureMetadata &&
            metadata.payload.text == _autoAcceptMessage) {
          _autoAcceptMessage = null;
          await _worker.acceptSignatures(event.setupId, event.request);
        }
      } else if (event is WorkerSigningResultEvent) {
        final signed = event.toSignedMessage();
        final verified = signed.verify();
        if (!verified) throw StateError('Invalid signature for ${signed.text}');
        if (_verifiedMessages.add(signed.text)) {
          stdout.writeln(
            'SIGNATURE VERIFIED setup=${event.setupId} text=${jsonEncode(signed.text)}',
          );
        }
      } else if (event is WorkerFailureEvent) {
        throw StateError('${event.operation}: ${event.message}');
      }
    } catch (error, stackTrace) {
      _fail(error, stackTrace);
    }
  }

  Future<void> _acceptDkg(String setupId, WorkerDkgStatus dkg) async {
    final token = '$setupId:${encodeBytes(dkg.proposalBytes)}';
    if (!_acceptedDkgs.add(token)) return;
    await _worker.acceptDkg(setupId, dkg);
  }

  Future<void> readCommands() async {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      try {
        if (line == 'old-dkg') {
          await _worker.requestDkg(
            oldSetupId,
            NewDkgDetails(
              name: oldKeyName,
              description: 'Initial cross-platform 2-of-3 group',
              threshold: 2,
              expiry: Expiry(const Duration(hours: 1)),
              groupFingerprint: oldGroup.fingerprint,
            ),
          );
          stdout.writeln('OLD DKG REQUESTED');
        } else if (line == 'sign-old-14') {
          await _requestMessage(oldSetupId, oldMessageWithAndroid14);
        } else if (line == 'sign-old-16') {
          await _requestMessage(oldSetupId, oldMessageWithAndroid16);
        } else if (line == 'proposal') {
          await _createProposal();
        } else if (line.startsWith('start-successor ')) {
          await _startSuccessor(line.substring('start-successor '.length));
        } else if (line == 'new-dkg') {
          await _worker.requestDkg(
            '$successorSetupId-p1',
            _successorDkg ??
                (throw StateError('Transition proposal is not ready.')),
          );
          stdout.writeln('SUCCESSOR DKG REQUESTED');
        } else if (line == 'sign-new-14') {
          await _requestMessage(
            '$successorSetupId-p4',
            successorMessageWithAndroid14,
          );
        } else if (line == 'sign-new-linux') {
          _autoAcceptMessage = successorMessageWithLinux;
          await _requestMessage(
            '$successorSetupId-p4',
            successorMessageWithLinux,
          );
        } else if (line == 'status') {
          stdout.writeln(
            'LINUX STATUS ${jsonEncode({'oldKey': _oldGroupKey, 'successorKey': _successorGroupKey, 'successorStarted': _successorStarted, 'verifiedMessages': _verifiedMessages.toList()..sort()})}',
          );
        } else if (line == 'quit') {
          await _worker.close();
          exit(0);
        }
      } catch (error, stackTrace) {
        _fail(error, stackTrace);
      }
    }
  }

  Future<void> _requestMessage(String setupId, String text) async {
    final snapshot = await _worker.snapshot(setupId);
    final key = snapshot.keys.single;
    await _worker.requestSignatures(
      setupId,
      SignaturesRequestDetails.forMessage(
        text: text,
        groupKey: ECCompressedPublicKey.fromHex(key.groupKeyHex),
        expiry: Expiry(const Duration(minutes: 5)),
      ),
    );
    stdout.writeln('SIGNING REQUESTED setup=$setupId text=${jsonEncode(text)}');
  }

  Future<void> _createProposal() async {
    final oldKey = _oldGroupKey;
    if (oldKey == null) throw StateError('Old DKG is not complete.');
    final now = DateTime.now().toUtc();
    final dkg = NewDkgDetails(
      name: successorKeyName,
      description: '2-of-3 successor replacing Android 16 with client 4',
      threshold: 2,
      expiry: Expiry.fromTime(now.add(const Duration(hours: 1))),
      groupFingerprint: successorGroup.fingerprint,
    );
    final proposal = GroupTransitionProposal(
      transitionId: 'change-signers-e2e-transition',
      sourceGroup: oldGroup,
      successorRoomId: successorGroupId,
      coordinatorEndpointId: _successorCoordinator.id.asBytes(),
      successorParticipants: successorGroup.participants.values,
      keyPlans: [
        GroupTransitionKeyPlan(
          keyId: oldKeyName,
          sourceGroupKey: ECCompressedPublicKey.fromHex(oldKey),
          sourceThreshold: 2,
          targetThreshold: 2,
          dkgDetailsHash: dkg.sigHash,
        ),
      ],
      migrationPolicy: GroupTransitionMigrationPolicy(
        kind: 'sygnature/change-signers-e2e',
        version: 1,
        payload: Uint8List.fromList(
          utf8.encode('replace participant 3 with 4'),
        ),
      ),
      createdAt: now,
      expiresAt: now.add(const Duration(hours: 1)),
    );
    final approval = GroupTransitionApproval.forProposal(
      proposal: proposal,
      participantPublicKey: ECCompressedPublicKey.fromPubkey(
        identityKeys[0].pubkey,
      ),
      approvedAt: now,
    ).sign(identityKeys[0]);
    _successorDkg = dkg;
    _proposal = proposal;
    stdout.writeln(
      'TRANSITION ${jsonEncode({'proposal': encodeBytes(proposal.toBytes()), 'successorDkg': encodeBytes(dkg.toBytes()), 'linuxApproval': encodeBytes(approval.toBytes())})}',
    );
  }

  Future<void> _startSuccessor(String encodedApproval) async {
    final proposal =
        _proposal ?? (throw StateError('Transition proposal is not ready.'));
    final approval = Signed<GroupTransitionApproval>.fromBytes(
      decodeBytes(encodedApproval),
      GroupTransitionApproval.fromReader,
    );
    if (!approval.obj.matchesProposal(proposal) ||
        !approval.verify(approval.obj.participantPublicKey) ||
        approval.obj.participantPublicKey !=
            ECCompressedPublicKey.fromPubkey(identityKeys[1].pubkey)) {
      throw StateError('Android 14 transition approval is invalid.');
    }
    if (_successorStarted) return;
    final persistence = RoastPersistenceFactory(
      cipherKey: Uint8List.fromList(List<int>.filled(32, 4)),
    );
    await _worker.startSetup(
      setupId: '$successorSetupId-p1',
      client: clientOptions(
        group: successorGroup,
        identifier: successorIds[0],
        identity: 1,
        coordinator: _successorCoordinator,
        storage: await openStorage(persistence, '$successorSetupId-p1'),
      ),
    );
    await _worker.startSetup(
      setupId: '$successorSetupId-p4',
      client: clientOptions(
        group: successorGroup,
        identifier: successorIds[2],
        identity: 4,
        coordinator: _successorCoordinator,
        storage: await openStorage(persistence, '$successorSetupId-p4'),
      ),
    );
    _successorStarted = true;
    stdout.writeln('TRANSITION APPROVALS VERIFIED count=2 threshold=2');
    stdout.writeln('REPLACEMENT CLIENT 4 STARTED');
    _setStatus('successor-clients-ready');
  }

  void _setStatus(String value) => status.value = value;

  void _fail(Object error, [StackTrace? stackTrace]) {
    stderr.writeln('LINUX ERROR: $error');
    if (stackTrace != null) stderr.writeln(stackTrace);
    _setStatus('error: $error');
  }
}

final class _LinuxApp extends StatelessWidget {
  const _LinuxApp(this.harness);

  final _LinuxHarness harness;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Sygnature Change Signers E2E')),
      body: Center(
        child: ValueListenableBuilder<String>(
          valueListenable: harness.status,
          builder: (_, value, _) => Text(value),
        ),
      ),
    ),
  );
}
