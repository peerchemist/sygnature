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
  interrupted,
}

class RoastSigningOperation({
  required final String setupId,
  required final String accountId,
  required final String requestIdHex,
  required final String proposalHex,
  required final String expectedInternalKeyHex,
  required final List<int> derivationPath,
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
}) {
  String get storageId => '$setupId:$requestIdHex';

  bool get reservesUtxos =>
      rawTransactionHex == null && expiry.isBefore(DateTime.now())
      ? false
      : switch (state) {
          RoastSigningOperationState.broadcasted ||
          RoastSigningOperationState.expired ||
          RoastSigningOperationState.rejected => false,
          _ => true,
        };

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
    bool clearError = false,
  }) => RoastSigningOperation(
    setupId: setupId,
    accountId: accountId,
    requestIdHex: requestIdHex,
    proposalHex: proposalHex,
    expectedInternalKeyHex: expectedInternalKeyHex,
    derivationPath: derivationPath,
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
  );

  Map<String, Object?> toJson() => {
    'setupId': setupId,
    'accountId': accountId,
    'requestIdHex': requestIdHex,
    'proposalHex': proposalHex,
    'expectedInternalKeyHex': expectedInternalKeyHex,
    'derivationPath': derivationPath,
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
  };

  factory RoastSigningOperation.fromJson(Map<Object?, Object?> json) =>
      RoastSigningOperation(
        setupId: json['setupId']! as String,
        accountId: json['accountId']! as String,
        requestIdHex: json['requestIdHex']! as String,
        proposalHex: json['proposalHex']! as String,
        expectedInternalKeyHex: json['expectedInternalKeyHex']! as String,
        derivationPath: (json['derivationPath']! as List).cast<int>(),
        thresholdTransaction: Map<String, Object?>.from(
          json['thresholdTransaction']! as Map,
        ),
        reservedOutpoints: (json['reservedOutpoints']! as List).cast<String>(),
        expiry: DateTime.parse(json['expiry']! as String),
        state: RoastSigningOperationState.values.byName(
          json['state']! as String,
        ),
        updatedAt: DateTime.parse(json['updatedAt']! as String),
        signaturesHex: ((json['signaturesHex'] as List?) ?? const [])
            .cast<String>(),
        rawTransactionHex: json['rawTransactionHex'] as String?,
        transactionId: json['transactionId'] as String?,
        serverTransactionId: json['serverTransactionId'] as String?,
        errorMessage: json['errorMessage'] as String?,
      );
}
