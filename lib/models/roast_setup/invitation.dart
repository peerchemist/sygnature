enum RoastInvitationServerStatus { pending, used, revoked, expired }

enum RoastInvitationDisplayStatus {
  ready,
  copied,
  sent,
  joined,
  expired,
  revoked,
}

class RoastIssuedInvitation({
  required final String participantName,
  required final String participantPublicKeyHex,
  required final String encoded,
  required final DateTime issuedAt,
  required final DateTime expiresAt,
  final DateTime? copiedAt,
  final DateTime? sentAt,
  final DateTime? joinedAt,
  final RoastInvitationServerStatus serverStatus =
      RoastInvitationServerStatus.pending,
}) {
  RoastInvitationDisplayStatus statusAt(DateTime now) {
    if (joinedAt != null || serverStatus == RoastInvitationServerStatus.used) {
      return RoastInvitationDisplayStatus.joined;
    }
    if (serverStatus == RoastInvitationServerStatus.revoked) {
      return RoastInvitationDisplayStatus.revoked;
    }
    if (serverStatus == RoastInvitationServerStatus.expired ||
        !expiresAt.isAfter(now)) {
      return RoastInvitationDisplayStatus.expired;
    }
    if (sentAt != null) return RoastInvitationDisplayStatus.sent;
    if (copiedAt != null) return RoastInvitationDisplayStatus.copied;
    return RoastInvitationDisplayStatus.ready;
  }

  RoastIssuedInvitation copyWith({
    DateTime? copiedAt,
    DateTime? sentAt,
    DateTime? joinedAt,
    RoastInvitationServerStatus? serverStatus,
  }) {
    if ((copiedAt == null || copiedAt == this.copiedAt) &&
        (sentAt == null || sentAt == this.sentAt) &&
        (joinedAt == null || joinedAt == this.joinedAt) &&
        (serverStatus == null || serverStatus == this.serverStatus)) {
      return this;
    }
    return RoastIssuedInvitation(
      participantName: participantName,
      participantPublicKeyHex: participantPublicKeyHex,
      encoded: encoded,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      copiedAt: copiedAt ?? this.copiedAt,
      sentAt: sentAt ?? this.sentAt,
      joinedAt: joinedAt ?? this.joinedAt,
      serverStatus: serverStatus ?? this.serverStatus,
    );
  }

  Map<String, Object?> toJson() => {
    'participantName': participantName,
    'participantPublicKeyHex': participantPublicKeyHex,
    'encoded': encoded,
    'issuedAt': issuedAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'copiedAt': copiedAt?.toUtc().toIso8601String(),
    'sentAt': sentAt?.toUtc().toIso8601String(),
    'joinedAt': joinedAt?.toUtc().toIso8601String(),
    'serverStatus': serverStatus.name,
  };

  factory RoastIssuedInvitation.fromJson(Map<Object?, Object?> json) =>
      RoastIssuedInvitation(
        participantName: json['participantName']! as String,
        participantPublicKeyHex: json['participantPublicKeyHex']! as String,
        encoded: json['encoded']! as String,
        issuedAt: DateTime.parse(json['issuedAt']! as String),
        expiresAt: DateTime.parse(json['expiresAt']! as String),
        copiedAt: _dateTime(json['copiedAt']),
        sentAt: _dateTime(json['sentAt']),
        joinedAt: _dateTime(json['joinedAt']),
        serverStatus: RoastInvitationServerStatus.values.byName(
          json['serverStatus'] as String? ??
              RoastInvitationServerStatus.pending.name,
        ),
      );

  static DateTime? _dateTime(Object? value) =>
      value is String ? DateTime.parse(value) : null;
}
