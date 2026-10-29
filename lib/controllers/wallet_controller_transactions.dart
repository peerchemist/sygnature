part of 'wallet_controller.dart';

String _utxoKey(ElectrumxUtxo utxo) => '${utxo.txHash}:${utxo.txPos}';

extension WalletTransactionController on WalletController {
  Future<void> refreshBalances() => _restartElectrumxSync();

  WalletTransactionPreview prepareSend(WalletSendRequest request) {
    final account = selectedAccount;
    final address = account?.address;
    if (account == null ||
        account.derivationState != WalletDerivationState.ready ||
        address == null) {
      throw const WalletSigningUnavailable();
    }
    final owned = ownedAddressesFor(account);
    if (owned.isEmpty) throw const WalletSigningUnavailable();
    WalletOwnedAddress change = owned.first;
    if (request.useNewChangeAddress) {
      final throughNext = _ownedAddressesThrough(
        account,
        account.highestAllocatedAddressIndex + 1,
      );
      if (throughNext.length != account.highestAllocatedAddressIndex + 2) {
        throw const WalletSigningUnavailable();
      }
      change = throughNext.last;
    }
    return _transactionService.prepare(
      accountId: account.id,
      network: networkForAccount(account),
      sourceAddress: address,
      availableUtxos: availableUtxosFor(account),
      request: request,
      ownedAddressPaths: {
        for (final item in owned) item.address: item.derivationPath,
      },
      changeAddress: change.address,
      changeDerivationPath: change.derivationPath,
      changeAddressIndex: change.index,
    );
  }

