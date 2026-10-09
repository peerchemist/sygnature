import 'dart:async';
import 'dart:typed_data';

import 'package:noosphere_flutter/noosphere_flutter.dart';

import '../models/roast_setup.dart';
import 'wallet_transaction_service.dart';

const roastDkgAttemptTtl = Duration(hours: 1);
const defaultRoastSigningRequestTimeout = Duration(minutes: 30);
const maxRoastSigningRequestTimeout = Duration(hours: 24);
const maxRoastSigningMessageBytes = SignaturesRequestDetails.maxMessageBytes;
const maxRoastSignedMessageBytes = SignedMessagePayload.maxTextBytes;
const sygnatureRoomInvitePrefix = 'sygnature-roast-v1:';

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

class RoastRuntimeInvitationEnrollment({
  required final String participantPublicKeyHex,
  required final RoastInvitationServerStatus status,
  required final DateTime? usedAt,
});

class RoastRuntimeParticipantEnrollment({
  required final String participantPublicKeyHex,
  required final DateTime enrolledAt,
});

final class RoastRuntimeEnrollmentEvent(
  super.setupId, {
  required final List<RoastRuntimeInvitationEnrollment> invitations,
  required final List<RoastRuntimeParticipantEnrollment> participants,
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

enum RoastRuntimeOperation {
  signatures,
  signingPersistence,
  keyReadiness,
  dkg,
  room,
  connection,
  worker,
  refresh,
  unknown,
}

final class RoastRuntimeFailureEvent(
  super.setupId, {
  required final String message,
  required final bool interrupted,
  required final RoastRuntimeOperation operation,
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

class RoastRoomCreation({
  required final List<NoosphereRoomInvite> invites,
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
  Future<RoomSnapshot> joinRoom(RoastSetup setup, NoosphereRoomInvite invite);
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
    Duration timeout = defaultRoastSigningRequestTimeout,
  });
  RoastSigningProposal createMessageSigningProposal(
    RoastSetup setup,
    String text, {
    String message = '',
    Duration timeout = defaultRoastSigningRequestTimeout,
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
