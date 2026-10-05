import 'dart:async';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart'
    show TaprootKeySignDetails, bytesEqual, bytesToHex;
import 'package:noosphere_flutter/noosphere_flutter.dart';

import '../models/roast_setup.dart';
import '../storage/roast_storage.dart';
import 'app_logger.dart';
import 'roast_runtime.dart';
import 'wallet_transaction_service.dart';

export 'roast_runtime.dart';

part 'roast_runtime_rooms.dart';
part 'roast_runtime_dkg.dart';
part 'roast_runtime_signing_mapper.dart';

enum _ExistingDkgResolution { none, resumed, cancelled }

typedef WalletBip39SeedProvider = FutureOr<Uint8List> Function();

final class RoastRuntimeManager(
  RoastPersistenceFactory persistenceFactory, {
  required WalletBip39SeedProvider getWalletBip39Seed,
}) implements RoastRuntime, RoastCoordinatorRuntime {
  final RoastPersistenceFactory _persistenceFactory = persistenceFactory;
  final WalletBip39SeedProvider _getWalletBip39Seed = getWalletBip39Seed;
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
          getIrohSecretKey: () => _irohSecretKey(setup, persistence),
          serverPersistence: persistence.serverPersistence(setup.id),
        ),
      );
      _serverSetups.add(setup.id);
      AppLogger.info('${_irohScope(setup.id)} Coordinator started');
    } else if (_serverSetups.contains(setup.id)) {
      serverSnapshot = await worker.snapshot(setup.id);
    }

    final embeddedCoordinator = roomCoordinator ?? serverSnapshot?.coordinator;
    final selectedCoordinator =
        setup.role == RoastSetupRole.host && embeddedCoordinator != null
        ? RoastCoordinatorAddress(
            id: embeddedCoordinator.id,
            relayUrls: embeddedCoordinator.relayUrls,
            ipAddrs: embeddedCoordinator.ipAddrs,
          )
        : setup.coordinatorId == null
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
  }) => _createRoom(setup, beforeInvitations: beforeInvitations);

  @override
  Future<RoastRuntimeSnapshot> joinRoom(
    RoastSetup setup,
    String encodedInvite,
  ) => _joinRoom(setup, encodedInvite);

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
  }) => _requestDkg(
    setup,
    approvedDetails: approvedDetails,
    transitionKeyPlan: transitionKeyPlan,
  );

  @override
  Future<void> acceptDkg(String setupId, String proposalHex) =>
      _acceptDkg(setupId, proposalHex);

  @override
  Future<void> rejectDkg(String setupId, String proposalHex) =>
      _rejectDkg(setupId, proposalHex);

  @override
  RoastSigningProposal createTransactionSigningProposal(
    RoastSetup setup,
    ThresholdWalletTransaction transaction,
    List<int> derivationPath, {
    String message = '',
    Duration timeout = defaultRoastSigningRequestTimeout,
  }) {
    _validateSigningRequestTimeout(timeout);
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
      expiry: Expiry(timeout),
      message: message,
    );
    return _signingProposal(details);
  }

  @override
  RoastSigningProposal createMessageSigningProposal(
    RoastSetup setup,
    String text, {
    String message = '',
    Duration timeout = defaultRoastSigningRequestTimeout,
  }) {
    _validateSigningRequestTimeout(timeout);
    final groupKeyHex = setup.groupKeyHex;
    if (groupKeyHex == null) {
      throw StateError('The shared key is not available.');
    }
    return _signingProposal(
      SignaturesRequestDetails.forMessage(
        text: text,
        groupKey: ECCompressedPublicKey.fromHex(groupKeyHex),
        expiry: Expiry(timeout),
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

  static void _validateSigningRequestTimeout(Duration timeout) {
    if (timeout.inMicroseconds <= 0 ||
        timeout > maxRoastSigningRequestTimeout) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'Must be greater than zero and no more than 24 hours.',
      );
    }
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
    _events.add(
      RoastRuntimeSigningRequestEvent(
        setupId,
        request: _mapSigningRequest(request, idHex: idHex),
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

  Future<SecretKey> _irohSecretKey(
    RoastSetup setup,
    RoastPersistence persistence,
  ) async {
    final legacy = await persistence.legacyIrohSecretKey(setup.id);
    if (legacy != null) return legacy;

    final seed = await _getWalletBip39Seed();
    try {
      return deriveIrohSecretKeyFromBip39Seed(
        seed,
        index: setup.irohIdentityIndex,
      );
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

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
