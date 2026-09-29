import 'dart:convert';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart' as cl;
import 'package:noosphere/common.dart';
import 'package:noosphere/domain.dart';

const sygnatureWalletTransitionPolicyKind =
    'sygnature/peercoin-wallet-transition';
const sygnatureWalletTransitionPolicyVersion = 1;
const _sygnatureWalletTransitionPolicyDomain =
    'sygnature/wallet-transition-policy/1';

/// Host policy that constrains how one Sygnature wallet account may migrate.
final class SygnatureWalletTransitionPolicy._({
  required final String sourceAccountId,
  required final String blockchainId,
  required final String networkId,
  required final String keyId,
  required final List<int> destinationDerivationPath,
  required final int maxTotalFeeSats,
  required final int maxFeeRateSatsPerKb,
  required final int minimumConfirmations,
  required final int maxMigrationAttempts,
  required final bool sweepLateDeposits,
}) with cl.Writable {
  factory SygnatureWalletTransitionPolicy({
    required String sourceAccountId,
    required String blockchainId,
    required String networkId,
    required String keyId,
    required Iterable<int> destinationDerivationPath,
    required int maxTotalFeeSats,
    required int maxFeeRateSatsPerKb,
    required int minimumConfirmations,
    required int maxMigrationAttempts,
    required bool sweepLateDeposits,
  }) {
    _checkPolicyId(sourceAccountId, 'sourceAccountId');
    _checkPolicyId(blockchainId, 'blockchainId');
    _checkPolicyId(networkId, 'networkId');
    _checkPolicyId(keyId, 'keyId');
    final path = List<int>.unmodifiable(destinationDerivationPath);
    if (path.isEmpty || path.length > 0xffff) {
      throw ArgumentError.value(
        path.length,
        'destinationDerivationPath',
        'must contain 1..65535 components',
      );
    }
    for (final component in path) {
      RangeError.checkValueInInterval(
        component,
        0,
        0xffffffff,
        'destinationDerivationPath',
      );
    }
    RangeError.checkValueInInterval(
      maxTotalFeeSats,
      0,
      0x7fffffffffffffff,
      'maxTotalFeeSats',
    );
    RangeError.checkValueInInterval(
      maxFeeRateSatsPerKb,
      1,
      0xffffffff,
      'maxFeeRateSatsPerKb',
    );
    RangeError.checkValueInInterval(
      minimumConfirmations,
      1,
      0xffff,
      'minimumConfirmations',
    );
    RangeError.checkValueInInterval(
      maxMigrationAttempts,
      1,
      0xffff,
      'maxMigrationAttempts',
    );
    return SygnatureWalletTransitionPolicy._(
      sourceAccountId: sourceAccountId,
      blockchainId: blockchainId,
      networkId: networkId,
      keyId: keyId,
      destinationDerivationPath: path,
      maxTotalFeeSats: maxTotalFeeSats,
      maxFeeRateSatsPerKb: maxFeeRateSatsPerKb,
      minimumConfirmations: minimumConfirmations,
      maxMigrationAttempts: maxMigrationAttempts,
      sweepLateDeposits: sweepLateDeposits,
    );
  }

  factory SygnatureWalletTransitionPolicy.fromBytes(Uint8List bytes) {
    final reader = cl.BytesReader(bytes);
    if (reader.readString() != _sygnatureWalletTransitionPolicyDomain) {
      throw const FormatException('Invalid wallet transition policy domain.');
    }
    final version = reader.readUInt16();
    if (version != sygnatureWalletTransitionPolicyVersion) {
      throw FormatException(
        'Unsupported wallet transition policy version: $version',
      );
    }
    final policy = SygnatureWalletTransitionPolicy(
      sourceAccountId: reader.readString(),
      blockchainId: reader.readString(),
      networkId: reader.readString(),
      keyId: reader.readString(),
      destinationDerivationPath: List.generate(
        reader.readUInt16(),
        (_) => reader.readUInt32(),
      ),
      maxTotalFeeSats: reader.readUInt64().toInt(),
      maxFeeRateSatsPerKb: reader.readUInt32(),
      minimumConfirmations: reader.readUInt16(),
      maxMigrationAttempts: reader.readUInt16(),
      sweepLateDeposits: reader.readBool(),
    );
    if (!reader.atEnd || !cl.bytesEqual(bytes, policy.toBytes())) {
      throw const FormatException('Non-canonical wallet transition policy.');
    }
    return policy;
  }

  GroupTransitionMigrationPolicy get noospherePolicy =>
      GroupTransitionMigrationPolicy(
        kind: sygnatureWalletTransitionPolicyKind,
        version: sygnatureWalletTransitionPolicyVersion,
        payload: toBytes(),
      );

  @override
  void write(cl.Writer writer) {
    writer
      ..writeString(_sygnatureWalletTransitionPolicyDomain)
      ..writeUInt16(sygnatureWalletTransitionPolicyVersion)
      ..writeString(sourceAccountId)
      ..writeString(blockchainId)
      ..writeString(networkId)
      ..writeString(keyId)
      ..writeUInt16(destinationDerivationPath.length);
    for (final component in destinationDerivationPath) {
      writer.writeUInt32(component);
    }
    writer
      ..writeUInt64(BigInt.from(maxTotalFeeSats))
      ..writeUInt32(maxFeeRateSatsPerKb)
      ..writeUInt16(minimumConfirmations)
      ..writeUInt16(maxMigrationAttempts)
      ..writeBool(sweepLateDeposits);
  }
}

