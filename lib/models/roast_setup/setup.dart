import 'dart:convert';

import 'participant.dart';

enum RoastSetupRole { host, member }

enum RoastSetupStatus {
  draft,
  ready,
  connecting,
  awaitingDkgApproval,
  creatingKey,
  active,
  interrupted,
  error,
}

class RoastSetup({
  required final String id,
  required final String groupId,
  required final String name,
  required final RoastSetupRole role,
  required final RoastSetupStatus status,
  required final int threshold,
  required final int participantCount,
  required final String blockchainId,
  required final String networkId,
  required final String localCardId,
  required final String localParticipantPrivateKeyHex,
  required final List<RoastParticipant> participants,
  required final List<String> onlineParticipantIds,
  required final String keyName,
  required final DateTime createdAt,
  final int irohIdentityIndex = 0,
  final bool usesRoomEnrollment = false,
  final String? hostParticipantId,
  final String? coordinatorId,
  final List<String> coordinatorRelayUrls = const [],
  final List<String> coordinatorIpAddrs = const [],
  final String? groupFingerprintHex,
  final String? groupKeyHex,
  final String? pendingDkgProposalHex,
  final String? pendingDkgStage,
  final List<String> pendingDkgCompletedParticipantIds = const [],
  final String? pendingDkgName,
  final int? pendingDkgThreshold,
  final String? pendingDkgCreatorId,
  final DateTime? pendingDkgExpiry,
  final String? errorMessage,
}) {
  RoastParticipant get localParticipant => participants.firstWhere(
    (participant) => participant.cardId == localCardId,
  );

  bool get isFinalized => participants.length == participantCount;
  bool get isActive => status == RoastSetupStatus.active;
  bool get isWaitingForInvitation =>
      role == RoastSetupRole.member && status == RoastSetupStatus.draft;

  RoastSetup copyWith({
    RoastSetupStatus? status,
    List<RoastParticipant>? participants,
    List<String>? onlineParticipantIds,
    String? keyName,
    int? irohIdentityIndex,
    String? hostParticipantId,
    String? coordinatorId,
    List<String>? coordinatorRelayUrls,
    List<String>? coordinatorIpAddrs,
    String? groupFingerprintHex,
    String? groupKeyHex,
    String? pendingDkgProposalHex,
    String? pendingDkgStage,
    List<String>? pendingDkgCompletedParticipantIds,
    String? pendingDkgName,
    int? pendingDkgThreshold,
    String? pendingDkgCreatorId,
    DateTime? pendingDkgExpiry,
    bool clearPendingDkgProposal = false,
    String? errorMessage,
    bool clearError = false,
  }) => RoastSetup(
    id: id,
    groupId: groupId,
    name: name,
    role: role,
    status: status ?? this.status,
    threshold: threshold,
    participantCount: participantCount,
    blockchainId: blockchainId,
    networkId: networkId,
    localCardId: localCardId,
    localParticipantPrivateKeyHex: localParticipantPrivateKeyHex,
    participants: participants ?? this.participants,
    onlineParticipantIds: onlineParticipantIds ?? this.onlineParticipantIds,
    keyName: keyName ?? this.keyName,
    createdAt: createdAt,
    irohIdentityIndex: irohIdentityIndex ?? this.irohIdentityIndex,
    usesRoomEnrollment: usesRoomEnrollment,
    hostParticipantId: hostParticipantId ?? this.hostParticipantId,
    coordinatorId: coordinatorId ?? this.coordinatorId,
    coordinatorRelayUrls: coordinatorRelayUrls ?? this.coordinatorRelayUrls,
    coordinatorIpAddrs: coordinatorIpAddrs ?? this.coordinatorIpAddrs,
    groupFingerprintHex: groupFingerprintHex ?? this.groupFingerprintHex,
    groupKeyHex: groupKeyHex ?? this.groupKeyHex,
    pendingDkgProposalHex: clearPendingDkgProposal
        ? null
        : pendingDkgProposalHex ?? this.pendingDkgProposalHex,
    pendingDkgStage: clearPendingDkgProposal
        ? null
        : pendingDkgStage ?? this.pendingDkgStage,
    pendingDkgCompletedParticipantIds: clearPendingDkgProposal
        ? const []
        : pendingDkgCompletedParticipantIds ??
              this.pendingDkgCompletedParticipantIds,
    pendingDkgName: clearPendingDkgProposal
        ? null
        : pendingDkgName ?? this.pendingDkgName,
    pendingDkgThreshold: clearPendingDkgProposal
        ? null
        : pendingDkgThreshold ?? this.pendingDkgThreshold,
    pendingDkgCreatorId: clearPendingDkgProposal
        ? null
        : pendingDkgCreatorId ?? this.pendingDkgCreatorId,
    pendingDkgExpiry: clearPendingDkgProposal
        ? null
        : pendingDkgExpiry ?? this.pendingDkgExpiry,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'groupId': groupId,
    'name': name,
    'role': role.name,
    'status': status.name,
    'threshold': threshold,
    'participantCount': participantCount,
    'blockchainId': blockchainId,
    'networkId': networkId,
    'localCardId': localCardId,
    'localParticipantPrivateKeyHex': localParticipantPrivateKeyHex,
    'participants': participants.map((item) => item.toJson()).toList(),
    'onlineParticipantIds': onlineParticipantIds,
    'keyName': keyName,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'irohIdentityIndex': irohIdentityIndex,
    'usesRoomEnrollment': usesRoomEnrollment,
    'hostParticipantId': hostParticipantId,
    'coordinatorId': coordinatorId,
    'coordinatorRelayUrls': coordinatorRelayUrls,
    'coordinatorIpAddrs': coordinatorIpAddrs,
    'groupFingerprintHex': groupFingerprintHex,
    'groupKeyHex': groupKeyHex,
    'pendingDkgProposalHex': pendingDkgProposalHex,
    'pendingDkgStage': pendingDkgStage,
    'pendingDkgCompletedParticipantIds': pendingDkgCompletedParticipantIds,
    'pendingDkgName': pendingDkgName,
    'pendingDkgThreshold': pendingDkgThreshold,
    'pendingDkgCreatorId': pendingDkgCreatorId,
    'pendingDkgExpiry': pendingDkgExpiry?.toUtc().toIso8601String(),
    'errorMessage': errorMessage,
  };

  factory RoastSetup.fromJson(Map<Object?, Object?> json) {
    final participants = (json['participants']! as List)
        .map((item) => RoastParticipant.fromJson(item as Map))
        .toList(growable: false);
    final id = json['id']! as String;
    final groupId = json['groupId']! as String;
    return RoastSetup(
      id: id,
      groupId: groupId,
      name: json['name']! as String,
      role: RoastSetupRole.values.byName(json['role']! as String),
      status: RoastSetupStatus.values.byName(json['status']! as String),
      threshold: json['threshold']! as int,
      participantCount: json['participantCount']! as int,
      blockchainId: json['blockchainId']! as String,
      networkId: json['networkId']! as String,
      localCardId: json['localCardId']! as String,
      localParticipantPrivateKeyHex:
          json['localParticipantPrivateKeyHex']! as String,
      participants: participants,
      onlineParticipantIds:
          ((json['onlineParticipantIds'] as List?) ?? const []).cast<String>(),
      keyName: normalizeRoastKeyName(groupId, json['keyName']! as String),
      createdAt: DateTime.parse(json['createdAt']! as String),
      irohIdentityIndex:
          json['irohIdentityIndex'] as int? ?? irohIdentityIndexForSetup(id),
      usesRoomEnrollment: json['usesRoomEnrollment'] as bool? ?? false,
      hostParticipantId:
          json['hostParticipantId'] as String? ??
          participants.firstOrNull?.identifierHex,
      coordinatorId: json['coordinatorId'] as String?,
      coordinatorRelayUrls:
          ((json['coordinatorRelayUrls'] as List?) ?? const []).cast<String>(),
      coordinatorIpAddrs: ((json['coordinatorIpAddrs'] as List?) ?? const [])
          .cast<String>(),
      groupFingerprintHex: json['groupFingerprintHex'] as String?,
      groupKeyHex: json['groupKeyHex'] as String?,
      pendingDkgProposalHex: json['pendingDkgProposalHex'] as String?,
      pendingDkgStage: json['pendingDkgStage'] as String?,
      pendingDkgCompletedParticipantIds:
          ((json['pendingDkgCompletedParticipantIds'] as List?) ?? const [])
              .cast<String>(),
      pendingDkgName: json['pendingDkgName'] as String?,
      pendingDkgThreshold: json['pendingDkgThreshold'] as int?,
      pendingDkgCreatorId: json['pendingDkgCreatorId'] as String?,
      pendingDkgExpiry: json['pendingDkgExpiry'] == null
          ? null
          : DateTime.parse(json['pendingDkgExpiry']! as String),
      errorMessage: json['errorMessage'] as String?,
    );
  }
}

/// Returns a stable non-secret BIP-85 child index for a ROAST setup.
int irohIdentityIndexForSetup(String setupId) {
  var hash = 0x811c9dc5;
  for (final codeUnit in setupId.codeUnits) {
    hash = ((hash ^ codeUnit) * 0x01000193) & 0x7fffffff;
  }
  return hash;
}

const maxRoastKeyNameLength = 40;

String roastKeyName(String groupId) {
  const suffix = '-g1';
  final maxGroupIdLength = maxRoastKeyNameLength - suffix.length;
  final keyPrefix = groupId.length <= maxGroupIdLength
      ? groupId
      : groupId.substring(0, maxGroupIdLength);
  return '$keyPrefix$suffix';
}

String normalizeRoastKeyName(String groupId, String keyName) =>
    keyName.length >= 3 && keyName.length <= maxRoastKeyNameLength
    ? keyName
    : roastKeyName(groupId);

String roastKeyDescription(RoastSetup setup) => jsonEncode([
  'sygnature-roast-wallet-v1',
  setup.name,
  setup.blockchainId,
  setup.networkId,
  setup.threshold,
  setup.participantCount,
  setup.groupFingerprintHex,
]);
