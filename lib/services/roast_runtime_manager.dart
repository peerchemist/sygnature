import 'dart:async';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart'
    show TaprootKeySignDetails, bytesEqual, bytesToHex;
import 'package:noosphere_flutter/noosphere_flutter.dart';

import '../models/roast_setup.dart';
import '../storage/roast_storage.dart';
import 'app_logger.dart';
import 'wallet_transaction_service.dart';

const roastDkgAttemptTtl = Duration(hours: 1);
const maxRoastSigningMessageBytes = SignaturesRequestDetails.maxMessageBytes;
const maxRoastSignedMessageBytes = SignedMessagePayload.maxTextBytes;

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
  final List<String> completedParticipantIds = const [],
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

enum RoastSigningRequestKind { transaction, message, unsupported }

class RoastSigningProgress({
  required final int threshold,
  required final List<String> contributingParticipants,
  required final String stage,
});

class RoastSigningRequest({
  required final String idHex,
  required final String proposalHex,
  required final String creator,
  required final DateTime expiry,
  required final RoastSigningRequestKind kind,
  required final bool hasTransactionMetadata,
  required final bool usesSupportedSighash,
  required final bool usesExpectedTaprootTweak,
  required final bool usesUntweakedKey,
  required final String status,
  required final RoastSigningProgress progress,
  required final int inputSats,
  required final int transactionInputCount,
  required final List<int> signedInputIndexes,
  required final List<String> previousOutputScripts,
  required final List<String> inputOutpoints,
  required final List<RoastSigningOutput> outputs,
  required final List<String> masterGroupKeys,
  required final List<List<int>> derivationPaths,
  final String message = '',
  final String? signedMessageText,
}) {
  int get outputSats =>
      outputs.fold(0, (sum, output) => sum + output.valueSats);
  int get feeSats => inputSats - outputSats;

  RoastSigningRequest copyWith({String? status}) => RoastSigningRequest(
    idHex: idHex,
    proposalHex: proposalHex,
    creator: creator,
    expiry: expiry,
    kind: kind,
    hasTransactionMetadata: hasTransactionMetadata,
    usesSupportedSighash: usesSupportedSighash,
    usesExpectedTaprootTweak: usesExpectedTaprootTweak,
    usesUntweakedKey: usesUntweakedKey,
    status: status ?? this.status,
    progress: progress,
    inputSats: inputSats,
    transactionInputCount: transactionInputCount,
    signedInputIndexes: signedInputIndexes,
    previousOutputScripts: previousOutputScripts,
    inputOutpoints: inputOutpoints,
    outputs: outputs,
    masterGroupKeys: masterGroupKeys,
    derivationPaths: derivationPaths,
    message: message,
    signedMessageText: signedMessageText,
  );
}

final class RoastRuntimeSigningRequestEvent(
  super.setupId, {
  required final RoastSigningRequest request,
}) extends RoastRuntimeEvent;

final class RoastRuntimeSigningRequestRemovedEvent(
  super.setupId, {
  required final String requestIdHex,
  required final bool expired,
}) extends RoastRuntimeEvent;

final class RoastRuntimeSigningResultEvent(
  super.setupId, {
  required final String requestIdHex,
  required final String proposalHex,
  required final List<Uint8List> signatures,
  required final String creator,
}) extends RoastRuntimeEvent;

class RoastSignedMessage({
  required final String text,
  required final String publicKeyHex,
  required final String signatureHex,
  required final String encoded,
});

final class RoastRuntimeMessageSigningResultEvent(
  super.setupId, {
  required final String requestIdHex,
  required final String creator,
  required final RoastSignedMessage signedMessage,
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
  final List<String> pendingDkgCompletedParticipantIds = const [],
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
  required final Uint8List coordinatorEndpointId,
  required final String coordinatorId,
  required final List<String> coordinatorRelayUrls,
  required final List<String> coordinatorIpAddrs,
});

class const RoastCoordinatorAddress({
  required final String id,
  required final List<String> relayUrls,
  required final List<String> ipAddrs,
}) {
  factory RoastCoordinatorAddress.parse({
    required String id,
    required Iterable<String> relayUrls,
    required Iterable<String> ipAddrs,
  }) {
    final endpoint = EndpointAddr(
      PublicKey.fromZ32(id.trim()),
      relayUrls: [
        for (final value in relayUrls)
          if (value.trim().isNotEmpty) RelayUrl.parse(value.trim()),
      ],
      ipAddrs: [
        for (final value in ipAddrs)
          if (value.trim().isNotEmpty) value.trim(),
      ],
    );
    return RoastCoordinatorAddress(
      id: endpoint.id.toZ32(),
      relayUrls: [for (final relay in endpoint.relayUrls) relay.value],
      ipAddrs: List.unmodifiable(endpoint.ipAddrs),
    );
  }
}

enum RoastCoordinatorSwitchFailureKind {
  pendingSigningOperations,
  persistence,
  connection,
}

