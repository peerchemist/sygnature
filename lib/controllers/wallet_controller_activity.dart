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
        } on Object catch (_) {
          operation = operation.copyWith(
            state: RoastSigningOperationState.interrupted,
            errorMessage:
                'The interrupted signing operation could not be restored.',
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
    DateTime? expiresAt,
    String? reference,
    String? details,
    String? signedMessagePublicKeyHex,
    String? signedMessageSignatureHex,
    String? signedMessageEncoded,
    List<WalletActivityRecipient>? transactionRecipients,
    int? transactionFeeSats,
    int? transactionNetSats,
    List<String>? transactionInputOutpoints,
  }) async {
    try {
      await _updateVault((current) {
        if (current == null) return current;
        final index = current.activities.indexWhere((item) => item.id == id);
        late final List<WalletActivity> activities;
        if (index == -1) {
          final activity = WalletActivity(
            id: id,
            accountId: accountId,
            type: type,
            occurredAt: DateTime.now().toUtc(),
            expiresAt: expiresAt,
            reference: reference,
            details: details,
            signedMessagePublicKeyHex: signedMessagePublicKeyHex,
            signedMessageSignatureHex: signedMessageSignatureHex,
            signedMessageEncoded: signedMessageEncoded,
            transactionRecipients: transactionRecipients ?? const [],
            transactionFeeSats: transactionFeeSats,
            transactionNetSats: transactionNetSats,
            transactionInputOutpoints: transactionInputOutpoints ?? const [],
          );
          activities = _limitNonTransactionActivities([
            activity,
            ...current.activities,
          ]);
        } else {
          final previous = current.activities[index];
          final updated = previous.copyWith(
            expiresAt: expiresAt,
            details: details,
            signedMessagePublicKeyHex: signedMessagePublicKeyHex,
            signedMessageSignatureHex: signedMessageSignatureHex,
            signedMessageEncoded: signedMessageEncoded,
            transactionRecipients: transactionRecipients,
            transactionFeeSats: transactionFeeSats,
            transactionNetSats: transactionNetSats,
            transactionInputOutpoints: transactionInputOutpoints,
          );
          if (updated.expiresAt == previous.expiresAt &&
              updated.details == previous.details &&
              updated.signedMessagePublicKeyHex ==
                  previous.signedMessagePublicKeyHex &&
              updated.signedMessageSignatureHex ==
                  previous.signedMessageSignatureHex &&
              updated.signedMessageEncoded == previous.signedMessageEncoded &&
              listEquals(
                updated.transactionRecipients,
                previous.transactionRecipients,
              ) &&
              updated.transactionFeeSats == previous.transactionFeeSats &&
              updated.transactionNetSats == previous.transactionNetSats &&
              listEquals(
                updated.transactionInputOutpoints,
                previous.transactionInputOutpoints,
              )) {
            return current;
          }
          activities = [...current.activities];
          activities[index] = updated;
        }
        return current.copyWith(activities: activities);
      });
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Unable to persist wallet activity',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _setTransactionStatus({
    required String accountId,
    required String transactionId,
    required WalletTransactionStatus status,
    int? blockHeight,
    String? details,
    List<String>? inputOutpoints,
    String? rawTransactionHex,
  }) async {
    try {
      await _updateVault((current) {
        if (current == null) return current;
        final id = 'transaction-broadcast:$accountId:$transactionId';
        final index = current.activities.indexWhere(
          (activity) => activity.id == id,
        );
        final activities = [...current.activities];
        if (index == -1) {
          activities.insert(
            0,
            WalletActivity(
              id: id,
              accountId: accountId,
              type: WalletActivityType.transactionBroadcast,
              occurredAt: DateTime.now().toUtc(),
              reference: transactionId,
              details: details,
              transactionStatus: status,
              blockHeight: blockHeight,
              transactionInputOutpoints: inputOutpoints ?? const [],
              rawTransactionHex: rawTransactionHex,
            ),
          );
          final limited = _limitNonTransactionActivities(activities);
          activities
            ..clear()
            ..addAll(limited);
        } else {
          final activity = activities[index];
          final chainAlreadySawTransaction =
              activity.transactionStatus == WalletTransactionStatus.mempool ||
              activity.transactionStatus == WalletTransactionStatus.confirmed;
          final networkOnlyStatus =
              status == WalletTransactionStatus.broadcasting ||
              status == WalletTransactionStatus.broadcast ||
              status == WalletTransactionStatus.failed;
          final keepChainStatus =
              chainAlreadySawTransaction && networkOnlyStatus;
          activities[index] = activity.copyWith(
            transactionStatus: keepChainStatus
                ? activity.transactionStatus
                : status,
            blockHeight: blockHeight,
            details: keepChainStatus ? null : details,
            clearDetails: keepChainStatus || details == null,
            transactionInputOutpoints: inputOutpoints,
            rawTransactionHex: rawTransactionHex,
          );
        }
        return current.copyWith(activities: activities);
      });
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Unable to persist transaction status',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _reconcileTransactionStatuses(
    String address,
    List<ElectrumxTransactionHistoryEntry> history,
  ) async {
    try {
      await _updateVault((current) {
        if (current == null) return current;
        final accountIds = current.accounts
            .where(
              (account) =>
                  ownedAddressesFor(account)
                      .any((owned) => owned.address == address),
            )
            .map((account) => account.id)
            .toSet();
        final transactions = <String, ElectrumxTransactionHistoryEntry>{
          for (final entry in history) entry.transactionId: entry,
        };
        final spendersByOutpoint = <String, Set<String>>{};
        for (final entry in history) {
          for (final outpoint in entry.inputOutpoints) {
            spendersByOutpoint
                .putIfAbsent(outpoint, () => <String>{})
                .add(entry.transactionId);
          }
        }
        for (final activity in current.activities) {
          if (!accountIds.contains(activity.accountId) ||
              activity.reference == null ||
              !activity.type.isTransaction) {
            continue;
          }
          for (final outpoint in activity.transactionInputOutpoints) {
            spendersByOutpoint
                .putIfAbsent(outpoint, () => <String>{})
                .add(activity.reference!);
          }
        }
        final conflictedIds = <String>{};
        for (final spenders in spendersByOutpoint.values) {
          if (spenders.length < 2) continue;
          final confirmed = spenders
              .where((id) => transactions[id]?.isConfirmed ?? false)
              .toSet();
          conflictedIds.addAll(
            confirmed.length == 1 ? spenders.difference(confirmed) : spenders,
          );
        }
        String? findCompetingTransaction(
          String? transactionId,
          Iterable<String> outpoints,
        ) {
          for (final outpoint in outpoints) {
            for (final candidate
                in spendersByOutpoint[outpoint] ?? const <String>{}) {
              if (candidate != transactionId) return candidate;
            }
          }
          return null;
        }

        List<WalletActivityRecipient> recipientsFor(
          ElectrumxTransactionHistoryEntry entry,
        ) => [
          for (final output in entry.outputs)
            if (output.address case final address?)
              WalletActivityRecipient(
                address: address,
                amountSats: output.value,
              ),
        ];
        String? conflictDetails(String? transactionId) => transactionId == null
            ? null
            : 'Conflicts with transaction $transactionId, which spends one or '
                  'more of the same inputs.';

        var changed = false;
        final activities = <WalletActivity>[];
        for (final activity in current.activities) {
          final entry = transactions[activity.reference];
          if (!activity.type.isTransaction ||
              !accountIds.contains(activity.accountId)) {
            activities.add(activity);
            continue;
          }
          final competingTransactionId = entry == null
              ? findCompetingTransaction(
                  activity.reference,
                  activity.transactionInputOutpoints,
                )
              : conflictedIds.contains(entry.transactionId)
              ? findCompetingTransaction(
                  entry.transactionId,
                  entry.inputOutpoints,
                )
              : null;
          final synchronizedActivity = activity.id.startsWith(
            'transaction-chain:',
          );
          final status = competingTransactionId != null
              ? WalletTransactionStatus.conflicted
              : entry == null
              ? synchronizedActivity
                    ? WalletTransactionStatus.dropped
                    : switch (activity.transactionStatus) {
                        WalletTransactionStatus.confirmed ||
                        WalletTransactionStatus.mempool =>
                          WalletTransactionStatus.broadcast,
                        _ => activity.transactionStatus,
                      }
              : entry.isConfirmed
              ? WalletTransactionStatus.confirmed
              : WalletTransactionStatus.mempool;
          final blockHeight = entry?.isConfirmed ?? false
              ? entry!.height
              : null;
          final recipients = entry == null
              ? activity.transactionRecipients
              : recipientsFor(entry);
          final details = conflictDetails(competingTransactionId);
          final updated = activity.copyWith(
            transactionStatus: status,
            blockHeight: blockHeight,
            clearBlockHeight: blockHeight == null,
            transactionConfirmations: entry?.confirmations,
            clearTransactionConfirmations: entry?.confirmations == null,
            details: details,
            clearDetails: details == null,
            transactionRecipients: recipients.isEmpty ? null : recipients,
            transactionFeeSats: entry?.feeSats,
            transactionNetSats: entry?.netSats,
            transactionInputOutpoints:
                entry == null || entry.inputOutpoints.isEmpty
                ? null
                : entry.inputOutpoints,
          );
          if (_sameTransactionActivity(activity, updated)) {
            activities.add(activity);
            continue;
          }
          changed = true;
          activities.add(updated);
        }
        for (final entry in history) {
          if (!entry.hasTransactionDetails ||
              activities.any(
                (activity) =>
                    accountIds.contains(activity.accountId) &&
                    activity.reference == entry.transactionId &&
                    activity.type.isTransaction,
              )) {
            continue;
          }
          final status = conflictedIds.contains(entry.transactionId)
              ? WalletTransactionStatus.conflicted
              : entry.isConfirmed
              ? WalletTransactionStatus.confirmed
              : WalletTransactionStatus.mempool;
          final competingTransactionId =
              status == WalletTransactionStatus.conflicted
              ? findCompetingTransaction(
                  entry.transactionId,
                  entry.inputOutpoints,
                )
              : null;
          final recipients = recipientsFor(entry);
          for (final accountId in accountIds) {
            activities.insert(
              0,
              WalletActivity(
                id: 'transaction-chain:$accountId:${entry.transactionId}',
                accountId: accountId,
                type: entry.netSats! < 0
                    ? WalletActivityType.transactionBroadcast
                    : WalletActivityType.transactionReceived,
                occurredAt: entry.timestamp ?? DateTime.now().toUtc(),
                reference: entry.transactionId,
                details: conflictDetails(competingTransactionId),
                transactionStatus: status,
                blockHeight: entry.isConfirmed ? entry.height : null,
                transactionConfirmations: entry.confirmations,
                transactionRecipients: recipients,
                transactionFeeSats: entry.feeSats,
                transactionNetSats: entry.netSats,
                transactionInputOutpoints: entry.inputOutpoints,
              ),
            );
          }
          changed = true;
        }
        if (!changed) return current;
        return current.copyWith(activities: activities);
      });
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Unable to persist synchronized transaction statuses',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  bool _sameTransactionActivity(WalletActivity first, WalletActivity second) =>
      first.transactionStatus == second.transactionStatus &&
      first.blockHeight == second.blockHeight &&
      first.transactionConfirmations == second.transactionConfirmations &&
      first.details == second.details &&
      listEquals(first.transactionRecipients, second.transactionRecipients) &&
      first.transactionFeeSats == second.transactionFeeSats &&
      first.transactionNetSats == second.transactionNetSats &&
      listEquals(
        first.transactionInputOutpoints,
        second.transactionInputOutpoints,
      );

  List<WalletActivity> _limitNonTransactionActivities(
    List<WalletActivity> activities,
  ) {
    var remaining = WalletController._maxActivityEntries;
    return [
      for (final activity in activities)
        if (activity.type.isTransaction || remaining-- > 0) activity,
    ];
  }

  Future<void> _recordSetupActivity(
    RoastSetup setup, {
    required String id,
    required WalletActivityType type,
    String? reference,
    String? details,
    String? signedMessagePublicKeyHex,
    String? signedMessageSignatureHex,
    String? signedMessageEncoded,
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
      signedMessagePublicKeyHex: signedMessagePublicKeyHex,
      signedMessageSignatureHex: signedMessageSignatureHex,
      signedMessageEncoded: signedMessageEncoded,
    );
  }

  Future<RoastSigningOperation> _completeRoastSigningOperation(
    RoastSigningOperation operation,
  ) async {
    final transaction = ThresholdWalletTransaction.fromJson(
      operation.thresholdTransaction,
    );
    final signatures = [
      for (final signature in operation.signaturesHex) hexToBytes(signature),
    ];
    final signed = _transactionService.completeThresholdSigning(
      transaction: transaction,
      signatures: signatures,
      expectedInternalKeysHex: operation.expectedInternalKeysHex,
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
