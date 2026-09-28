part of 'wallet_controller.dart';

extension WalletActivityController on WalletController {
  List<WalletActivity> activitiesFor(WalletAccount account) {
    final activities = (_vault?.activities ?? const [])
        .where((activity) => activity.accountId == account.id)
        .toList(growable: false);
    final localMessageRequestIds = {
      for (final activity in activities)
        if (activity.type == WalletActivityType.messageSignatureRequested &&
            activity.reference != null)
          activity.reference,
    };
    return activities
        .where(
          (activity) =>
              activity.type != WalletActivityType.signatureRequestApproved ||
              !localMessageRequestIds.contains(activity.reference),
        )
        .toList(growable: false);
  }

  Future<void> _restoreRoastSigningOperations() async {
    final operations = await _roastSigningOperations.loadSigningOperations();
    for (var operation in operations) {
      if (operation.state == RoastSigningOperationState.broadcasting) {
        operation = operation.copyWith(
          state: RoastSigningOperationState.broadcastUnknown,
          errorMessage: 'The previous broadcast outcome is unknown.',
        );
        await _saveRoastSigningOperation(operation);
      } else if (operation.rawTransactionHex == null &&
          operation.signaturesHex.isNotEmpty) {
        try {
          operation = await _completeRoastSigningOperation(operation);
        } on Object catch (error) {
          operation = operation.copyWith(
            state: RoastSigningOperationState.interrupted,
            errorMessage: '$error',
          );
          await _saveRoastSigningOperation(operation);
        }
      } else if (operation.rawTransactionHex == null &&
          operation.expiry.isBefore(DateTime.now())) {
        operation = operation.copyWith(
          state: RoastSigningOperationState.expired,
          errorMessage: 'The ROAST signing request expired.',
        );
        await _saveRoastSigningOperation(operation);
        await _recordActivity(
          id: 'signature-request-expired:${operation.storageId}',
          accountId: operation.accountId,
          type: WalletActivityType.signatureRequestExpired,
          reference: operation.requestIdHex,
        );
      } else if (operation.rawTransactionHex == null &&
          (operation.state == RoastSigningOperationState.prepared ||
              operation.state == RoastSigningOperationState.requesting ||
              operation.state ==
                  RoastSigningOperationState.awaitingSignatures)) {
        operation = operation.copyWith(
          state: RoastSigningOperationState.interrupted,
          errorMessage: 'The previous signing request outcome is unknown.',
        );
        await _saveRoastSigningOperation(operation);
      } else {
        _storedRoastSigningOperations[operation.storageId] = operation;
      }
    }
  }

  Future<void> _saveRoastSigningOperation(
    RoastSigningOperation operation,
  ) async {
    await _roastSigningOperations.putSigningOperation(operation);
    _storedRoastSigningOperations[operation.storageId] = operation;
    _notifyListeners();
  }

  Future<void> _recordActivity({
    required String id,
    required String accountId,
    required WalletActivityType type,
    String? reference,
    String? details,
  }) async {
    final current = _vault;
    if (current == null || current.activities.any((item) => item.id == id)) {
      return;
    }
    final activity = WalletActivity(
      id: id,
      accountId: accountId,
      type: type,
      occurredAt: DateTime.now().toUtc(),
      reference: reference,
      details: details,
    );
    final next = current.copyWith(
      activities: [
        activity,
        ...current.activities,
      ].take(WalletController._maxActivityEntries).toList(growable: false),
    );
    try {
      await _repository.save(next);
      _vault = next;
      _notifyListeners();
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Unable to persist wallet activity',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _recordSetupActivity(
    RoastSetup setup, {
    required String id,
    required WalletActivityType type,
    String? reference,
    String? details,
  }) async {
    final account = accounts
        .where((item) => item.sourceId == setup.id)
        .firstOrNull;
    if (account == null) return;
    await _recordActivity(
      id: id,
      accountId: account.id,
      type: type,
      reference: reference,
      details: details,
    );
  }

  Future<RoastSigningOperation> _completeRoastSigningOperation(
    RoastSigningOperation operation,
  ) async {
    final signed = _transactionService.completeThresholdSigning(
      transaction: ThresholdWalletTransaction.fromJson(
        operation.thresholdTransaction,
      ),
      signatures: [
        for (final signature in operation.signaturesHex) hexToBytes(signature),
      ],
      expectedInternalKeyHex: operation.expectedInternalKeyHex,
    );
    final completed = operation.copyWith(
      state: RoastSigningOperationState.signed,
      rawTransactionHex: signed.rawTransactionHex,
      transactionId: signed.transactionId,
      clearError: true,
    );
    await _saveRoastSigningOperation(completed);
    await _recordActivity(
      id: 'transaction-signed:${operation.storageId}',
      accountId: operation.accountId,
      type: WalletActivityType.transactionSigned,
      reference: signed.transactionId,
    );
    return completed;
  }
}