final class RoastCoordinatorSwitchFailure({
  required final RoastCoordinatorSwitchFailureKind kind,
  required final String code,
  required final Object cause,
}) implements Exception {
  @override
  String toString() => 'RoastCoordinatorSwitchFailure($code): $cause';
}

enum RoastEnrollmentFailureKind {
  rejected,
  timeout,
  malformedResponse,
  connection,
}

final class RoastEnrollmentFailure({
  required final RoastEnrollmentFailureKind kind,
  required final Object cause,
  final int roomFailureCode = 0xffff,
}) implements Exception {
  bool get outcomeMayBePersisted => kind != RoastEnrollmentFailureKind.rejected;

  @override
  String toString() =>
      'RoastEnrollmentFailure(${kind.name}, roomCode=$roomFailureCode): $cause';
}

abstract interface class RoastRuntime {
  Stream<RoastRuntimeEvent> get events;

  Future<RoastRuntimeSnapshot> startSetup(RoastSetup setup);

  /// Awaits [beforeInvitations] after the room exists and before issuing the
  /// first participant-bound invitation.
  Future<RoastRoomCreation> createRoom(
    RoastSetup setup, {
    Future<void> Function(RoastRoomCreation room)? beforeInvitations,
  });
  Future<RoastRuntimeSnapshot> joinRoom(RoastSetup setup, String encodedInvite);
  Future<void> requestDkg(
    RoastSetup setup, {
    NewDkgDetails? approvedDetails,
    GroupTransitionKeyPlan? transitionKeyPlan,
  });
  Future<void> acceptDkg(String setupId, String proposalHex);
  Future<void> rejectDkg(String setupId, String proposalHex);
  RoastSigningProposal createTransactionSigningProposal(
    RoastSetup setup,
    ThresholdWalletTransaction transaction,
    List<int> derivationPath, {
    String message = '',
  });
  RoastSigningProposal createMessageSigningProposal(
    RoastSetup setup,
    String text, {
    String message = '',
  });
  Future<void> requestSignatures(
    RoastSetup setup,
    RoastSigningProposal proposal,
  );
  Future<void> acceptSignatures(String setupId, String requestIdHex);
  Future<void> rejectSignatures(String setupId, String requestIdHex);
  Future<void> stopSetup(String setupId);
  Future<void> deleteSetup(String setupId);
  Future<void> close();
}

abstract interface class RoastCoordinatorRuntime {
  Future<RoastRuntimeSnapshot> switchCoordinator(
    RoastSetup setup, {
    required RoastCoordinatorAddress newCoordinator,
    required Future<void> Function(RoastCoordinatorAddress address) persist,
  });

  Future<RoastRuntimeSnapshot> updateCoordinatorAddress(
    RoastSetup setup,
    RoastCoordinatorAddress coordinator,
  );
}

enum _ExistingDkgResolution { none, resumed, cancelled }

