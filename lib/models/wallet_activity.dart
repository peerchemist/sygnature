enum WalletActivityType {
  signatureRequestReceived,
  signatureRequestApproved,
  signatureRequestRejected,
  signatureRequestExpired,
  dkgStarted,
  dkgCompleted,
  dkgFailed,
  transactionSigned,
  transactionBroadcast,
  messageSignatureRequested,
  messageSigned,
}

class WalletActivity({
  required final String id,
  required final String accountId,
  required final WalletActivityType type,
  required final DateTime occurredAt,
  final String? reference,
  final String? details,
}) {
  Map<String, Object?> toJson() => {
    'id': id,
    'accountId': accountId,
    'type': type.name,
    'occurredAt': occurredAt.toUtc().toIso8601String(),
    'reference': reference,
    'details': details,
  };

  factory WalletActivity.fromJson(Map<Object?, Object?> json) => WalletActivity(
    id: json['id']! as String,
    accountId: json['accountId']! as String,
    type: WalletActivityType.values.byName(json['type']! as String),
    occurredAt: DateTime.parse(json['occurredAt']! as String),
    reference: json['reference'] as String?,
    details: json['details'] as String?,
  );
}
