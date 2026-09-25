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
  required final List<String> onlineParticipantIds,
  required final String? coordinatorId,
  required final List<String> coordinatorRelayUrls,
  required final List<String> coordinatorIpAddrs,
}) extends RoastRuntimeEvent;

final class RoastRuntimeDkgEvent(
  super.setupId, {
  required final String proposalHex,
  required final bool rejected,
  final String? failure,
}) extends RoastRuntimeEvent;

final class RoastRuntimeKeyEvent(
  super.setupId, {
  required final String groupKeyHex,
}) extends RoastRuntimeEvent;

final class RoastRuntimeFailureEvent(
  super.setupId, {
  required final String message,
  required final bool interrupted,
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
  required final int inputSats,
  required final int transactionInputCount,
  required final List<int> signedInputIndexes,
  required final List<String> previousOutputScripts,
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

final class RoastRuntimeSigningResultEvent(
  super.setupId, {
  required final String requestIdHex,
  required final List<Uint8List> signatures,
  required final String creator,
}) extends RoastRuntimeEvent;

class RoastRuntimeSnapshot({
  required final bool connected,
  required final List<String> onlineParticipantIds,
  required final String? coordinatorId,
  required final List<String> coordinatorRelayUrls,
  required final List<String> coordinatorIpAddrs,
  required final String? groupKeyHex,
  required final String? pendingDkgProposalHex,
});

abstract interface class RoastRuntime {
  Stream<RoastRuntimeEvent> get events;

  Future<RoastRuntimeSnapshot> startSetup(RoastSetup setup);
  Future<void> requestDkg(RoastSetup setup);
  Future<void> acceptDkg(String setupId, String proposalHex);
  Future<void> rejectDkg(String setupId, String proposalHex);
  Future<String> requestTransactionSignatures(
    RoastSetup setup,
    ThresholdWalletTransaction transaction,
    List<int> derivationPath,
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
  NoosphereWorker? _worker;
  StreamSubscription<NoosphereWorkerEvent>? _workerEvents;

  @override
  Stream<RoastRuntimeEvent> get events => _events.stream;

  Future<NoosphereWorker> _ensureWorker() async {
    final existing = _worker;
    if (existing != null && !existing.isClosed) return existing;
    final worker = await NoosphereWorker.start();
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
    final persistence = await _persistenceFactory.open();
    final group = _group(setup);
    final fingerprint = bytesToHex(group.fingerprint);
    if (setup.groupFingerprintHex case final expected?
        when expected != fingerprint) {
      throw StateError('The stored ROAST group fingerprint does not match.');
    }

    NoosphereWorkerSnapshot? serverSnapshot;
    if (setup.role == RoastSetupRole.host) {
      serverSnapshot = await worker.startSetup(
        setupId: setup.id,
        identityStorageId: 'sygnature:${setup.id}',
        server: EmbeddedServerOptions(
          serverConfig: ServerConfig(group: group),
          identityStore: persistence.serverIdentity(setup.id),
        ),
      );
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
    final snapshot = await worker.startSetup(
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
    return _snapshot(snapshot);
  }

  @override
  Future<void> requestDkg(RoastSetup setup) async {
    final worker = await _ensureWorker();
    await worker.requestDkg(
      setup.id,
      NewDkgDetails(
        name: setup.keyName,
        description: 'Sygnature ${setup.name} shared wallet',
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
  Future<String> requestTransactionSignatures(
    RoastSetup setup,
    ThresholdWalletTransaction transaction,
    List<int> derivationPath,
  ) async {
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
    await (await _ensureWorker()).requestSignatures(setup.id, details);
    return bytesToHex(details.id.toBytes());
  }

  @override
  Future<void> acceptSignatures(String setupId, String requestIdHex) async {
    final request = _signingRequests['$setupId:$requestIdHex'];
    if (request == null) {
      throw StateError('The signing request is no longer available.');
    }
    await (await _ensureWorker()).acceptSignatures(setupId, request);
  }

  @override
  Future<void> rejectSignatures(String setupId, String requestIdHex) async {
    final request = _signingRequests['$setupId:$requestIdHex'];
    if (request == null) {
      throw StateError('The signing request is no longer available.');
    }
    await (await _ensureWorker()).rejectSignatures(setupId, request);
  }

  @override
  Future<void> stopSetup(String setupId) async {
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
        for (final key in event.snapshot.keys) {
          _events.add(
            RoastRuntimeKeyEvent(event.setupId, groupKeyHex: key.groupKeyHex),
          );
        }
      case WorkerDkgEvent():
        final proposalHex = bytesToHex(event.status.proposalBytes);
        _dkgProposals['${event.setupId}:$proposalHex'] = event.status;
        _events.add(
          RoastRuntimeDkgEvent(
            event.setupId,
            proposalHex: proposalHex,
            rejected: event.rejected,
            failure: event.failure,
          ),
        );
      case WorkerKeyUpdatedEvent():
        _events.add(
          RoastRuntimeKeyEvent(
            event.setupId,
            groupKeyHex: event.key.groupKeyHex,
          ),
        );
      case WorkerFailureEvent():
        _events.add(
          RoastRuntimeFailureEvent(
            event.setupId,
            message: event.message,
            interrupted: event.interrupted,
          ),
        );
      case WorkerParticipantEvent() || WorkerSessionReplacedEvent():
        unawaited(_refresh(event.setupId));
      case WorkerSigningRequestEvent():
        _emitSigningRequest(event.setupId, event.request);
      case WorkerSigningResultEvent():
        _events.add(
          RoastRuntimeSigningResultEvent(
            event.setupId,
            requestIdHex: bytesToHex(event.requestId),
            signatures: event.signatures,
            creator: event.creator,
          ),
        );
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
    } on Object {
      // A concurrent stop legitimately makes this refresh stale.
    }
  }

  void _rememberDkgs(NoosphereWorkerSnapshot snapshot) {
    for (final proposal in snapshot.dkgs) {
      final proposalHex = bytesToHex(proposal.proposalBytes);
      _dkgProposals['${snapshot.setupId}:$proposalHex'] = proposal;
      _events.add(
        RoastRuntimeDkgEvent(
          snapshot.setupId,
          proposalHex: proposalHex,
          rejected: false,
        ),
      );
    }
  }

  void _rememberSigningRequests(NoosphereWorkerSnapshot snapshot) {
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
    var signedInputIndexes = const <int>[];
    var previousOutputScripts = const <String>[];
    var outputs = const <RoastSigningOutput>[];
    final hasTransactionMetadata =
        metadata is TaprootTransactionSignatureMetadata;
    if (metadata is TaprootTransactionSignatureMetadata) {
      transactionInputCount = metadata.transaction.inputs.length;
      usesSupportedSighash = metadata.signDetails.every(
        (details) =>
            details is TaprootKeySignDetails &&
            details.hashType.schnorrDefault,
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
          for (final output in previousOutputs)
            bytesToHex(output.scriptPubKey),
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
          inputSats: inputSats,
          transactionInputCount: transactionInputCount,
          signedInputIndexes: signedInputIndexes,
          previousOutputScripts: previousOutputScripts,
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
        onlineParticipantIds: snapshot.onlineParticipants,
        coordinatorId: coordinator?.id,
        coordinatorRelayUrls: coordinator?.relayUrls ?? const [],
        coordinatorIpAddrs: coordinator?.ipAddrs ?? const [],
      ),
    );
  }

  RoastRuntimeSnapshot _snapshot(NoosphereWorkerSnapshot snapshot) {
    _rememberDkgs(snapshot);
    final coordinator = snapshot.coordinator;
    return RoastRuntimeSnapshot(
      connected: snapshot.connected,
      onlineParticipantIds: snapshot.onlineParticipants,
      coordinatorId: coordinator?.id,
      coordinatorRelayUrls: coordinator?.relayUrls ?? const [],
      coordinatorIpAddrs: coordinator?.ipAddrs ?? const [],
      groupKeyHex: snapshot.keys.firstOrNull?.groupKeyHex,
      pendingDkgProposalHex: snapshot.dkgs.isEmpty
          ? null
          : bytesToHex(snapshot.dkgs.first.proposalBytes),
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

  @override
  Future<void> close() async {
    await _workerEvents?.cancel();
    _workerEvents = null;
    await _worker?.close();
    _worker = null;
    await _events.close();
  }
}
