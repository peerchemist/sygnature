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

abstract interface class RoastRuntime {
  Stream<RoastRuntimeEvent> get events;

  Future<RoastRuntimeSnapshot> startSetup(RoastSetup setup);
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
  Future<RoastRuntimeSnapshot> startSetup(RoastSetup setup) async {
    if (!setup.isFinalized) {
      throw StateError('Finalize the participant roster before connecting.');
    }
    final worker = await _ensureWorker();
    _setups[setup.id] = setup;
    final persistence = await _persistenceFactory.open();
    final group = _group(setup);
    final fingerprint = bytesToHex(group.fingerprint);
    if (setup.groupFingerprintHex case final expected?
        when expected != fingerprint) {
      throw StateError('The stored ROAST group fingerprint does not match.');
    }

    NoosphereWorkerSnapshot? serverSnapshot;
    if (setup.role == RoastSetupRole.host &&
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

    final coordinator = serverSnapshot?.coordinator;
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
    final snapshot = _signerSetups.contains(setup.id)
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
    _signerSetups.add(setup.id);
    return _snapshot(snapshot, setup);
  }

  @override
  Future<void> requestDkg(RoastSetup setup) async {
    final worker = await _ensureWorker();
    await worker.requestDkg(
      setup.id,
      NewDkgDetails(
        name: setup.keyName,
        description: _keyDescription(setup),
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
    final worker = _worker;
    if (worker == null || worker.isClosed) return;
    await worker.stopSetup(setupId);
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
    final expectedDescription = _keyDescription(setup);
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
              key.description == _keyDescription(setup) &&
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
              key.description == _keyDescription(setup),
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
      status.description == _keyDescription(setup) &&
      status.expiry.isAfter(DateTime.now());

  static String _keyDescription(RoastSetup setup) =>
      'Sygnature ${setup.name} shared wallet';

  static GroupConfig _group(RoastSetup setup) => GroupConfig(
    id: setup.groupId,
    participants: {
      for (final participant in setup.participants)
        Identifier.fromHex(participant.identifierHex):
            ECCompressedPublicKey.fromHex(participant.publicKeyHex),
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
    for (final timer in _keyReadinessTimers.values) {
      timer.cancel();
    }
    _keyReadinessTimers.clear();
    await _events.close();
  }
}