enum WalletGroupTransitionPhase {
  proposed,
  preparing,
  ready,
  migrationPending,
  active,
  retired,
  failed,
  outcomeUnknown,
}

/// Durable host progress for a canonical Noosphere transition proposal.
final class WalletGroupTransition._({
  required final String transitionId,
  required final String sourceSetupId,
  required final String successorSetupId,
  required final String proposalHex,
  required final Map<String, String> dkgDetailsHexByKey,
  required final Map<String, String> signedApprovalsHexByParticipant,
  required final WalletGroupTransitionPhase phase,
  required final List<String> migrationOperationIds,
  required final List<String> transactionIds,
  required final DateTime createdAt,
  required final DateTime updatedAt,
  required final String? errorMessage,
}) {
  factory WalletGroupTransition.proposed({
    required String sourceSetupId,
    required String successorSetupId,
    required GroupTransitionProposal proposal,
    required Map<String, NewDkgDetails> dkgDetailsByKey,
    DateTime? now,
  }) => _validated(
    transitionId: proposal.transitionId,
    sourceSetupId: sourceSetupId,
    successorSetupId: successorSetupId,
    proposalHex: cl.bytesToHex(proposal.toBytes()),
    dkgDetailsHexByKey: {
      for (final entry in dkgDetailsByKey.entries)
        entry.key: cl.bytesToHex(entry.value.toBytes()),
    },
    signedApprovalsHexByParticipant: const {},
    phase: WalletGroupTransitionPhase.proposed,
    migrationOperationIds: const [],
    transactionIds: const [],
    createdAt: now ?? DateTime.now().toUtc(),
    updatedAt: now ?? DateTime.now().toUtc(),
    errorMessage: null,
  );

  factory WalletGroupTransition.fromJson(Map<Object?, Object?> json) =>
      _validated(
        transitionId: json['transitionId']! as String,
        sourceSetupId: json['sourceSetupId']! as String,
        successorSetupId: json['successorSetupId']! as String,
        proposalHex: json['proposalHex']! as String,
        dkgDetailsHexByKey: Map<String, String>.from(
          json['dkgDetailsHexByKey']! as Map,
        ),
        signedApprovalsHexByParticipant: Map<String, String>.from(
          (json['signedApprovalsHexByParticipant'] as Map?) ?? const {},
        ),
        phase: WalletGroupTransitionPhase.values.byName(
          json['phase']! as String,
        ),
        migrationOperationIds:
            ((json['migrationOperationIds'] as List?) ?? const []).cast(),
        transactionIds: ((json['transactionIds'] as List?) ?? const []).cast(),
        createdAt: DateTime.parse(json['createdAt']! as String),
        updatedAt: DateTime.parse(json['updatedAt']! as String),
        errorMessage: json['errorMessage'] as String?,
      );

  GroupTransitionProposal get proposal =>
      GroupTransitionProposal.fromBytes(cl.hexToBytes(proposalHex));

  Map<String, NewDkgDetails> get dkgDetailsByKey => Map.unmodifiable({
    for (final entry in dkgDetailsHexByKey.entries)
      entry.key: NewDkgDetails.fromBytesAllowExpired(
        cl.hexToBytes(entry.value),
      ),
  });

  WalletGroupTransition withApproval(
    Signed<GroupTransitionApproval> signedApproval, {
    DateTime? now,
  }) {
    final approval = signedApproval.obj;
    if (!approval.matchesProposal(proposal) ||
        !signedApproval.verify(approval.participantPublicKey)) {
      throw const FormatException(
        'Transition approval is invalid for this proposal.',
      );
    }
    return copyWith(
      signedApprovalsHexByParticipant: {
        ...signedApprovalsHexByParticipant,
        approval.participantPublicKey.hex: cl.bytesToHex(
          signedApproval.toBytes(),
        ),
      },
      updatedAt: now,
    );
  }

  WalletGroupTransition copyWith({
    Map<String, String>? signedApprovalsHexByParticipant,
    WalletGroupTransitionPhase? phase,
    List<String>? migrationOperationIds,
    List<String>? transactionIds,
    DateTime? updatedAt,
    String? errorMessage,
    bool clearError = false,
  }) => _validated(
    transitionId: transitionId,
    sourceSetupId: sourceSetupId,
    successorSetupId: successorSetupId,
    proposalHex: proposalHex,
    dkgDetailsHexByKey: dkgDetailsHexByKey,
    signedApprovalsHexByParticipant:
        signedApprovalsHexByParticipant ?? this.signedApprovalsHexByParticipant,
    phase: phase ?? this.phase,
    migrationOperationIds: migrationOperationIds ?? this.migrationOperationIds,
    transactionIds: transactionIds ?? this.transactionIds,
    createdAt: createdAt,
    updatedAt: updatedAt ?? DateTime.now().toUtc(),
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );

  Map<String, Object?> toJson() => {
    'transitionId': transitionId,
    'sourceSetupId': sourceSetupId,
    'successorSetupId': successorSetupId,
    'proposalHex': proposalHex,
    'dkgDetailsHexByKey': dkgDetailsHexByKey,
    'signedApprovalsHexByParticipant': signedApprovalsHexByParticipant,
    'phase': phase.name,
    'migrationOperationIds': migrationOperationIds,
    'transactionIds': transactionIds,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'errorMessage': errorMessage,
  };

  static WalletGroupTransition _validated({
    required String transitionId,
    required String sourceSetupId,
    required String successorSetupId,
    required String proposalHex,
    required Map<String, String> dkgDetailsHexByKey,
    required Map<String, String> signedApprovalsHexByParticipant,
    required WalletGroupTransitionPhase phase,
    required List<String> migrationOperationIds,
    required List<String> transactionIds,
    required DateTime createdAt,
    required DateTime updatedAt,
    required String? errorMessage,
  }) {
    _checkPolicyId(sourceSetupId, 'sourceSetupId');
    _checkPolicyId(successorSetupId, 'successorSetupId');
    if (sourceSetupId == successorSetupId) {
      throw ArgumentError.value(
        successorSetupId,
        'successorSetupId',
        'must differ from sourceSetupId',
      );
    }
    final proposalBytes = cl.hexToBytes(proposalHex);
    final proposal = GroupTransitionProposal.fromBytes(proposalBytes);
    if (proposal.transitionId != transitionId) {
      throw const FormatException('Transition ID does not match the proposal.');
    }
    final expectedKeyIds = {for (final plan in proposal.keyPlans) plan.keyId};
    if (!expectedKeyIds.containsAll(dkgDetailsHexByKey.keys) ||
        !dkgDetailsHexByKey.keys.toSet().containsAll(expectedKeyIds)) {
      throw const FormatException('Transition DKG plans are incomplete.');
    }
    for (final plan in proposal.keyPlans) {
      final encoded = cl.hexToBytes(dkgDetailsHexByKey[plan.keyId]!);
      final details = NewDkgDetails.fromBytesAllowExpired(encoded);
      if (!cl.bytesEqual(encoded, details.toBytes()) ||
          !plan.matchesDkgDetails(details)) {
        throw FormatException(
          'DKG details do not match transition key ${plan.keyId}.',
        );
      }
    }
    for (final entry in signedApprovalsHexByParticipant.entries) {
      final encoded = cl.hexToBytes(entry.value);
      final signed = Signed<GroupTransitionApproval>.fromBytes(
        encoded,
        GroupTransitionApproval.fromReader,
      );
      final approval = signed.obj;
      if (!cl.bytesEqual(encoded, signed.toBytes()) ||
          entry.key != approval.participantPublicKey.hex ||
          !approval.matchesProposal(proposal) ||
          !signed.verify(approval.participantPublicKey)) {
        throw const FormatException('Stored transition approval is invalid.');
      }
    }
    if (updatedAt.isBefore(createdAt)) {
      throw const FormatException('Transition update predates its creation.');
    }
    return WalletGroupTransition._(
      transitionId: transitionId,
      sourceSetupId: sourceSetupId,
      successorSetupId: successorSetupId,
      proposalHex: proposalHex,
      dkgDetailsHexByKey: Map.unmodifiable(dkgDetailsHexByKey),
      signedApprovalsHexByParticipant: Map.unmodifiable(
        signedApprovalsHexByParticipant,
      ),
      phase: phase,
      migrationOperationIds: List.unmodifiable(migrationOperationIds),
      transactionIds: List.unmodifiable(transactionIds),
      createdAt: createdAt.toUtc(),
      updatedAt: updatedAt.toUtc(),
      errorMessage: errorMessage,
    );
  }
}

void _checkPolicyId(String value, String name) {
  final length = utf8.encode(value).length;
  if (length < 1 || length > 255) {
    throw ArgumentError.value(value, name, 'must be 1..255 UTF-8 bytes');
  }
}
