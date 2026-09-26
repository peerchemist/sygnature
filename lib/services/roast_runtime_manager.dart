import 'dart:async';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart' show TaprootKeySignDetails, bytesToHex;
import 'package:noosphere_flutter/noosphere_flutter.dart';

import '../models/roast_setup.dart';
import '../storage/roast_storage.dart';
import 'wallet_transaction_service.dart';

sealed class RoastRuntimeEvent {
  const RoastRuntimeEvent(this.setupId);

  final String setupId;
}

final class RoastRuntimeSnapshotEvent(
  super.setupId, {
  required final bool connected,
  required final bool signerRunning,
  required final List<String> onlineParticipantIds,
  required final String? coordinatorId,
  required final List<String> coordinatorRelayUrls,
  required final List<String> coordinatorIpAddrs,
}) extends RoastRuntimeEvent;

final class RoastRuntimeDkgEvent(
  super.setupId, {
  required final String proposalHex,
  required final String name,
  required final int threshold,
  required final String creator,
  required final DateTime expiry,
  required final String description,
  required final String stage,
  required final bool rejected,
  final String? failure,
}) extends RoastRuntimeEvent;

final class RoastRuntimeKeyEvent(
  super.setupId, {
  required final String groupKeyHex,
  required final String keyName,
  required final String description,
}) extends RoastRuntimeEvent;

final class RoastRuntimeFailureEvent(
  super.setupId, {
  required final String message,
  required final bool interrupted,
  required final String operation,
  final String? requestIdHex,
}) extends RoastRuntimeEvent;

class RoastSigningOutput({
  required final int valueSats,
  required final String scriptHex,
});

class RoastSigningRequest({
  required final String idHex,
  required final String proposalHex,
  required final String creator,
  required final DateTime expiry,
  required final bool hasTransactionMetadata,
  required final bool usesSupportedSighash,
  required final bool usesExpectedTaprootTweak,
  required final String status,
  required final int inputSats,
  required final int transactionInputCount,
  required final List<int> signedInputIndexes,
  required final List<String> previousOutputScripts,
  required final List<String> inputOutpoints,
  required final List<RoastSigningOutput> outputs,
  required final List<String> masterGroupKeys,
  required final List<List<int>> derivationPaths,
}) {
  int get outputSats =>
      outputs.fold(0, (sum, output) => sum + output.valueSats);
  int get feeSats => inputSats - outputSats;
}

final class RoastRuntimeSigningRequestEvent(
  super.setupId, {
  required final RoastSigningRequest request,
}) extends RoastRuntimeEvent;

final class RoastRuntimeSigningRequestRemovedEvent(
  super.setupId, {
  required final String requestIdHex,
}) extends RoastRuntimeEvent;

final class RoastRuntimeSigningResultEvent(
  super.setupId, {
  required final String requestIdHex,
  required final String proposalHex,
  required final List<Uint8List> signatures,
  required final String creator,
}) extends RoastRuntimeEvent;

class RoastRuntimeSnapshot({
  required final bool connected,
  required final bool signerRunning,
  required final List<String> onlineParticipantIds,
  required final String? coordinatorId,
  required final List<String> coordinatorRelayUrls,
  required final List<String> coordinatorIpAddrs,
  required final String? groupKeyHex,
  required final String? pendingDkgProposalHex,
  final String? pendingDkgStage,
  final String? pendingDkgName,
  final int? pendingDkgThreshold,
  final String? pendingDkgCreator,
  final DateTime? pendingDkgExpiry,
});

class RoastSigningProposal({
  required final String idHex,
  required final String proposalHex,
  required final DateTime expiry,
});

class RoastRoomInvite({
  required final String participantPublicKeyHex,
  required final String encoded,
  required final DateTime expiresAt,
});

class RoastRoomCreation({
  required final List<RoastRoomInvite> invites,
  required final String coordinatorId,
  required final List<String> coordinatorRelayUrls,
  required final List<String> coordinatorIpAddrs,
});

abstract interface class RoastRuntime {
  Stream<RoastRuntimeEvent> get events;

  Future<RoastRuntimeSnapshot> startSetup(RoastSetup setup);
  Future<RoastRoomCreation> createRoom(RoastSetup setup);
  Future<RoastRuntimeSnapshot> joinRoom(RoastSetup setup, String encodedInvite);
  Future<void> requestDkg(RoastSetup setup);
  Future<void> acceptDkg(String setupId, String proposalHex);
  Future<void> rejectDkg(String setupId, String proposalHex);
  RoastSigningProposal createTransactionSigningProposal(
    RoastSetup setup,
    ThresholdWalletTransaction transaction,
    List<int> derivationPath,
  );
  Future<void> requestTransactionSignatures(
    RoastSetup setup,
    RoastSigningProposal proposal,
  );
  Future<void> acceptSignatures(String setupId, String requestIdHex);
  Future<void> rejectSignatures(String setupId, String requestIdHex);
  Future<void> stopSetup(String setupId);
  Future<void> deleteSetup(String setupId);
  Future<void> close();
}

