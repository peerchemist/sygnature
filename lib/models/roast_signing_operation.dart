enum RoastSigningOperationState {
  prepared,
  requesting,
  awaitingSignatures,
  signed,
  broadcasting,
  broadcastUnknown,
  broadcasted,
  expired,
  rejected,
  cancelled,
  interrupted,
}

class RoastSigningOperation({
  required final String setupId,
  required final String accountId,
  required final String requestIdHex,
  required final String proposalHex,
  required final List<String> expectedInternalKeysHex,
  required final Map<String, Object?> thresholdTransaction,
  required final List<String> reservedOutpoints,
  required final DateTime expiry,
  required final RoastSigningOperationState state,
  required final DateTime updatedAt,
  final List<String> signaturesHex = const [],
  final String? rawTransactionHex,
  final String? transactionId,
  final String? serverTransactionId,
  final String? errorMessage,
  final bool reservationsReleased = false,
}) {
  static const schemaVersion = 2;

  String get storageId => '$setupId:$requestIdHex';

  bool get reservesUtxos {
    if (reservationsReleased ||
        (rawTransactionHex == null && expiry.isBefore(DateTime.now()))) {
      return false;
    }
    return switch (state) {
      RoastSigningOperationState.expired ||
      RoastSigningOperationState.rejected ||
      RoastSigningOperationState.cancelled => false,
      _ => true,
    };
  }

  bool get canRetryBroadcast =>
      rawTransactionHex != null &&
      transactionId != null &&
      (state == RoastSigningOperationState.signed ||
          state == RoastSigningOperationState.broadcasting ||
          state == RoastSigningOperationState.broadcastUnknown);

  RoastSigningOperation copyWith({
    RoastSigningOperationState? state,
    List<String>? signaturesHex,
    String? rawTransactionHex,
    String? transactionId,
    String? serverTransactionId,
    String? errorMessage,
    bool? reservationsReleased,
    bool clearError = false,
  }) => RoastSigningOperation(
    setupId: setupId,
    accountId: accountId,
    requestIdHex: requestIdHex,
    proposalHex: proposalHex,
    expectedInternalKeysHex: expectedInternalKeysHex,
    thresholdTransaction: thresholdTransaction,
    reservedOutpoints: reservedOutpoints,
    expiry: expiry,
    state: state ?? this.state,
    updatedAt: DateTime.now().toUtc(),
    signaturesHex: signaturesHex ?? this.signaturesHex,
    rawTransactionHex: rawTransactionHex ?? this.rawTransactionHex,
    transactionId: transactionId ?? this.transactionId,
    serverTransactionId: serverTransactionId ?? this.serverTransactionId,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    reservationsReleased: reservationsReleased ?? this.reservationsReleased,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'setupId': setupId,
    'accountId': accountId,
    'requestIdHex': requestIdHex,
    'proposalHex': proposalHex,
    'expectedInternalKeysHex': expectedInternalKeysHex,
    'thresholdTransaction': thresholdTransaction,
    'reservedOutpoints': reservedOutpoints,
    'expiry': expiry.toUtc().toIso8601String(),
    'state': state.name,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'signaturesHex': signaturesHex,
    'rawTransactionHex': rawTransactionHex,
    'transactionId': transactionId,
    'serverTransactionId': serverTransactionId,
    'errorMessage': errorMessage,
    'reservationsReleased': reservationsReleased,
  };

  factory RoastSigningOperation.fromJson(Map<Object?, Object?> json) {
    if (json['schemaVersion'] != schemaVersion) {
      throw const FormatException('Unsupported ROAST signing operation.');
    }
    return RoastSigningOperation(
      setupId: json['setupId']! as String,
      accountId: json['accountId']! as String,
      requestIdHex: json['requestIdHex']! as String,
      proposalHex: json['proposalHex']! as String,
      expectedInternalKeysHex: (json['expectedInternalKeysHex']! as List)
          .cast<String>(),
      thresholdTransaction: Map<String, Object?>.from(
        json['thresholdTransaction']! as Map,
      ),
      reservedOutpoints: (json['reservedOutpoints']! as List).cast<String>(),
      expiry: DateTime.parse(json['expiry']! as String),
      state: RoastSigningOperationState.values.byName(json['state']! as String),
      updatedAt: DateTime.parse(json['updatedAt']! as String),
      signaturesHex: ((json['signaturesHex'] as List?) ?? const [])
          .cast<String>(),
      rawTransactionHex: json['rawTransactionHex'] as String?,
      transactionId: json['transactionId'] as String?,
      serverTransactionId: json['serverTransactionId'] as String?,
      errorMessage: json['errorMessage'] as String?,
      reservationsReleased: json['reservationsReleased'] as bool? ?? false,
    );
  }
}
