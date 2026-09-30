enum WalletActivityType {
  signatureRequestReceived,
  signatureRequestApproved,
  signatureRequestRejected,
  signatureRequestExpired,
  dkgStarted,
  dkgCompleted,
  dkgFailed,
  transactionSignatureRequested,
  transactionSigned,
  transactionBroadcast,
  messageSignatureRequested,
  messageSigned,
}

enum WalletTransactionStatus {
  broadcasting,
  broadcast,
  mempool,
  confirmed,
  failed,
}

class WalletActivity({
  required final String id,
  required final String accountId,
  required final WalletActivityType type,
  required final DateTime occurredAt,
  final String? reference,
  final String? details,
  final String? signedMessagePublicKeyHex,
  final String? signedMessageSignatureHex,
  final String? signedMessageEncoded,
  final WalletTransactionStatus? transactionStatus,
  final int? blockHeight,
}) {
  WalletActivity copyWith({
    WalletTransactionStatus? transactionStatus,
    int? blockHeight,
    String? details,
    String? signedMessagePublicKeyHex,
    String? signedMessageSignatureHex,
    String? signedMessageEncoded,
    bool clearDetails = false,
    bool clearBlockHeight = false,
  }) => WalletActivity(
    id: id,
    accountId: accountId,
    type: type,
    occurredAt: occurredAt,
    reference: reference,
    details: clearDetails ? null : details ?? this.details,
    signedMessagePublicKeyHex:
        signedMessagePublicKeyHex ?? this.signedMessagePublicKeyHex,
    signedMessageSignatureHex:
        signedMessageSignatureHex ?? this.signedMessageSignatureHex,
    signedMessageEncoded: signedMessageEncoded ?? this.signedMessageEncoded,
    transactionStatus: transactionStatus ?? this.transactionStatus,
    blockHeight: clearBlockHeight ? null : blockHeight ?? this.blockHeight,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'accountId': accountId,
    'type': type.name,
    'occurredAt': occurredAt.toUtc().toIso8601String(),
    'reference': reference,
    'details': details,
    'signedMessagePublicKeyHex': signedMessagePublicKeyHex,
    'signedMessageSignatureHex': signedMessageSignatureHex,
    'signedMessageEncoded': signedMessageEncoded,
    'transactionStatus': transactionStatus?.name,
    'blockHeight': blockHeight,
  };

  factory WalletActivity.fromJson(Map<Object?, Object?> json) => WalletActivity(
    id: json['id']! as String,
    accountId: json['accountId']! as String,
    type: WalletActivityType.values.byName(json['type']! as String),
    occurredAt: DateTime.parse(json['occurredAt']! as String),
    reference: json['reference'] as String?,
    details: json['details'] as String?,
    signedMessagePublicKeyHex: json['signedMessagePublicKeyHex'] as String?,
    signedMessageSignatureHex: json['signedMessageSignatureHex'] as String?,
    signedMessageEncoded: json['signedMessageEncoded'] as String?,
    transactionStatus: switch (json['transactionStatus']) {
      final String value => WalletTransactionStatus.values.byName(value),
      _ => null,
    },
    blockHeight: json['blockHeight'] as int?,
  );
}