final class RoastRuntimeManager(RoastPersistenceFactory persistenceFactory)
    implements RoastRuntime, RoastCoordinatorRuntime {
  final RoastPersistenceFactory _persistenceFactory = persistenceFactory;
  final StreamController<RoastRuntimeEvent> _events =
      StreamController<RoastRuntimeEvent>.broadcast();
  final Map<String, WorkerDkgStatus> _dkgProposals = {};
  final Map<String, WorkerSigningRequest> _signingRequests = {};
  final Map<String, RoastSetup> _setups = {};
  final Map<String, String> _emittedGroupKeys = {};
  final Set<String> _serverSetups = {};
  final Set<String> _signerSetups = {};
  final Map<String, RoastCoordinatorAddress> _signerCoordinators = {};
  final Map<String, NoosphereNode> _roomServers = {};
  final Map<String, StreamSubscription<RoomSnapshot>> _roomSubscriptions = {};
  final Set<String> _freezingRooms = {};
  final Map<String, Timer> _roomSignerTimers = {};
  final Set<String> _connectingRoomSigners = {};
  final Set<String> _synchronizingDkgSetups = {};
  final Map<String, Uint8List> _approvedDkgDetailsBySetup = {};
  final Map<String, Timer> _keyReadinessTimers = {};
  NoosphereWorker? _worker;
  StreamSubscription<NoosphereWorkerEvent>? _workerEvents;

  static String _scope(String subsystem, String setupId) {
    final shortId = setupId.length <= 8 ? setupId : setupId.substring(0, 8);
    return '[$subsystem $shortId]';
  }

  static String _irohScope(String setupId) => _scope('IROH', setupId);
  static String _noosphereScope(String setupId) => _scope('NOOSPHERE', setupId);
  static String _roastScope(String setupId) => _scope('ROAST', setupId);

  static String _shortId(String value) =>
      value.length <= 8 ? value : value.substring(0, 8);

  @override
  Stream<RoastRuntimeEvent> get events => _events.stream;

  Future<NoosphereWorker> _ensureWorker() async {
    final existing = _worker;
    if (existing != null && !existing.isClosed) return existing;
    AppLogger.info('[NOOSPHERE] Starting worker');
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
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.error(
          '[NOOSPHERE] Worker stream failed',
          error: error,
          stackTrace: stackTrace,
        );
        if (!_events.isClosed) {
          _events.addError(StateError('ROAST worker stream failed: $error'));
        }
      },
    );
    AppLogger.info('[NOOSPHERE] Worker started');
    return worker;
  }

  @override
  Future<RoastRuntimeSnapshot> startSetup(RoastSetup setup) async {
    final scope = _roastScope(setup.id);
    AppLogger.info(
      '$scope Starting setup (${setup.role.name}, '
      '${setup.participantCount} participants, threshold ${setup.threshold})',
    );
    try {
      final snapshot = await _startSetup(setup, scheduleRoomRetry: true);
      AppLogger.info(
        '$scope Setup state: connected=${snapshot.connected}, '
        'signerRunning=${snapshot.signerRunning}, '
        'online=${snapshot.onlineParticipantIds.length}',
      );
      return snapshot;
    } catch (error, stackTrace) {
      AppLogger.error(
        '$scope Setup failed to start',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<RoastRuntimeSnapshot> _startSetup(
    RoastSetup setup, {
    required bool scheduleRoomRetry,
    bool publishDkgs = true,
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
        AppLogger.info(
          '${_roastScope(setup.id)} Room is waiting for enrolled participants',
        );
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
        server: EmbeddedServerOptions(
          serverConfig: ServerConfig(group: group),
          identityStore: persistence.serverIdentity(setup.id),
          serverPersistence: persistence.serverPersistence(setup.id),
        ),
      );
      _serverSetups.add(setup.id);
      AppLogger.info('${_irohScope(setup.id)} Coordinator started');
    } else if (_serverSetups.contains(setup.id)) {
      serverSnapshot = await worker.snapshot(setup.id);
    }

    final embeddedCoordinator = roomCoordinator ?? serverSnapshot?.coordinator;
    final selectedCoordinator = setup.coordinatorId == null
        ? embeddedCoordinator == null
              ? null
              : RoastCoordinatorAddress(
                  id: embeddedCoordinator.id,
                  relayUrls: embeddedCoordinator.relayUrls,
                  ipAddrs: embeddedCoordinator.ipAddrs,
                )
        : RoastCoordinatorAddress(
            id: setup.coordinatorId!,
            relayUrls: setup.coordinatorRelayUrls,
            ipAddrs: setup.coordinatorIpAddrs,
          );
    if (selectedCoordinator == null) {
      throw StateError('The coordinator did not publish an Iroh identity.');
    }
    final address = _endpointAddress(selectedCoordinator);
    final pinnedId = address.id;
    _signerCoordinators[setup.id] = selectedCoordinator;
    final privateKey = ECPrivateKey.fromHex(
      setup.localParticipantPrivateKeyHex,
    );
    final clientOptions = ClientNodeOptions(
      clientConfig: ClientConfig(
        group: group,
        id: Identifier.fromHex(setup.localParticipant.identifierHex),
      ),
      bootstrapAddress: address,
      pinnedServerId: pinnedId,
      storage: persistence.clientStorage(setup.id),
      getPrivateKey: (_) async => privateKey,
    );
    late final NoosphereWorkerSnapshot snapshot;
    try {
      snapshot = _signerSetups.contains(setup.id)
          ? await worker.snapshot(setup.id)
          : await worker.startSetup(
              setupId: setup.id,
              client: clientOptions.withCoordinator(address),
            );
    } on Object catch (error) {
      if (scheduleRoomRetry &&
          setup.role == RoastSetupRole.member &&
          setup.usesRoomEnrollment) {
        AppLogger.info(
          '${_roastScope(setup.id)} Signer is waiting for the host to freeze '
          'the room (${error.runtimeType})',
        );
        _scheduleRoomSignerConnection(setup);
        return _pendingRoomSnapshot(setup);
      }
      rethrow;
    }
    _signerSetups.add(setup.id);
    AppLogger.info('${_irohScope(setup.id)} Signer transport connected');
    return _snapshot(snapshot, setup, publishDkgs: publishDkgs);
  }

  @override
  Future<RoastRuntimeSnapshot> switchCoordinator(
    RoastSetup setup, {
    required RoastCoordinatorAddress newCoordinator,
    required Future<void> Function(RoastCoordinatorAddress address) persist,
  }) async {
    final worker = await _ensureWorker();
    if (!_signerSetups.contains(setup.id)) {
      throw StateError('The ROAST signer is not running.');
    }
    try {
      final snapshot = await worker.switchCoordinator(
        setup.id,
        newCoordinator: _endpointAddress(newCoordinator),
        persist: (_) async {
          await persist(newCoordinator);
          _signerCoordinators[setup.id] = newCoordinator;
          _setups[setup.id] = setup.copyWith(
            coordinatorId: newCoordinator.id,
            coordinatorRelayUrls: newCoordinator.relayUrls,
            coordinatorIpAddrs: newCoordinator.ipAddrs,
          );
        },
      );
      _signerSetups.add(setup.id);
      return await _snapshot(snapshot, _setups[setup.id] ?? setup);
    } on NoosphereWorkerException catch (error, stackTrace) {
      _signerSetups.remove(setup.id);
      Error.throwWithStackTrace(
        RoastCoordinatorSwitchFailure(
          kind: switch (error.code) {
            'pending_signing_operations' =>
              RoastCoordinatorSwitchFailureKind.pendingSigningOperations,
            'host_state' ||
            'host_timeout' ||
            'host_argument' ||
            'host_failure' => RoastCoordinatorSwitchFailureKind.persistence,
            _ => RoastCoordinatorSwitchFailureKind.connection,
          },
          code: error.code,
          cause: error,
        ),
        stackTrace,
      );
    }
  }

  @override
  Future<RoastRuntimeSnapshot> updateCoordinatorAddress(
    RoastSetup setup,
    RoastCoordinatorAddress coordinator,
  ) async {
    final worker = await _ensureWorker();
    if (!_signerSetups.contains(setup.id)) {
      throw StateError('The ROAST signer is not running.');
    }
    await worker.updateSignerAddress(setup.id, _endpointAddress(coordinator));
    _signerCoordinators[setup.id] = coordinator;
    _setups[setup.id] = setup.copyWith(
      coordinatorId: coordinator.id,
      coordinatorRelayUrls: coordinator.relayUrls,
      coordinatorIpAddrs: coordinator.ipAddrs,
    );
    return _snapshot(await worker.snapshot(setup.id), _setups[setup.id]!);
  }

  @override
  Future<RoastRoomCreation> createRoom(
    RoastSetup setup, {
    Future<void> Function(RoastRoomCreation room)? beforeInvitations,
  }) async {
    if (setup.role != RoastSetupRole.host || !setup.isFinalized) {
      throw StateError('Only a host with a complete roster can create a room.');
    }
    AppLogger.info(
      '${_roastScope(setup.id)} Creating room for '
      '${setup.participantCount} participants (threshold ${setup.threshold})',
    );
    _setups[setup.id] = setup;
    final node = await _ensureRoomServer(setup);
    final server = node.server!;
    await server.createRoom(
      roomId: setup.groupId,
      expectedParticipants: setup.participantCount,
      threshold: setup.threshold,
    );
    final coordinator = _coordinator(server.address);
    final preparedRoom = RoastRoomCreation(
      invites: const [],
      coordinatorEndpointId: server.address.id.asBytes(),
      coordinatorId: coordinator.id,
      coordinatorRelayUrls: coordinator.relayUrls,
      coordinatorIpAddrs: coordinator.ipAddrs,
    );
    await beforeInvitations?.call(preparedRoom);
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
    AppLogger.info(
      '${_roastScope(setup.id)} Room created; issued ${issued.length} '
      'participant-bound invites',
    );
    return RoastRoomCreation(
      invites: issued,
      coordinatorEndpointId: preparedRoom.coordinatorEndpointId,
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
    AppLogger.info('${_roastScope(setup.id)} Validating room invite');
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
    try {
      await _joinRoomInvite(invite, privateKey);
    } on RoomEnrollmentProtocolException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        RoastEnrollmentFailure(
          kind: RoastEnrollmentFailureKind.rejected,
          cause: error,
          roomFailureCode: error.code,
        ),
        stackTrace,
      );
    } on TimeoutException catch (error, stackTrace) {
      _reconcileInterruptedEnrollment(setup);
      Error.throwWithStackTrace(
        RoastEnrollmentFailure(
          kind: RoastEnrollmentFailureKind.timeout,
          cause: error,
        ),
        stackTrace,
      );
    } on FormatException catch (error, stackTrace) {
      _reconcileInterruptedEnrollment(setup);
      Error.throwWithStackTrace(
        RoastEnrollmentFailure(
          kind: RoastEnrollmentFailureKind.malformedResponse,
          cause: error,
        ),
        stackTrace,
      );
    } on Object catch (error, stackTrace) {
      _reconcileInterruptedEnrollment(setup);
      Error.throwWithStackTrace(
        RoastEnrollmentFailure(
          kind: RoastEnrollmentFailureKind.connection,
          cause: error,
        ),
        stackTrace,
      );
    }
    AppLogger.info('${_roastScope(setup.id)} Room enrollment completed');
    _setups[setup.id] = setup;
    _scheduleRoomSignerConnection(setup);
    return _pendingRoomSnapshot(setup);
  }

  void _reconcileInterruptedEnrollment(RoastSetup setup) {
    _setups[setup.id] = setup;
    _scheduleRoomSignerConnection(setup);
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
    AppLogger.info(
      '${_roastScope(setup.id)} Waiting for the frozen room; signer connection '
      'will retry in the background',
    );
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
      AppLogger.info('${_irohScope(setup.id)} Signer transport connected');
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
    AppLogger.info('${_irohScope(setup.id)} Starting room coordinator');
    final persistence = await _persistenceFactory.open();
    final node = await NoosphereNode.start(
      server: EmbeddedServerOptions(
        serverConfig: ServerConfig(group: _bootstrapGroup(setup.groupId)),
        identityStore: persistence.serverIdentity(setup.id),
        serverPersistence: persistence.serverPersistence(setup.id),
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
    AppLogger.info('${_irohScope(setup.id)} Room coordinator started');
    return node;
  }

  void _onRoomSnapshot(String setupId, RoomSnapshot room) {
    if (room.lifecycle != RoomLifecycle.enrolling ||
        !room.isFull ||
        !_freezingRooms.add(setupId)) {
      return;
    }
    AppLogger.info('${_roastScope(setupId)} Room is full; freezing roster');
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
      AppLogger.info('${_roastScope(setupId)} Room roster frozen and verified');
      final snapshot = await startSetup(setup);
      _emitSnapshotValues(setupId, snapshot);
    } catch (error, stackTrace) {
      _emitRoomFailure(setupId, error, stackTrace);
    } finally {
      _freezingRooms.remove(setupId);
    }
  }

  void _emitRoomFailure(
    String setupId,
    Object error, [
    StackTrace? stackTrace,
  ]) {
    AppLogger.error(
      '${_roastScope(setupId)} Room operation failed',
      error: error,
      stackTrace: stackTrace,
    );
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
        id: address.id.toZ32(),
        relayUrls: [for (final relay in address.relayUrls) relay.value],
        ipAddrs: address.ipAddrs,
      );

  static EndpointAddr _endpointAddress(RoastCoordinatorAddress address) =>
      EndpointAddr(
        PublicKey.fromZ32(address.id),
        relayUrls: [
          for (final value in address.relayUrls) RelayUrl.parse(value),
        ],
        ipAddrs: address.ipAddrs,
      );

  @override
  Future<void> requestDkg(
    RoastSetup setup, {
    NewDkgDetails? approvedDetails,
    GroupTransitionKeyPlan? transitionKeyPlan,
  }) async {
    AppLogger.info('${_roastScope(setup.id)} Requesting DKG');
    if ((approvedDetails == null) != (transitionKeyPlan == null)) {
      throw ArgumentError(
        'Approved DKG details and transition key plan must be provided together.',
      );
    }
    if (approvedDetails != null) {
      if (approvedDetails.expiry.isExpired ||
          approvedDetails.name != setup.keyName ||
          approvedDetails.threshold != setup.threshold ||
          transitionKeyPlan!.targetThreshold != setup.threshold ||
          !transitionKeyPlan.matchesDkgDetails(approvedDetails)) {
        throw StateError(
          'The DKG does not match the approved transition plan.',
        );
      }
      _approvedDkgDetailsBySetup[setup.id] = Uint8List.fromList(
        approvedDetails.toBytes(),
      );
    } else {
      _approvedDkgDetailsBySetup.remove(setup.id);
    }
    final worker = await _ensureWorker();
    final existing = await _resolveExistingDkg(
      worker,
      setup,
      await worker.snapshot(setup.id),
    );
    if (existing == _ExistingDkgResolution.resumed) return;

    final details =
        approvedDetails ??
        NewDkgDetails(
          name: setup.keyName,
          description: roastKeyDescription(setup),
          threshold: setup.threshold,
          expiry: Expiry(roastDkgAttemptTtl),
        );
    try {
      await worker.requestDkg(setup.id, details);
    } catch (error, stackTrace) {
      if (!_isDuplicateDkgError(error)) {
        AppLogger.error(
          '${_roastScope(setup.id)} DKG request failed',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
      AppLogger.warn(
        '${_roastScope(setup.id)} Coordinator already has this DKG name; '
        'reloading the signer session before retrying',
      );
      final recovered = await _reloadExistingDkg(worker, setup);
      if (recovered == _ExistingDkgResolution.resumed) return;
      if (recovered == _ExistingDkgResolution.cancelled) {
        await _runDkgCommand(
          setup.id,
          'DKG retry after cancelling the conflicting proposal',
          () => worker.requestDkg(setup.id, details),
        );
      } else {
        AppLogger.error(
          '${_roastScope(setup.id)} Existing DKG could not be recovered',
          error: error,
          stackTrace: stackTrace,
        );
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
    AppLogger.info(
      '${_roastScope(setup.id)} DKG request submitted; '
      'waiting for signer approvals',
    );
  }

  Future<_ExistingDkgResolution> _reloadExistingDkg(
    NoosphereWorker worker,
    RoastSetup setup,
  ) async {
    AppLogger.info(
      '${_irohScope(setup.id)} Restarting signer session to synchronize DKGs',
    );
    _synchronizingDkgSetups.add(setup.id);
    try {
      await worker.stopSetup(setup.id, roles: NoosphereWorkerRoles.signer);
      _signerSetups.remove(setup.id);
      await _startSetup(setup, scheduleRoomRetry: false, publishDkgs: false);
      final snapshot = await worker.snapshot(setup.id);
      AppLogger.info(
        '${_irohScope(setup.id)} Signer session synchronized; '
        '${snapshot.dkgs.length} DKG proposal(s) loaded',
      );
      return await _resolveExistingDkg(worker, setup, snapshot);
    } finally {
      _synchronizingDkgSetups.remove(setup.id);
    }
  }

  Future<_ExistingDkgResolution> _resolveExistingDkg(
    NoosphereWorker worker,
    RoastSetup setup,
    NoosphereWorkerSnapshot snapshot,
  ) async {
    final sameName = snapshot.dkgs
        .where((proposal) => proposal.name == setup.keyName)
        .toList(growable: false);
    if (sameName.isEmpty) return _ExistingDkgResolution.none;
    if (sameName.length > 1) {
      throw StateError('Multiple DKG proposals use the expected key name.');
    }
    final proposal = sameName.single;
    final proposalHex = bytesToHex(proposal.proposalBytes);
    if (_dkgMatchesSetup(proposal, setup)) {
      AppLogger.info(
        '${_roastScope(setup.id)} Resuming existing DKG '
        '${_shortId(proposalHex)} at stage=${proposal.stage}',
      );
      _rememberDkgs(snapshot);
      _emitSnapshot(snapshot);
      return _ExistingDkgResolution.resumed;
    }

    AppLogger.warn(
      '${_roastScope(setup.id)} Cancelling incompatible DKG '
      '${_shortId(proposalHex)} before creating a replacement',
    );
    await _runDkgCommand(
      setup.id,
      'Conflicting DKG cancellation',
      () => worker.rejectDkg(setup.id, proposal),
    );
    _dkgProposals.remove('${setup.id}:$proposalHex');
    return _ExistingDkgResolution.cancelled;
  }

  static bool _isDuplicateDkgError(Object error) =>
      error is NoosphereWorkerException &&
      error.code == 'iroh_protocol_error' &&
      error.message.contains('DKG request with same name exists');

  @override
  Future<void> acceptDkg(String setupId, String proposalHex) async {
    final proposal = _dkgProposals['$setupId:$proposalHex'];
    if (proposal == null) {
      throw StateError('The DKG proposal is no longer available.');
    }
    AppLogger.info(
      '${_roastScope(setupId)} Accepting DKG ${_shortId(proposalHex)}',
    );
    final worker = await _ensureWorker();
    await _runDkgCommand(
      setupId,
      'DKG approval',
      () => worker.acceptDkg(setupId, proposal),
    );
    AppLogger.info('${_roastScope(setupId)} DKG approved locally');
  }

  @override
  Future<void> rejectDkg(String setupId, String proposalHex) async {
    final proposal = _dkgProposals['$setupId:$proposalHex'];
    if (proposal == null) {
      throw StateError('The DKG proposal is no longer available.');
    }
    AppLogger.info(
      '${_roastScope(setupId)} Rejecting DKG ${_shortId(proposalHex)}',
    );
    final worker = await _ensureWorker();
    await _runDkgCommand(
      setupId,
      'DKG rejection',
      () => worker.rejectDkg(setupId, proposal),
    );
    AppLogger.info('${_roastScope(setupId)} DKG rejected locally');
  }

  Future<void> _runDkgCommand(
    String setupId,
    String operation,
    Future<void> Function() command,
  ) async {
    try {
      await command();
    } catch (error, stackTrace) {
      AppLogger.error(
        '${_roastScope(setupId)} $operation failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  RoastSigningProposal createTransactionSigningProposal(
    RoastSetup setup,
    ThresholdWalletTransaction transaction,
    List<int> derivationPath, {
    String message = '',
  }) {
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
      message: message,
    );
    return _signingProposal(details);
  }

  @override
  RoastSigningProposal createMessageSigningProposal(
    RoastSetup setup,
    String text, {
    String message = '',
  }) {
    final groupKeyHex = setup.groupKeyHex;
    if (groupKeyHex == null) {
      throw StateError('The shared key is not available.');
    }
    return _signingProposal(
      SignaturesRequestDetails.forMessage(
        text: text,
        groupKey: ECCompressedPublicKey.fromHex(groupKeyHex),
        expiry: Expiry(const Duration(minutes: 5)),
        message: message,
      ),
    );
  }

  static RoastSigningProposal _signingProposal(
    SignaturesRequestDetails details,
  ) {
    final proposalBytes = details.toBytes();
    final persistedDetails = SignaturesRequestDetails.fromBytes(proposalBytes);
    return RoastSigningProposal(
      idHex: bytesToHex(persistedDetails.id.toBytes()),
      proposalHex: bytesToHex(proposalBytes),
      expiry: persistedDetails.expiry.time,
    );
  }

  @override
  Future<void> requestSignatures(
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
    AppLogger.info(
      '${_roastScope(setup.id)} Requesting signatures '
      '${_shortId(proposal.idHex)}',
    );
    await (await _ensureWorker()).requestSignatures(setup.id, details);
  }

  @override
  Future<void> acceptSignatures(String setupId, String requestIdHex) async {
    final request = _signingRequests['$setupId:$requestIdHex'];
    if (request == null || request.status != 'waiting') {
      throw StateError('The signing request is no longer available.');
    }
    AppLogger.info(
      '${_roastScope(setupId)} Accepting signing request '
      '${_shortId(requestIdHex)}',
    );
    await (await _ensureWorker()).acceptSignatures(setupId, request);
  }

  @override
  Future<void> rejectSignatures(String setupId, String requestIdHex) async {
    final request = _signingRequests['$setupId:$requestIdHex'];
    if (request == null || request.status != 'waiting') {
      throw StateError('The signing request is no longer available.');
    }
    AppLogger.info(
      '${_roastScope(setupId)} Rejecting signing request '
      '${_shortId(requestIdHex)}',
    );
    await (await _ensureWorker()).rejectSignatures(setupId, request);
  }

  @override
  Future<void> stopSetup(String setupId) async {
    AppLogger.info('${_roastScope(setupId)} Stopping setup');
    _setups.remove(setupId);
    _emittedGroupKeys.remove(setupId);
    _serverSetups.remove(setupId);
    _signerSetups.remove(setupId);
    _signerCoordinators.remove(setupId);
    _keyReadinessTimers.remove(setupId)?.cancel();
    await _roomSubscriptions.remove(setupId)?.cancel();
    await _roomServers.remove(setupId)?.close();
    _freezingRooms.remove(setupId);
    _roomSignerTimers.remove(setupId)?.cancel();
    _connectingRoomSigners.remove(setupId);
    final worker = _worker;
    if (worker != null && !worker.isClosed) {
      await worker.stopSetup(setupId);
    }
    AppLogger.info('${_roastScope(setupId)} Setup stopped');
  }

  @override
  Future<void> deleteSetup(String setupId) async {
    await stopSetup(setupId);
    await _persistenceFactory.deleteSetupData(setupId);
    AppLogger.info('${_roastScope(setupId)} Setup data deleted');
  }

  void _onWorkerEvent(NoosphereWorkerEvent event) {
    switch (event) {
      case WorkerSnapshotEvent():
        if (!_synchronizingDkgSetups.contains(event.setupId)) {
          _rememberDkgs(event.snapshot);
        }
        _rememberSigningRequests(event.snapshot);
        _emitSnapshot(event.snapshot);
        unawaited(_rememberExpectedKeySafely(event.snapshot));
      case WorkerDkgEvent():
        final proposalHex = bytesToHex(event.status.proposalBytes);
        AppLogger.info(
          '${_roastScope(event.setupId)} DKG ${_shortId(proposalHex)} '
          'stage=${event.status.stage}, rejected=${event.rejected}',
          error: event.failure,
        );
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
            completedParticipantIds: event.status.completedParticipants,
            failure: event.failure,
          ),
        );
      case WorkerKeyUpdatedEvent():
        AppLogger.info('${_roastScope(event.setupId)} Group key updated');
        unawaited(_refresh(event.setupId));
      case WorkerFailureEvent():
        AppLogger.error(
          '${_noosphereScope(event.setupId)} Worker operation '
          '${event.operation} failed: ${event.message}',
        );
        _events.add(
          RoastRuntimeFailureEvent(
            event.setupId,
            message: event.message,
            interrupted: event.interrupted,
            operation: event.operation,
          ),
        );
        unawaited(_refresh(event.setupId));
      case WorkerParticipantEvent():
        AppLogger.info(
          '${_irohScope(event.setupId)} Participant is '
          '${event.online ? 'online' : 'offline'}',
        );
        unawaited(_refresh(event.setupId));
      case WorkerSessionReplacedEvent():
        AppLogger.warn(
          '${_noosphereScope(event.setupId)} Worker session replaced',
        );
        unawaited(_refresh(event.setupId));
      case WorkerSigningRequestEvent():
        AppLogger.info(
          '${_roastScope(event.setupId)} Signing request '
          '${_shortId(bytesToHex(event.request.id))} '
          'status=${event.request.status}, '
          'stage=${event.request.progress.stage}, '
          'contributors=${event.request.progress.contributingParticipants.length}/'
          '${event.request.progress.threshold}',
        );
        _emitSigningRequest(event.setupId, event.request);
      case WorkerSigningResultEvent():
        AppLogger.info(
          '${_roastScope(event.setupId)} Signing completed for '
          '${_shortId(bytesToHex(event.requestId))}; '
          '${event.signatures.length} signatures',
        );
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
      if (event.decodeProposal().metadata is MessageSignatureMetadata) {
        final signed = event.toSignedMessage();
        if (!_events.isClosed) {
          _events.add(
            RoastRuntimeMessageSigningResultEvent(
              event.setupId,
              requestIdHex: requestIdHex,
              creator: event.creator,
              signedMessage: RoastSignedMessage(
                text: signed.text,
                publicKeyHex: signed.publicKey.xhex,
                signatureHex: bytesToHex(signed.signature.data),
                encoded: signed.toJsonString(),
              ),
            ),
          );
        }
        return;
      }
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
    } catch (error, stackTrace) {
      AppLogger.error(
        '${_roastScope(event.setupId)} Failed to process signing result '
        '${_shortId(requestIdHex)}',
        error: error,
        stackTrace: stackTrace,
      );
      if (!_events.isClosed) {
        _events.add(
          RoastRuntimeFailureEvent(
            event.setupId,
            message: 'Unable to process completed ROAST signatures: $error',
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
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        '${_roastScope(snapshot.setupId)} Unable to verify key readiness',
        error: error,
        stackTrace: stackTrace,
      );
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
    AppLogger.info('${_roastScope(snapshot.setupId)} Group key is ready');
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
    final keys = (await persistence.clientStorage(setup.id).loadState()).keys;
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
      final participantCount = _setups[snapshot.setupId]?.participantCount;
      AppLogger.info(
        '${_roastScope(snapshot.setupId)} DKG ${_shortId(proposalHex)} '
        'snapshot stage=${proposal.stage}, '
        'completed=${proposal.completedParticipants.length}/'
        '${participantCount ?? '?'}',
      );
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
          completedParticipantIds: proposal.completedParticipants,
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
      final request = _signingRequests.remove(key);
      _events.add(
        RoastRuntimeSigningRequestRemovedEvent(
          snapshot.setupId,
          requestIdHex: key.substring(prefix.length),
          expired: request?.expiry.isBefore(DateTime.now()) ?? false,
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
    final kind = switch (metadata) {
      TaprootTransactionSignatureMetadata() =>
        RoastSigningRequestKind.transaction,
      MessageSignatureMetadata() => RoastSigningRequestKind.message,
      _ => RoastSigningRequestKind.unsupported,
    };
    var inputSats = 0;
    var transactionInputCount = 0;
    var usesSupportedSighash = false;
    final usesExpectedTaprootTweak = proposal.requiredSigs.every(
      (signature) => signature.signDetails.mastHash?.isEmpty == true,
    );
    final usesUntweakedKey = proposal.requiredSigs.every(
      (signature) => signature.signDetails.mastHash == null,
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
          kind: kind,
          hasTransactionMetadata: hasTransactionMetadata,
          usesSupportedSighash: usesSupportedSighash,
          usesExpectedTaprootTweak: usesExpectedTaprootTweak,
          usesUntweakedKey: usesUntweakedKey,
          status: request.status,
          progress: RoastSigningProgress(
            threshold: request.progress.threshold,
            contributingParticipants: List.unmodifiable(
              request.progress.contributingParticipants,
            ),
            stage: request.progress.stage,
          ),
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
          message: proposal.message,
          signedMessageText: metadata is MessageSignatureMetadata
              ? metadata.payload.text
              : null,
        ),
      ),
    );
  }

  void _emitSnapshot(NoosphereWorkerSnapshot snapshot) {
    final coordinator = _selectedCoordinator(snapshot.setupId);
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
    RoastSetup setup, {
    bool publishDkgs = true,
  }) async {
    if (publishDkgs) _rememberDkgs(snapshot);
    _rememberSigningRequests(snapshot);
    final coordinator = _selectedCoordinator(snapshot.setupId);
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
      pendingDkgCompletedParticipantIds:
          matchingDkg?.completedParticipants ?? const [],
      pendingDkgName: matchingDkg?.name,
      pendingDkgThreshold: matchingDkg?.threshold,
      pendingDkgCreator: matchingDkg?.creator,
      pendingDkgExpiry: matchingDkg?.expiry,
    );
  }

  bool _dkgMatchesSetup(WorkerDkgStatus status, RoastSetup setup) {
    final approved = _approvedDkgDetailsBySetup[setup.id];
    return status.name == setup.keyName &&
        status.threshold == setup.threshold &&
        status.creator == setup.hostParticipantId &&
        status.expiry.isAfter(DateTime.now()) &&
        (approved == null
            ? status.description == roastKeyDescription(setup)
            : bytesEqual(status.proposalBytes, approved));
  }

  RoastCoordinatorAddress? _selectedCoordinator(String setupId) {
    final selected = _signerCoordinators[setupId];
    if (selected != null) return selected;
    final setup = _setups[setupId];
    final id = setup?.coordinatorId;
    return id == null
        ? null
        : RoastCoordinatorAddress(
            id: id,
            relayUrls: setup!.coordinatorRelayUrls,
            ipAddrs: setup.coordinatorIpAddrs,
          );
  }

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
    AppLogger.info('[NOOSPHERE] Closing runtime');
    await _workerEvents?.cancel();
    _workerEvents = null;
    await _worker?.close();
    _worker = null;
    _setups.clear();
    _emittedGroupKeys.clear();
    _serverSetups.clear();
    _signerSetups.clear();
    _signerCoordinators.clear();
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
    AppLogger.info('[NOOSPHERE] Runtime closed');
  }
}