  static String _changeAllocationOperationId(
    WalletTransactionPreview preview,
  ) => bytesToHex(
    sha256Hash(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'account': preview.accountId,
            'destination': preview.destinationAddress,
            'amount': preview.amountSats,
            'fee': preview.feeSats,
            'feeRate': preview.feeRateSatsPerKb,
            'change': preview.changeSats,
            'changeAddress': preview.changeAddress,
            'changePath': preview.changeDerivationPath,
            'changeIndex': preview.changeAddressIndex,
            'message': preview.signingMessage,
            'inputs': [
              for (final utxo in preview.selectedUtxos)
                {
                  'outpoint': _utxoKey(utxo),
                  'address': utxo.address,
                  'value': utxo.value,
                },
            ],
          }),
        ),
      ),
    ),
  );

  Future<WalletSendResult> sendTransaction(
    WalletTransactionPreview preview, {
    Duration signatureRequestTimeout = defaultRoastSigningRequestTimeout,
  }) async {
    if (_backupInProgress) throw const WalletBusyFailure();
    if (_sending) {
      throw const WalletTransactionRejected(
        'Another transaction is already being submitted.',
      );
    }
    _sending = true;
    try {
      final reviewed = _validateSendPreview(preview);
      final account = reviewed is WalletAccount ? reviewed : await reviewed;
      final (signed, signingOperation) = switch (account.keySource) {
        WalletKeySource.watchOnly => throw const WalletSigningUnavailable(),
        WalletKeySource.personal => (
          await _signPersonalTransaction(account, preview),
          null,
        ),
        WalletKeySource.roast => await _signRoastTransaction(
          account,
          preview,
          signatureRequestTimeout,
        ),
      };
      return signingOperation == null
          ? await _broadcastSigned(
              account,
              signed,
              inputOutpoints: [
                for (final utxo in preview.selectedUtxos) _utxoKey(utxo),
              ],
            )
          : await _broadcastRoastOperation(account, signingOperation, signed);
    } on WalletTransactionFailure {
      rethrow;
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        '[WALLET SEND ${preview.accountId}] Transaction submission failed',
        error: error,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(
        WalletSubmissionFailure(_sendFailureMessage(error), cause: error),
        stackTrace,
      );
    } finally {
      _sending = false;
    }
  }

  // Keep validation synchronous unless change allocation needs persistence.
  FutureOr<WalletAccount> _validateSendPreview(
    WalletTransactionPreview preview,
  ) {
    final foundAccount = accounts
        .where((candidate) => candidate.id == preview.accountId)
        .firstOrNull;
    if (foundAccount == null ||
        foundAccount.derivationState != WalletDerivationState.ready) {
      throw const WalletSigningUnavailable();
    }
    final account = foundAccount;
    final reservedOutpoints = _reservedOutpointsFor(account.id);
    if (preview.selectedUtxos.any(
      (utxo) => reservedOutpoints.contains(_utxoKey(utxo)),
    )) {
      throw const WalletTransactionRejected(
        'A transaction input is reserved by another signing request.',
      );
    }
    final availableByOutpoint = {
      for (final utxo in availableUtxosFor(account)) _utxoKey(utxo): utxo,
    };
    final inputsStillMatch = preview.selectedUtxos.every((utxo) {
      final current = availableByOutpoint[_utxoKey(utxo)];
      return current != null &&
          current.address == utxo.address &&
          current.value == utxo.value &&
          preview.inputDerivationPaths.containsKey(utxo.address);
    });
    if (!inputsStillMatch) {
      throw const WalletTransactionRejected(
        'Wallet funds changed after review. Review the transaction again.',
      );
    }
    if (preview.changeSats > 0 && preview.changeAddressIndex > 0) {
      final allocationOperationId = _changeAllocationOperationId(preview);
      final operationIsKnown =
          _vault?.changeAllocationOperationIds.contains(
            allocationOperationId,
          ) ??
          false;
      final allocated = _ownedAddressesThrough(
        account,
        preview.changeAddressIndex,
      );
      final expected = allocated
          .where((owned) => owned.index == preview.changeAddressIndex)
          .firstOrNull;
      if (expected == null ||
          expected.address != preview.changeAddress ||
          expected.derivationPath != preview.changeDerivationPath ||
          preview.changeAddressIndex >
              account.highestAllocatedAddressIndex + 1 ||
          preview.changeAddressIndex <= account.highestAllocatedAddressIndex &&
              !operationIsKnown) {
        throw const WalletTransactionRejected(
          'Wallet state changed after review. Review the transaction again.',
        );
      }
      if (preview.changeAddressIndex > account.highestAllocatedAddressIndex) {
        return _allocateReviewedChange(account, preview, allocationOperationId);
      }
    }
    return account;
  }

  Future<WalletAccount> _allocateReviewedChange(
    WalletAccount account,
    WalletTransactionPreview preview,
    String allocationOperationId,
  ) async {
    await _updateVault((current) {
      if (current == null) throw StateError('Wallet is not initialized.');
      return current.copyWith(
        accounts: [
          for (final item in current.accounts)
            if (item.id == account.id)
              item.copyWith(
                highestAllocatedAddressIndex: preview.changeAddressIndex,
              )
            else
              item,
        ],
        changeAllocationOperationIds: [
          allocationOperationId,
          ...current.changeAllocationOperationIds,
        ].take(512).toList(growable: false),
      );
    });
    final updatedAccount = accounts.firstWhere(
      (item) => item.id == preview.accountId,
    );
    await _restartElectrumxSync();
    return updatedAccount;
  }

  Future<SignedWalletTransaction> _signPersonalTransaction(
    WalletAccount account,
    WalletTransactionPreview preview,
  ) async {
    final signed = _transactionService.sign(
      network: networkForAccount(account),
      preview: preview,
      privateKeysByAddress: {
        for (final owned in ownedAddressesFor(account))
          owned.address: ?owned.privateKeyHex,
      },
    );
    await _recordActivity(
      id: 'transaction-signed:${account.id}:${signed.transactionId}',
      accountId: account.id,
      type: WalletActivityType.transactionSigned,
      reference: signed.transactionId,
    );
    return signed;
  }

  Future<(SignedWalletTransaction, RoastSigningOperation?)>
  _signRoastTransaction(
    WalletAccount account,
    WalletTransactionPreview preview,
    Duration signatureRequestTimeout,
  ) async {
    final setup = setupForAccount(account);
    final runtime = _roastRuntime;
    if (setup == null || runtime == null || setup.groupKeyHex == null) {
      throw const WalletSigningUnavailable();
    }
    _requireRoastCoordinator(setup);
    final network = networkForAccount(account);
    final ownedByAddress = {
      for (final owned in ownedAddressesFor(account)) owned.address: owned,
    };
    final inputAddresses = [
      for (final utxo in preview.selectedUtxos)
        ownedByAddress[utxo.address] ??
            (throw const WalletTransactionRejected(
              'A transaction input does not belong to this wallet.',
            )),
    ];
    final transaction = _transactionService.prepareThresholdSigning(
      network: network,
      preview: preview,
    );
    final paths = [
      for (final owned in inputAddresses) _roastPath(owned.derivationPath),
    ];
    final inputInternalKeys = [
      for (final path in paths)
        _deriveRoastAddress(setup, account, path).internalKeyHex,
    ];
    final changeOutputIndex = preview.changeAddress == null
        ? null
        : transaction.transaction.outputs.lastIndexWhere(
            (output) =>
                bytesToHex(output.scriptPubKey) ==
                _roastKeyService.scriptHexForAddress(
                  network,
                  preview.changeAddress!,
                ),
          );
    final proposal = runtime.createTransactionSigningProposal(
      setup,
      transaction,
      paths,
      accountIndex: account.accountIndex,
      changeOutputIndex: changeOutputIndex == -1 ? null : changeOutputIndex,
      changeDerivationPath: preview.changeDerivationPath == null
          ? null
          : _roastPath(preview.changeDerivationPath!),
      message: preview.signingMessage,
      timeout: signatureRequestTimeout,
    );
    final pendingKey = '${setup.id}:${proposal.idHex}';
    final completer = Completer<_RoastSendOutcome>();
    _pendingRoastSends[pendingKey] = _PendingRoastSend(completer: completer);
    var signingOperation = RoastSigningOperation(
      setupId: setup.id,
      accountId: account.id,
      requestIdHex: proposal.idHex,
      proposalHex: proposal.proposalHex,
      expectedInternalKeysHex: inputInternalKeys,
      thresholdTransaction: transaction.toJson(),
      reservedOutpoints: [
        for (final utxo in preview.selectedUtxos) _utxoKey(utxo),
      ],
      expiry: proposal.expiry,
      state: RoastSigningOperationState.prepared,
      updatedAt: DateTime.now().toUtc(),
    );
    await _saveRoastSigningOperation(signingOperation);
    try {
      signingOperation = signingOperation.copyWith(
        state: RoastSigningOperationState.requesting,
      );
      await _saveRoastSigningOperation(signingOperation);
      signingOperation = signingOperation.copyWith(
        state: RoastSigningOperationState.awaitingSignatures,
      );
      await _saveRoastSigningOperation(signingOperation);
      await _recordActivity(
        id: 'transaction-signature-requested:$pendingKey',
        accountId: account.id,
        type: WalletActivityType.transactionSignatureRequested,
        expiresAt: proposal.expiry,
        reference: proposal.idHex,
        details: preview.signingMessage.isEmpty ? null : preview.signingMessage,
      );
      try {
        await runtime.requestSignatures(setup, proposal);
      } on Object catch (error, stackTrace) {
        Error.throwWithStackTrace(
          WalletSigningFailure(
            WalletSigningFailureKind.interrupted,
            'Could not send the approval request. Make sure the ROAST '
            'coordinator is running and connected, then try again.',
            cause: error,
          ),
          stackTrace,
        );
      }
      final outcome = await completer.future.timeout(
        proposal.expiry.difference(DateTime.now()),
        onTimeout: () => throw const WalletSigningFailure(
          WalletSigningFailureKind.expired,
          'The signing request expired before enough signatures arrived.',
        ),
      );
      if (outcome.error case final error?) {
        Error.throwWithStackTrace(
          error,
          outcome.stackTrace ?? StackTrace.current,
        );
      }
      return (outcome.signed!, _storedRoastSigningOperations[pendingKey]);
    } on Object catch (error, stackTrace) {
      final current = _storedRoastSigningOperations[pendingKey];
      if (current != null && current.rawTransactionHex == null) {
        final kind = switch (error) {
          _ when current.expiry.isBefore(DateTime.now()) =>
            WalletSigningFailureKind.expired,
          WalletSigningFailure(:final kind) => kind,
          _ => WalletSigningFailureKind.interrupted,
        };
        final (state, message) = switch (kind) {
          WalletSigningFailureKind.expired => (
            RoastSigningOperationState.expired,
            'The signing request expired before enough signatures arrived.',
          ),
          WalletSigningFailureKind.rejected => (
            RoastSigningOperationState.rejected,
            'The signing request was rejected.',
          ),
          WalletSigningFailureKind.cancelled => (
            RoastSigningOperationState.cancelled,
            'The signing request was cancelled.',
          ),
          _ => (
            RoastSigningOperationState.interrupted,
            'The signing request was interrupted.',
          ),
        };
        await _saveRoastSigningOperation(
          current.copyWith(state: state, errorMessage: message),
        );
        if (state == RoastSigningOperationState.expired) {
          await _recordActivity(
            id: 'signature-request-expired:${current.storageId}',
            accountId: current.accountId,
            type: WalletActivityType.signatureRequestExpired,
            reference: current.requestIdHex,
          );
          Error.throwWithStackTrace(
            WalletSigningFailure(
              WalletSigningFailureKind.expired,
              'The signing request expired before enough signatures arrived.',
              cause: error,
            ),
            stackTrace,
          );
        }
      }
      rethrow;
    } finally {
      _pendingRoastSends.remove(pendingKey);
      _notifyListeners();
    }
  }

  Future<WalletSendResult> _broadcastRoastOperation(
    WalletAccount account,
    RoastSigningOperation operation,
    SignedWalletTransaction signed,
  ) async {
    var current = operation.copyWith(
      state: RoastSigningOperationState.broadcasting,
      rawTransactionHex: signed.rawTransactionHex,
      transactionId: signed.transactionId,
      clearError: true,
    );
    await _saveRoastSigningOperation(current);
    try {
      final result = await _broadcastSigned(
        account,
        signed,
        inputOutpoints: operation.reservedOutpoints,
      );
      current = current.copyWith(
        state: RoastSigningOperationState.broadcasted,
        serverTransactionId: result.serverTransactionId,
        clearError: true,
      );
      await _saveRoastSigningOperation(current);
      return result;
    } on Object catch (_) {
      await _saveRoastSigningOperation(
        current.copyWith(
          state: RoastSigningOperationState.broadcastUnknown,
          errorMessage: 'The transaction broadcast outcome is unknown.',
        ),
      );
      rethrow;
    }
  }

  Future<WalletSendResult> retryRoastBroadcast(
    RoastSigningOperation operation,
  ) async {
    final current = _storedRoastSigningOperations[operation.storageId];
    if (current == null || !current.canRetryBroadcast) {
      throw const WalletTransactionRejected(
        'This ROAST transaction cannot be rebroadcast.',
      );
    }
    final account = accounts
        .where((candidate) => candidate.id == current.accountId)
        .firstOrNull;
    if (account == null) throw const WalletSigningUnavailable();
    return _broadcastRoastOperation(
      account,
      current,
      SignedWalletTransaction(
        transactionId: current.transactionId!,
        rawTransactionHex: current.rawTransactionHex!,
      ),
    );
  }

  Future<WalletSendResult> retryPersonalBroadcast(
    WalletActivity activity,
  ) async {
    final current = _vault?.activities
        .where((candidate) => candidate.id == activity.id)
        .firstOrNull;
    final account = current == null
        ? null
        : accounts
              .where((candidate) => candidate.id == current.accountId)
              .firstOrNull;
    if (current == null ||
        account == null ||
        account.keySource != WalletKeySource.personal ||
        !current.canRetryBroadcast) {
      throw const WalletTransactionRejected(
        'This transaction cannot be rebroadcast.',
      );
    }
    return _broadcastSigned(
      account,
      SignedWalletTransaction(
        transactionId: current.reference!,
        rawTransactionHex: current.rawTransactionHex!,
      ),
      inputOutpoints: current.transactionInputOutpoints,
    );
  }

  Future<WalletSendResult> _broadcastSigned(
    WalletAccount account,
    SignedWalletTransaction signed, {
    List<String> inputOutpoints = const [],
  }) async {
    if (_broadcastedTransactionIds.contains(signed.transactionId) ||
        !_broadcastingTransactionIds.add(signed.transactionId)) {
      throw const WalletTransactionRejected(
        'This transaction has already been submitted.',
      );
    }
    try {
      await _setTransactionStatus(
        accountId: account.id,
        transactionId: signed.transactionId,
        status: WalletTransactionStatus.broadcasting,
        inputOutpoints: inputOutpoints,
        rawTransactionHex: signed.rawTransactionHex,
      );
      late final String serverTransactionId;
      try {
        final service = _networkServices[networkForAccount(account).storageId];
        if (service == null) {
          throw const WalletBroadcastFailure(
            WalletBroadcastFailureKind.unavailable,
            'ElectrumX is unavailable for this wallet. Reconnect and retry.',
          );
        }
        serverTransactionId = await service.broadcastTransaction(
          signed.rawTransactionHex,
        );
      } on Object catch (error, stackTrace) {
        final network = networkForAccount(account);
        final failure = _broadcastFailure(error);
        AppLogger.error(
          '[ELECTRUMX ${network.storageId}] Transaction broadcast failed; '
          'localTxId=${signed.transactionId}; '
          'rawBytes=${(signed.rawTransactionHex.length + 1) ~/ 2}',
          error: error,
          stackTrace: stackTrace,
        );
        await _setTransactionStatus(
          accountId: account.id,
          transactionId: signed.transactionId,
          status: WalletTransactionStatus.failed,
          details: failure.message,
        );
        Error.throwWithStackTrace(failure, stackTrace);
      }
      _broadcastedTransactionIds.add(signed.transactionId);
      await _setTransactionStatus(
        accountId: account.id,
        transactionId: signed.transactionId,
        status: WalletTransactionStatus.broadcast,
      );
      await _restartElectrumxSync();
      return WalletSendResult(
        transactionId: signed.transactionId,
        serverTransactionId: serverTransactionId,
      );
    } finally {
      _broadcastingTransactionIds.remove(signed.transactionId);
    }
  }

  WalletBroadcastFailure _broadcastFailure(Object error) {
    if (error is WalletBroadcastFailure) return error;
    Object cause = error;
    for (var depth = 0; depth < 8; depth++) {
      if (cause is ElectrumxException &&
          cause is! ElectrumxRpcException &&
          cause.cause != null) {
        cause = cause.cause!;
        continue;
      }
      break;
    }

    if (cause is ElectrumxRpcException) {
      return WalletBroadcastFailure(
        WalletBroadcastFailureKind.rejected,
        'ElectrumX rejected the transaction (code ${cause.code}).',
        cause: error,
        rpcCode: cause.code,
      );
    }
    if (cause is TimeoutException) {
      return WalletBroadcastFailure(
        WalletBroadcastFailureKind.timeout,
        'Broadcast timed out. Verify the network connection and retry.',
        cause: error,
      );
    }
    if (cause is ElectrumxException) {
      return WalletBroadcastFailure(
        WalletBroadcastFailureKind.connection,
        'ElectrumX could not broadcast the transaction. '
        'Verify the network connection and retry.',
        cause: error,
      );
    }
    return WalletBroadcastFailure(
      WalletBroadcastFailureKind.unexpected,
      'Broadcast failed. Verify the network connection and retry.',
      cause: error,
    );
  }

  String _sendFailureMessage(Object error) => switch (error) {
    NoosphereWorkerException() =>
      'ROAST signing failed. Check signer connectivity and retry.',
    TimeoutException() =>
      'Transaction signing timed out. Check signer connectivity and retry.',
    StateError() =>
      'Transaction submission failed. Check wallet state and retry.',
    _ => 'Transaction submission failed. Check the application log and retry.',
  };
}
