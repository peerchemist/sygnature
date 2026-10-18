enum WalletActivityType {
  signatureRequestReceived,
  signatureRequestApproved,
  signatureRequestRejected,
  signatureRequestCancelled,
  signatureRequestExpired,
  dkgStarted,
  dkgCompleted,
  dkgFailed,
  transactionSignatureRequested,
  transactionSigned,
  transactionBroadcast,
  transactionReceived,
  messageSignatureRequested,
  messageSigned;

  bool get isTransaction =>
      this == transactionBroadcast || this == transactionReceived;
}

enum WalletTransactionStatus {
  broadcasting,
  broadcast,
  mempool,
  confirmed,
  dropped,
  conflicted,
  failed,
}

class const WalletActivityRecipient({
  required final String address,
  required final int amountSats,
}) {
  Map<String, Object?> toJson() => {
    'address': address,
    'amountSats': amountSats,
  };

  factory WalletActivityRecipient.fromJson(Map<Object?, Object?> json) =>
      WalletActivityRecipient(
        address: json['address']! as String,
        amountSats: json['amountSats']! as int,
      );

  @override
  bool operator ==(Object other) =>
      other is WalletActivityRecipient &&
      other.address == address &&
      other.amountSats == amountSats;

  @override
  int get hashCode => Object.hash(address, amountSats);
}

class WalletActivity({
  required final String id,
  required final String accountId,
  required final WalletActivityType type,
  required final DateTime occurredAt,
  final DateTime? expiresAt,
  final String? reference,
  final String? details,
  final String? signedMessagePublicKeyHex,
  final String? signedMessageSignatureHex,
  final String? signedMessageEncoded,
  final WalletTransactionStatus? transactionStatus,
  final int? blockHeight,
  final int? transactionConfirmations,
  final List<WalletActivityRecipient> transactionRecipients = const [],
  final int? transactionFeeSats,
  final int? transactionNetSats,
  final List<String> transactionInputOutpoints = const [],
  final String? rawTransactionHex,
}) {
  bool get canRetryBroadcast =>
      type == WalletActivityType.transactionBroadcast &&
      reference != null &&
      rawTransactionHex != null &&
      (transactionStatus == WalletTransactionStatus.broadcasting ||
          transactionStatus == WalletTransactionStatus.failed);

  WalletActivity copyWith({
    DateTime? expiresAt,
    WalletTransactionStatus? transactionStatus,
    int? blockHeight,
    int? transactionConfirmations,
    String? details,
    String? signedMessagePublicKeyHex,
    String? signedMessageSignatureHex,
    String? signedMessageEncoded,
    List<WalletActivityRecipient>? transactionRecipients,
    int? transactionFeeSats,
    int? transactionNetSats,
    List<String>? transactionInputOutpoints,
    String? rawTransactionHex,
    bool clearDetails = false,
    bool clearBlockHeight = false,
    bool clearTransactionConfirmations = false,
  }) => WalletActivity(
    id: id,
    accountId: accountId,
    type: type,
    occurredAt: occurredAt,
    expiresAt: expiresAt ?? this.expiresAt,
    reference: reference,
    details: clearDetails ? null : details ?? this.details,
    signedMessagePublicKeyHex:
        signedMessagePublicKeyHex ?? this.signedMessagePublicKeyHex,
    signedMessageSignatureHex:
        signedMessageSignatureHex ?? this.signedMessageSignatureHex,
    signedMessageEncoded: signedMessageEncoded ?? this.signedMessageEncoded,
    transactionStatus: transactionStatus ?? this.transactionStatus,
    blockHeight: clearBlockHeight ? null : blockHeight ?? this.blockHeight,
    transactionConfirmations: clearTransactionConfirmations
        ? null
        : transactionConfirmations ?? this.transactionConfirmations,
    transactionRecipients: transactionRecipients ?? this.transactionRecipients,
    transactionFeeSats: transactionFeeSats ?? this.transactionFeeSats,
    transactionNetSats: transactionNetSats ?? this.transactionNetSats,
    transactionInputOutpoints:
        transactionInputOutpoints ?? this.transactionInputOutpoints,
    rawTransactionHex: rawTransactionHex ?? this.rawTransactionHex,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'accountId': accountId,
    'type': type.name,
    'occurredAt': occurredAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'reference': reference,
    'details': details,
    'signedMessagePublicKeyHex': signedMessagePublicKeyHex,
    'signedMessageSignatureHex': signedMessageSignatureHex,
    'signedMessageEncoded': signedMessageEncoded,
    'transactionStatus': transactionStatus?.name,
    'blockHeight': blockHeight,
    'transactionConfirmations': transactionConfirmations,
    'transactionRecipients': transactionRecipients
        .map((recipient) => recipient.toJson())
        .toList(),
    'transactionFeeSats': transactionFeeSats,
    'transactionNetSats': transactionNetSats,
    'transactionInputOutpoints': transactionInputOutpoints,
    'rawTransactionHex': rawTransactionHex,
  };

  factory WalletActivity.fromJson(Map<Object?, Object?> json) => WalletActivity(
    id: json['id']! as String,
    accountId: json['accountId']! as String,
    type: WalletActivityType.values.byName(json['type']! as String),
    occurredAt: DateTime.parse(json['occurredAt']! as String),
    expiresAt: switch (json['expiresAt']) {
      final String value => DateTime.parse(value),
      _ => null,
    },
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
    transactionConfirmations: json['transactionConfirmations'] as int?,
    transactionRecipients:
        ((json['transactionRecipients'] as List?) ?? const [])
            .map(
              (recipient) => WalletActivityRecipient.fromJson(
                recipient as Map<Object?, Object?>,
              ),
            )
            .toList(growable: false),
    transactionFeeSats: json['transactionFeeSats'] as int?,
    transactionNetSats: json['transactionNetSats'] as int?,
    transactionInputOutpoints:
        ((json['transactionInputOutpoints'] as List?) ?? const [])
            .cast<String>()
            .toList(growable: false),
    rawTransactionHex: json['rawTransactionHex'] as String?,
  );
}
