import 'dart:convert';

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

class RoastParticipant({
  required final String cardId,
  required final String name,
  required final String identifierHex,
  required final String publicKeyHex,
}) {
  Map<String, Object?> toJson() => {
    'cardId': cardId,
    'name': name,
    'identifierHex': identifierHex,
    'publicKeyHex': publicKeyHex,
  };

  factory RoastParticipant.fromJson(Map<Object?, Object?> json) =>
      RoastParticipant(
        cardId: json['cardId']! as String,
        name: json['name']! as String,
        identifierHex: json['identifierHex']! as String,
        publicKeyHex: json['publicKeyHex']! as String,
      );
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

  RoastSetup copyWith({
    RoastSetupStatus? status,
    List<RoastParticipant>? participants,
    List<String>? onlineParticipantIds,
    String? keyName,
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
    final groupId = json['groupId']! as String;
    return RoastSetup(
      id: json['id']! as String,
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

abstract final class RoastExchangeCodec {
  static const version = 1;
  static const uriScheme = 'sygnature-roast-v1';
  static const _prefix = '$uriScheme:';
  static const maxEncodedLength = 16384;

  static String encodeParticipantCard({
    required String cardId,
    required String name,
    required String publicKeyHex,
  }) => _encode({
    'version': version,
    'type': 'participant-card',
    'cardId': cardId,
    'name': name,
    'publicKeyHex': publicKeyHex,
  });

  static ({String cardId, String name, String publicKeyHex})
  decodeParticipantCard(String encoded) {
    final json = _decode(encoded, expectedType: 'participant-card');
    return (
      cardId: _requiredString(json, 'cardId'),
      name: _requiredString(json, 'name'),
      publicKeyHex: _requiredString(json, 'publicKeyHex'),
    );
  }

  static String encodeInvitation(
    RoastSetup setup, {
    required String roomInvite,
    required String participantPublicKeyHex,
    required DateTime expiresAt,
  }) {
    if (!setup.isFinalized ||
        setup.coordinatorId == null ||
        setup.hostParticipantId == null) {
      throw StateError('The ROAST setup is not ready for an invitation.');
    }
    return _encode({
      'version': version,
      'type': 'room-invitation',
      'groupId': setup.groupId,
      'setupName': setup.name,
      'threshold': setup.threshold,
      'participantCount': setup.participantCount,
      'blockchainId': setup.blockchainId,
      'networkId': setup.networkId,
      'keyName': setup.keyName,
      'hostParticipantId': setup.hostParticipantId,
      'coordinatorId': setup.coordinatorId,
      'coordinatorRelayUrls': setup.coordinatorRelayUrls,
      'coordinatorIpAddrs': setup.coordinatorIpAddrs,
      'groupFingerprintHex': setup.groupFingerprintHex,
      'participantPublicKeyHex': participantPublicKeyHex,
      'roomInvite': roomInvite,
      'expiresAt': expiresAt.toUtc().toIso8601String(),
      'participants': setup.participants.map((item) => item.toJson()).toList(),
    });
  }

  static Map<String, Object?> decodeInvitation(String encoded) =>
      _decode(encoded, expectedType: 'room-invitation');

  static String _encode(Map<String, Object?> value) {
    final encoded =
        '$_prefix${base64Url.encode(utf8.encode(jsonEncode(value)))}';
    if (encoded.length > maxEncodedLength) {
      throw const FormatException('ROAST exchange payload is too large.');
    }
    return encoded;
  }

  static Map<String, Object?> _decode(
    String input, {
    required String expectedType,
  }) {
    final encoded = input.trim();
    if (!encoded.startsWith(_prefix) || encoded.length > maxEncodedLength) {
      throw const FormatException('Invalid ROAST exchange payload.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(
        utf8.decode(base64Url.decode(encoded.substring(_prefix.length))),
      );
    } on Object {
      throw const FormatException('Invalid ROAST exchange payload.');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != version ||
        decoded['type'] != expectedType) {
      throw const FormatException('Unsupported ROAST exchange payload.');
    }
    return decoded.cast<String, Object?>();
  }

  static String _requiredString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('ROAST payload is missing $key.');
    }
    return value;
  }
}