final class RoastRuntimeManager(RoastPersistenceFactory persistenceFactory)
    implements RoastRuntime {
  final RoastPersistenceFactory _persistenceFactory = persistenceFactory;
  final StreamController<RoastRuntimeEvent> _events =
      StreamController<RoastRuntimeEvent>.broadcast();
  final Map<String, WorkerDkgStatus> _dkgProposals = {};
  final Map<String, WorkerSigningRequest> _signingRequests = {};
  final Map<String, RoastSetup> _setups = {};
  final Map<String, String> _emittedGroupKeys = {};
  final Set<String> _serverSetups = {};
  final Set<String> _signerSetups = {};
  final Map<String, NoosphereNode> _roomServers = {};
  final Map<String, StreamSubscription<RoomSnapshot>> _roomSubscriptions = {};
  final Set<String> _freezingRooms = {};
  final Map<String, Timer> _roomSignerTimers = {};
  final Set<String> _connectingRoomSigners = {};
  final Map<String, Timer> _keyReadinessTimers = {};
  NoosphereWorker? _worker;
  StreamSubscription<NoosphereWorkerEvent>? _workerEvents;

  @override
  Stream<RoastRuntimeEvent> get events => _events.stream;

  Future<NoosphereWorker> _ensureWorker() async {
    final existing = _worker;
    if (existing != null && !existing.isClosed) return existing;
    await _workerEvents?.cancel();
    _workerEvents = null;
    final worker = await NoosphereWorker.start();
    _serverSetups.clear();
    _signerSetups.clear();
    for (final timer in _keyReadinessTimers.values) {
      timer.cancel();
    }
    _keyReadinessTimers.clear();
    _worker = worker;
    _workerEvents = worker.events.listen(
      _onWorkerEvent,
      onError: (Object error) {
        if (!_events.isClosed) {
          _events.addError(StateError('ROAST worker stream failed: $error'));
        }
      },
    );
    return worker;
  }

  @override
  Future<RoastRuntimeSnapshot> startSetup(RoastSetup setup) =>
      _startSetup(setup, scheduleRoomRetry: true);

  Future<RoastRuntimeSnapshot> _startSetup(
    RoastSetup setup, {
    required bool scheduleRoomRetry,
  }) async {
    if (!setup.isFinalized) {
      throw StateError('Finalize the participant roster before connecting.');
    }
    _setups[setup.id] = setup;
    final persistence = await _persistenceFactory.open();
    final group = _group(setup);
    final fingerprint = bytesToHex(group.fingerprint);
    if (setup.groupFingerprintHex case final expected?
        when expected != fingerprint) {
      throw StateError('The stored ROAST group fingerprint does not match.');
    }

    NoosphereWorkerSnapshot? serverSnapshot;
    WorkerCoordinatorAddress? roomCoordinator;
    if (setup.role == RoastSetupRole.host && setup.usesRoomEnrollment) {
      final server = await _ensureRoomServer(setup);
      final room = await server.server!.getRoom(setup.groupId);
      roomCoordinator = _coordinator(server.server!.address);
      if (room.lifecycle != RoomLifecycle.frozen) {
        return RoastRuntimeSnapshot(
          connected: false,
          signerRunning: false,
          onlineParticipantIds: const [],
          coordinatorId: roomCoordinator.id,
          coordinatorRelayUrls: roomCoordinator.relayUrls,
          coordinatorIpAddrs: roomCoordinator.ipAddrs,
          groupKeyHex: null,
          pendingDkgProposalHex: null,
        );
      }
    }
    final worker = await _ensureWorker();
    if (setup.role == RoastSetupRole.host &&
        !setup.usesRoomEnrollment &&
        !_serverSetups.contains(setup.id)) {
      serverSnapshot = await worker.startSetup(
        setupId: setup.id,
        identityStorageId: 'sygnature:${setup.id}',
        server: EmbeddedServerOptions(
          serverConfig: ServerConfig(group: group),
          identityStore: persistence.serverIdentity(setup.id),
        ),
      );
      _serverSetups.add(setup.id);
    } else if (_serverSetups.contains(setup.id)) {
      serverSnapshot = await worker.snapshot(setup.id);
    }

    final coordinator = roomCoordinator ?? serverSnapshot?.coordinator;
    final coordinatorId = setup.role == RoastSetupRole.host
        ? coordinator?.id
        : setup.coordinatorId;
    if (coordinatorId == null) {
      throw StateError('The coordinator did not publish an Iroh identity.');
    }
    final relayUrls = setup.role == RoastSetupRole.host
        ? coordinator?.relayUrls ?? const <String>[]
        : setup.coordinatorRelayUrls;
    final ipAddrs = setup.role == RoastSetupRole.host
        ? coordinator?.ipAddrs ?? const <String>[]
        : setup.coordinatorIpAddrs;
    final pinnedId = PublicKey.fromZ32(coordinatorId);
    final address = EndpointAddr(
      pinnedId,
      relayUrls: [for (final value in relayUrls) RelayUrl.parse(value)],
      ipAddrs: ipAddrs,
    );
    final privateKey = ECPrivateKey.fromHex(
      setup.localParticipantPrivateKeyHex,
    );
    late final NoosphereWorkerSnapshot snapshot;
    try {
      snapshot = _signerSetups.contains(setup.id)
          ? await worker.snapshot(setup.id)
          : await worker.startSetup(
              setupId: setup.id,
              client: ClientNodeOptions(
                clientConfig: ClientConfig(
                  group: group,
                  id: Identifier.fromHex(setup.localParticipant.identifierHex),
                ),
                bootstrapAddress: address,
                pinnedServerId: pinnedId,
                storage: persistence.clientStorage(setup.id),
                getPrivateKey: (_) async => privateKey,
              ),
            );
    } on Object {
      if (scheduleRoomRetry &&
          setup.role == RoastSetupRole.member &&
          setup.usesRoomEnrollment) {
        _scheduleRoomSignerConnection(setup);
        return _pendingRoomSnapshot(setup);
      }
      rethrow;
    }
    _signerSetups.add(setup.id);
    return _snapshot(snapshot, setup);
  }

  @override
  Future<RoastRoomCreation> createRoom(RoastSetup setup) async {
    if (setup.role != RoastSetupRole.host || !setup.isFinalized) {
      throw StateError('Only a host with a complete roster can create a room.');
    }
    _setups[setup.id] = setup;
    final node = await _ensureRoomServer(setup);
    final server = node.server!;
    await server.createRoom(
      roomId: setup.groupId,
      expectedParticipants: setup.participantCount,
      threshold: setup.threshold,
    );
    final privateKey = ECPrivateKey.fromHex(
      setup.localParticipantPrivateKeyHex,
    );
    final issued = <RoastRoomInvite>[];
    for (final participant in setup.participants) {
      final invite = await server.issueRoomInvite(
        roomId: setup.groupId,
        expectedParticipantPublicKey: ECCompressedPublicKey.fromHex(
          participant.publicKeyHex,
        ),
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 7)),
      );
      if (participant.cardId == setup.localCardId) {
        await _joinRoomInvite(invite, privateKey);
      } else {
        issued.add(
          RoastRoomInvite(
            participantPublicKeyHex: participant.publicKeyHex,
            encoded: invite.encode(),
            expiresAt: invite.expiresAt,
          ),
        );
      }
    }
    final coordinator = _coordinator(server.address);
    return RoastRoomCreation(
      invites: issued,
      coordinatorId: coordinator.id,
      coordinatorRelayUrls: coordinator.relayUrls,
      coordinatorIpAddrs: coordinator.ipAddrs,
    );
  }

  @override
  Future<RoastRuntimeSnapshot> joinRoom(
    RoastSetup setup,
    String encodedInvite,
  ) async {
    final invite = RoomInvite.decode(encodedInvite);
    if (invite.roomId != setup.groupId ||
        invite.expectedParticipantPublicKey.hex !=
            setup.localParticipant.publicKeyHex ||
        bytesToHex(invite.coordinatorEndpointId) !=
            bytesToHex(PublicKey.fromZ32(setup.coordinatorId!).asBytes())) {
      throw const FormatException(
        'The room invite does not match this participant setup.',
      );
    }
    final privateKey = ECPrivateKey.fromHex(
      setup.localParticipantPrivateKeyHex,
    );
    invite.requirePrivateKey(privateKey);
    await _joinRoomInvite(invite, privateKey);
    _setups[setup.id] = setup;
    _scheduleRoomSignerConnection(setup);
    return _pendingRoomSnapshot(setup);
  }

  static RoastRuntimeSnapshot _pendingRoomSnapshot(RoastSetup setup) =>
      RoastRuntimeSnapshot(
        connected: false,
        signerRunning: false,
        onlineParticipantIds: const [],
        coordinatorId: setup.coordinatorId,
        coordinatorRelayUrls: setup.coordinatorRelayUrls,
        coordinatorIpAddrs: setup.coordinatorIpAddrs,
        groupKeyHex: null,
        pendingDkgProposalHex: null,
      );

  void _scheduleRoomSignerConnection(RoastSetup setup) {
    if (_roomSignerTimers.containsKey(setup.id)) return;
    unawaited(_connectRoomSigner(setup));
    _roomSignerTimers[setup.id] = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_connectRoomSigner(setup)),
    );
  }

  Future<void> _connectRoomSigner(RoastSetup setup) async {
    if (!_connectingRoomSigners.add(setup.id)) return;
    try {
      final snapshot = await _startSetup(setup, scheduleRoomRetry: false);
      _roomSignerTimers.remove(setup.id)?.cancel();
      _emitSnapshotValues(setup.id, snapshot);
    } on Object {
      // The ordinary ROAST group becomes available only after the host freezes
      // the full room. Retry quietly while enrollment is still in progress.
    } finally {
      _connectingRoomSigners.remove(setup.id);
    }
  }

  Future<NoosphereNode> _ensureRoomServer(RoastSetup setup) async {
    final existing = _roomServers[setup.id];
    if (existing != null) return existing;
    final persistence = await _persistenceFactory.open();
    final node = await NoosphereNode.start(
      server: EmbeddedServerOptions(
        serverConfig: ServerConfig(group: _bootstrapGroup(setup.groupId)),
        identityStore: persistence.serverIdentity(setup.id),
        roomPersistence: persistence.roomPersistence(setup.id),
      ),
    );
    _roomServers[setup.id] = node;
    _roomSubscriptions[setup.id] = node.server!.rooms!.snapshots.listen(
      (room) => _onRoomSnapshot(setup.id, room),
      onError: (Object error) => _emitRoomFailure(setup.id, error),
    );
    for (final room in await node.server!.rooms!.getRooms()) {
      _onRoomSnapshot(setup.id, room);
    }
    return node;
  }

  void _onRoomSnapshot(String setupId, RoomSnapshot room) {
    if (room.lifecycle != RoomLifecycle.enrolling ||
        !room.isFull ||
        !_freezingRooms.add(setupId)) {
      return;
    }
    unawaited(_freezeRoomAndStartSigner(setupId));
  }

  Future<void> _freezeRoomAndStartSigner(String setupId) async {
    try {
      final setup = _setups[setupId];
      final server = _roomServers[setupId]?.server;
      if (setup == null || server == null) return;
      final frozen = await server.freezeRoom(setup.groupId);
      final expected = _group(setup);
      if (bytesToHex(frozen.groupFingerprint!) !=
          bytesToHex(expected.fingerprint)) {
        throw StateError('The frozen room roster does not match the setup.');
      }
      final snapshot = await startSetup(setup);
      _emitSnapshotValues(setupId, snapshot);
    } catch (error) {
      _emitRoomFailure(setupId, error);
    } finally {
      _freezingRooms.remove(setupId);
    }
  }

  void _emitRoomFailure(String setupId, Object error) {
    if (_events.isClosed) return;
    _events.add(
      RoastRuntimeFailureEvent(
        setupId,
        message: 'ROAST room failed: $error',
        interrupted: true,
        operation: 'room',
      ),
    );
  }

  void _emitSnapshotValues(String setupId, RoastRuntimeSnapshot snapshot) {
    if (_events.isClosed) return;
    _events.add(
      RoastRuntimeSnapshotEvent(
        setupId,
        connected: snapshot.connected,
        signerRunning: snapshot.signerRunning,
        onlineParticipantIds: snapshot.onlineParticipantIds,
        coordinatorId: snapshot.coordinatorId,
        coordinatorRelayUrls: snapshot.coordinatorRelayUrls,
        coordinatorIpAddrs: snapshot.coordinatorIpAddrs,
      ),
    );
  }

  static Future<RoomSnapshot> _joinRoomInvite(
    RoomInvite invite,
    ECPrivateKey privateKey,
  ) {
    final endpointId = PublicKey.fromBytes(invite.coordinatorEndpointId);
    return IrohRoomEnrollmentApi.joinRoom(
      IrohClientTransportConfig(
        bootstrapAddress: EndpointAddr(
          endpointId,
          relayUrls: [for (final url in invite.relayUrls) RelayUrl.parse(url)],
          ipAddrs: invite.ipAddrs,
        ),
        pinnedServerId: endpointId,
      ),
      invite,
      (_) async => privateKey,
    );
  }

  static WorkerCoordinatorAddress _coordinator(EndpointAddr address) =>
      WorkerCoordinatorAddress(
        id: address.id.toString(),
        relayUrls: [for (final relay in address.relayUrls) relay.value],
        ipAddrs: address.ipAddrs,
      );

  @override
  Future<void> requestDkg(RoastSetup setup) async {
    final worker = await _ensureWorker();
    await worker.requestDkg(
      setup.id,
      NewDkgDetails(
        name: setup.keyName,
        description: roastKeyDescription(setup),
        threshold: setup.threshold,
        expiry: Expiry(const Duration(hours: 24)),
      ),
    );
  }

  @override
  Future<void> acceptDkg(String setupId, String proposalHex) async {
    final proposal = _dkgProposals['$setupId:$proposalHex'];
    if (proposal == null) {
      throw StateError('The DKG proposal is no longer available.');
    }
    await (await _ensureWorker()).acceptDkg(setupId, proposal);
  }

  @override
  Future<void> rejectDkg(String setupId, String proposalHex) async {
    final proposal = _dkgProposals['$setupId:$proposalHex'];
    if (proposal == null) {
      throw StateError('The DKG proposal is no longer available.');
    }
    await (await _ensureWorker()).rejectDkg(setupId, proposal);
  }

  @override
  RoastSigningProposal createTransactionSigningProposal(
    RoastSetup setup,
    ThresholdWalletTransaction transaction,
    List<int> derivationPath,
  ) {
    final groupKeyHex = setup.groupKeyHex;
    if (groupKeyHex == null) {
      throw StateError('The shared key is not available.');
    }
    final details = SignaturesRequestDetails(
      requiredSigs: [
        for (final hash in transaction.signatureHashes)
          SingleSignatureDetails(
            signDetails: SignDetails.keySpend(message: hash),
            groupKey: ECCompressedPublicKey.fromHex(groupKeyHex),
            hdDerivation: derivationPath,
          ),
      ],
      metadata: TaprootTransactionSignatureMetadata(
        transaction: transaction.transaction,
        signDetails: transaction.signDetails,
      ),
      expiry: Expiry(const Duration(minutes: 5)),
    );
    return RoastSigningProposal(
      idHex: bytesToHex(details.id.toBytes()),
      proposalHex: bytesToHex(details.toBytes()),
      expiry: details.expiry.time,
    );
  }

  @override
  Future<void> requestTransactionSignatures(
    RoastSetup setup,
    RoastSigningProposal proposal,
  ) async {
    final details = SignaturesRequestDetails.fromHex(proposal.proposalHex);
    if (bytesToHex(details.id.toBytes()) != proposal.idHex ||
        details.expiry.time != proposal.expiry ||
        details.requiredSigs.any(
          (signature) => signature.groupKey.hex != setup.groupKeyHex,
        )) {
      throw StateError('The persisted ROAST signing proposal is invalid.');
    }
    await (await _ensureWorker()).requestSignatures(setup.id, details);
  }

  @override
  Future<void> acceptSignatures(String setupId, String requestIdHex) async {
    final request = _signingRequests['$setupId:$requestIdHex'];
    if (request == null || request.status != 'waiting') {
      throw StateError('The signing request is no longer available.');
    }
    await (await _ensureWorker()).acceptSignatures(setupId, request);
  }

  @override
  Future<void> rejectSignatures(String setupId, String requestIdHex) async {
    final request = _signingRequests['$setupId:$requestIdHex'];
    if (request == null || request.status != 'waiting') {
      throw StateError('The signing request is no longer available.');
    }
    await (await _ensureWorker()).rejectSignatures(setupId, request);
  }

  @override
  Future<void> stopSetup(String setupId) async {
    _setups.remove(setupId);
    _emittedGroupKeys.remove(setupId);
    _serverSetups.remove(setupId);
    _signerSetups.remove(setupId);
    _keyReadinessTimers.remove(setupId)?.cancel();
    await _roomSubscriptions.remove(setupId)?.cancel();
    await _roomServers.remove(setupId)?.close();
    _freezingRooms.remove(setupId);
    _roomSignerTimers.remove(setupId)?.cancel();
    _connectingRoomSigners.remove(setupId);
    final worker = _worker;
    if (worker == null || worker.isClosed) return;
    await worker.stopSetup(setupId);
  }

  @override
  Future<void> deleteSetup(String setupId) async {
    await stopSetup(setupId);
    await _persistenceFactory.deleteSetupData(setupId);
  }

  void _onWorkerEvent(NoosphereWorkerEvent event) {
    switch (event) {
      case WorkerSnapshotEvent():
        _rememberDkgs(event.snapshot);
        _rememberSigningRequests(event.snapshot);
        _emitSnapshot(event.snapshot);
        unawaited(_rememberExpectedKeySafely(event.snapshot));
      case WorkerDkgEvent():
        final proposalHex = bytesToHex(event.status.proposalBytes);
        _dkgProposals['${event.setupId}:$proposalHex'] = event.status;
        _events.add(
          RoastRuntimeDkgEvent(
            event.setupId,
            proposalHex: proposalHex,
            name: event.status.name,
            threshold: event.status.threshold,
            creator: event.status.creator,
            expiry: event.status.expiry,
            description: event.status.description,
            stage: event.status.stage,
            rejected: event.rejected,
            failure: event.failure,
          ),
        );
      case WorkerKeyUpdatedEvent():
        unawaited(_refresh(event.setupId));
      case WorkerFailureEvent():
        _events.add(
          RoastRuntimeFailureEvent(
            event.setupId,
            message: event.message,
            interrupted: event.interrupted,
            operation: event.operation,
          ),
        );
        unawaited(_refresh(event.setupId));
      case WorkerParticipantEvent() || WorkerSessionReplacedEvent():
        unawaited(_refresh(event.setupId));
      case WorkerSigningRequestEvent():
        _emitSigningRequest(event.setupId, event.request);
      case WorkerSigningResultEvent():
        unawaited(_persistAndEmitSigningResult(event));
    }
  }

  Future<void> _persistAndEmitSigningResult(
    WorkerSigningResultEvent event,
  ) async {
    final requestIdHex = bytesToHex(event.requestId);
    final proposalHex = bytesToHex(event.proposalBytes);
    final setup = _setups[event.setupId];
    try {
      if (setup != null &&
          event.creator == setup.localParticipant.identifierHex) {
        await _persistenceFactory.recordSigningResult(
          '${event.setupId}:$requestIdHex',
          proposalHex: proposalHex,
          signaturesHex: [
            for (final signature in event.signatures) bytesToHex(signature),
          ],
        );
      }
      if (!_events.isClosed) {
        _events.add(
          RoastRuntimeSigningResultEvent(
            event.setupId,
            requestIdHex: requestIdHex,
            proposalHex: proposalHex,
            signatures: event.signatures,
            creator: event.creator,
          ),
        );
      }
    } catch (error) {
      if (!_events.isClosed) {
        _events.add(
          RoastRuntimeFailureEvent(
            event.setupId,
            message: 'Unable to persist completed ROAST signatures: $error',
            interrupted: false,
            operation: 'signingPersistence',
            requestIdHex: requestIdHex,
          ),
        );
      }
    }
  }

  Future<void> _refresh(String setupId) async {
    final worker = _worker;
    if (worker == null || worker.isClosed) return;
    try {
      final snapshot = await worker.snapshot(setupId);
      _rememberDkgs(snapshot);
      _rememberSigningRequests(snapshot);
      _emitSnapshot(snapshot);
      await _rememberExpectedKey(snapshot);
    } on Object {
      // A concurrent stop legitimately makes this refresh stale.
    }
  }

  Future<void> _rememberExpectedKeySafely(
    NoosphereWorkerSnapshot snapshot,
  ) async {
    try {
      await _rememberExpectedKey(snapshot);
    } on Object catch (error) {
      if (!_events.isClosed) {
        _events.add(
          RoastRuntimeFailureEvent(
            snapshot.setupId,
            message: 'Unable to verify ROAST key readiness: $error',
            interrupted: true,
            operation: 'keyReadiness',
          ),
        );
      }
    }
  }

  Future<void> _rememberExpectedKey(NoosphereWorkerSnapshot snapshot) async {
    final setup = _setups[snapshot.setupId];
    if (setup == null) return;
    final expectedDescription = roastKeyDescription(setup);
    final keys = snapshot.keys
        .where(
          (key) =>
              key.name == setup.keyName &&
              key.description == expectedDescription,
        )
        .toList(growable: false);
    if (keys.length > 1) {
      _events.add(
        RoastRuntimeFailureEvent(
          snapshot.setupId,
          message: 'Multiple local ROAST keys use the expected key name.',
          interrupted: true,
          operation: 'keyReadiness',
        ),
      );
      return;
    }
    if (keys.isEmpty ||
        _emittedGroupKeys[snapshot.setupId] == keys.single.groupKeyHex) {
      return;
    }
    final key = keys.single;
    if (!await _hasAllKeyAcknowledgements(setup, key.groupKeyHex)) {
      _scheduleKeyReadinessPoll(setup.id);
      return;
    }
    _keyReadinessTimers.remove(setup.id)?.cancel();
    _emittedGroupKeys[snapshot.setupId] = key.groupKeyHex;
    _events.add(
      RoastRuntimeKeyEvent(
        snapshot.setupId,
        groupKeyHex: key.groupKeyHex,
        keyName: key.name,
        description: key.description,
      ),
    );
  }

  Future<bool> _hasAllKeyAcknowledgements(
    RoastSetup setup,
    String groupKeyHex,
  ) async {
    final persistence = await _persistenceFactory.open();
    final keys = await persistence.clientStorage(setup.id).loadKeys();
    final matching = keys
        .where(
          (key) =>
              key.name == setup.keyName &&
              key.description == roastKeyDescription(setup) &&
              key.groupKey.hex == groupKeyHex,
        )
        .toList(growable: false);
    if (matching.length > 1) {
      throw StateError('Multiple persisted ROAST keys match this setup.');
    }
    return (matching.singleOrNull?.acceptedAcks ?? 0) >= setup.participantCount;
  }

  void _scheduleKeyReadinessPoll(String setupId) {
    if (_keyReadinessTimers.containsKey(setupId)) return;
    _keyReadinessTimers[setupId] = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => unawaited(_refresh(setupId)),
    );
  }

  void _rememberDkgs(NoosphereWorkerSnapshot snapshot) {
    for (final proposal in snapshot.dkgs) {
      final proposalHex = bytesToHex(proposal.proposalBytes);
      _dkgProposals['${snapshot.setupId}:$proposalHex'] = proposal;
      _events.add(
        RoastRuntimeDkgEvent(
          snapshot.setupId,
          proposalHex: proposalHex,
          name: proposal.name,
          threshold: proposal.threshold,
          creator: proposal.creator,
          expiry: proposal.expiry,
          description: proposal.description,
          stage: proposal.stage,
          rejected: false,
        ),
      );
    }
  }

  void _rememberSigningRequests(NoosphereWorkerSnapshot snapshot) {
    final prefix = '${snapshot.setupId}:';
    final currentIds = {
      for (final request in snapshot.signingRequests) bytesToHex(request.id),
    };
    final removed = _signingRequests.keys
        .where(
          (key) =>
              key.startsWith(prefix) &&
              !currentIds.contains(key.substring(prefix.length)),
        )
        .toList(growable: false);
    for (final key in removed) {
      _signingRequests.remove(key);
      _events.add(
        RoastRuntimeSigningRequestRemovedEvent(
          snapshot.setupId,
          requestIdHex: key.substring(prefix.length),
        ),
      );
    }
    for (final request in snapshot.signingRequests) {
      _emitSigningRequest(snapshot.setupId, request);
    }
  }

  void _emitSigningRequest(String setupId, WorkerSigningRequest request) {
    final idHex = bytesToHex(request.id);
    _signingRequests['$setupId:$idHex'] = request;
    final proposal = request.decodeProposal();
    final metadata = proposal.metadata;
    var inputSats = 0;
    var transactionInputCount = 0;
    var usesSupportedSighash = false;
    final usesExpectedTaprootTweak = proposal.requiredSigs.every(
      (signature) => signature.signDetails.mastHash?.isEmpty == true,
    );
    var signedInputIndexes = const <int>[];
    var previousOutputScripts = const <String>[];
    var inputOutpoints = const <String>[];
    var outputs = const <RoastSigningOutput>[];
    final hasTransactionMetadata =
        metadata is TaprootTransactionSignatureMetadata;
    if (metadata is TaprootTransactionSignatureMetadata) {
      transactionInputCount = metadata.transaction.inputs.length;
      inputOutpoints = [
        for (final input in metadata.transaction.inputs)
          '${bytesToHex(Uint8List.fromList(input.prevOut.hash.reversed.toList()))}:${input.prevOut.n}',
      ];
      usesSupportedSighash = metadata.signDetails.every(
        (details) =>
            details is TaprootKeySignDetails && details.hashType.schnorrDefault,
      );
      signedInputIndexes = [
        for (final details in metadata.signDetails) details.inputN,
      ];
      final previousOutputSets = metadata.signDetails
          .where((details) => details.prevOuts.isNotEmpty)
          .map((details) => details.prevOuts)
          .toList();
      if (previousOutputSets.isNotEmpty) {
        final previousOutputs = previousOutputSets.reduce(
          (first, next) => first.length >= next.length ? first : next,
        );
        inputSats = previousOutputs.fold(
          0,
          (sum, output) => sum + output.value.toInt(),
        );
        previousOutputScripts = [
          for (final output in previousOutputs) bytesToHex(output.scriptPubKey),
        ];
      }
      outputs = [
        for (final output in metadata.transaction.outputs)
          RoastSigningOutput(
            valueSats: output.value.toInt(),
            scriptHex: bytesToHex(output.scriptPubKey),
          ),
      ];
    }
    _events.add(
      RoastRuntimeSigningRequestEvent(
        setupId,
        request: RoastSigningRequest(
          idHex: idHex,
          proposalHex: bytesToHex(request.proposalBytes),
          creator: request.creator,
          expiry: request.expiry,
          hasTransactionMetadata: hasTransactionMetadata,
          usesSupportedSighash: usesSupportedSighash,
          usesExpectedTaprootTweak: usesExpectedTaprootTweak,
          status: request.status,
          inputSats: inputSats,
          transactionInputCount: transactionInputCount,
          signedInputIndexes: signedInputIndexes,
          previousOutputScripts: previousOutputScripts,
          inputOutpoints: inputOutpoints,
          outputs: outputs,
          masterGroupKeys: [
            for (final signature in proposal.requiredSigs)
              signature.groupKey.hex,
          ],
          derivationPaths: [
            for (final signature in proposal.requiredSigs)
              List.unmodifiable(signature.hdDerivation),
          ],
        ),
      ),
    );
  }

  void _emitSnapshot(NoosphereWorkerSnapshot snapshot) {
    final coordinator = snapshot.coordinator;
    _events.add(
      RoastRuntimeSnapshotEvent(
        snapshot.setupId,
        connected: snapshot.connected,
        signerRunning: snapshot.signerRunning,
        onlineParticipantIds: snapshot.onlineParticipants,
        coordinatorId: coordinator?.id,
        coordinatorRelayUrls: coordinator?.relayUrls ?? const [],
        coordinatorIpAddrs: coordinator?.ipAddrs ?? const [],
      ),
    );
  }

  Future<RoastRuntimeSnapshot> _snapshot(
    NoosphereWorkerSnapshot snapshot,
    RoastSetup setup,
  ) async {
    _rememberDkgs(snapshot);
    final coordinator = snapshot.coordinator;
    final matchingKeys = snapshot.keys
        .where(
          (key) =>
              key.name == setup.keyName &&
              key.description == roastKeyDescription(setup),
        )
        .toList(growable: false);
    if (matchingKeys.length > 1) {
      throw StateError('Multiple local ROAST keys use the expected key name.');
    }
    final matchingDkgs = snapshot.dkgs
        .where((status) => _dkgMatchesSetup(status, setup))
        .toList(growable: false);
    final matchingKey = matchingKeys.firstOrNull;
    final readyGroupKey =
        matchingKey != null &&
            await _hasAllKeyAcknowledgements(setup, matchingKey.groupKeyHex)
        ? matchingKey.groupKeyHex
        : null;
    if (matchingKey != null && readyGroupKey == null) {
      _scheduleKeyReadinessPoll(setup.id);
    }
    final matchingDkg = matchingDkgs.firstOrNull;
    return RoastRuntimeSnapshot(
      connected: snapshot.connected,
      signerRunning: snapshot.signerRunning,
      onlineParticipantIds: snapshot.onlineParticipants,
      coordinatorId: coordinator?.id,
      coordinatorRelayUrls: coordinator?.relayUrls ?? const [],
      coordinatorIpAddrs: coordinator?.ipAddrs ?? const [],
      groupKeyHex: readyGroupKey,
      pendingDkgProposalHex: matchingDkg == null
          ? null
          : bytesToHex(matchingDkg.proposalBytes),
      pendingDkgStage: matchingDkg?.stage,
      pendingDkgName: matchingDkg?.name,
      pendingDkgThreshold: matchingDkg?.threshold,
      pendingDkgCreator: matchingDkg?.creator,
      pendingDkgExpiry: matchingDkg?.expiry,
    );
  }

  static bool _dkgMatchesSetup(WorkerDkgStatus status, RoastSetup setup) =>
      status.name == setup.keyName &&
      status.threshold == setup.threshold &&
      status.creator == setup.hostParticipantId &&
      status.description == roastKeyDescription(setup) &&
      status.expiry.isAfter(DateTime.now());

  static GroupConfig _group(RoastSetup setup) => GroupConfig(
    id: setup.groupId,
    participants: {
      for (final participant in setup.participants)
        Identifier.fromHex(participant.identifierHex):
            ECCompressedPublicKey.fromHex(participant.publicKeyHex),
    },
  );

  static GroupConfig _bootstrapGroup(String roomId) => GroupConfig(
    id: '$roomId:enrollment-bootstrap',
    participants: {
      for (var index = 1; index <= 2; index++)
        Identifier.fromUint16(index): ECCompressedPublicKey.fromPubkey(
          ECPrivateKey.generate().pubkey,
        ),
    },
  );

  @override
  Future<void> close() async {
    await _workerEvents?.cancel();
    _workerEvents = null;
    await _worker?.close();
    _worker = null;
    _setups.clear();
    _emittedGroupKeys.clear();
    _serverSetups.clear();
    _signerSetups.clear();
    for (final subscription in _roomSubscriptions.values) {
      await subscription.cancel();
    }
    _roomSubscriptions.clear();
    for (final node in _roomServers.values) {
      await node.close();
    }
    _roomServers.clear();
    _freezingRooms.clear();
    for (final timer in _roomSignerTimers.values) {
      timer.cancel();
    }
    _roomSignerTimers.clear();
    _connectingRoomSigners.clear();
    for (final timer in _keyReadinessTimers.values) {
      timer.cancel();
    }
    _keyReadinessTimers.clear();
    await _events.close();
  }
}
