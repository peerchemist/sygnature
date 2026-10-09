part of 'wallet_controller.dart';

extension WalletSigningController on WalletController {
  List<RoastSigningInboxItem> get roastSigningRequests =>
      List.unmodifiable(_roastSigningRequests.values);
  List<RoastSigningInboxItem> roastSigningRequestsForSetup(String setupId) =>
      roastSigningRequests
          .where((item) => item.setupId == setupId)
          .toList(growable: false);
  int activeRoastSigningRequestCount(String setupId) {
    final prefix = '$setupId:';
    return {
      ..._roastSigningRequests.keys.where((key) => key.startsWith(prefix)),
      ..._pendingRoastSends.keys.where((key) => key.startsWith(prefix)),
      ..._pendingRoastMessages.keys.where((key) => key.startsWith(prefix)),
    }.length;
  }

  int roastSigningRequestsAwaitingLocalApprovalCount(String setupId) =>
      roastSigningRequestsForSetup(setupId)
          .where((item) => item.request.status == 'waiting')
          .length;

  List<RoastSigningOperation> get recoverableRoastSigningOperations =>
      _storedRoastSigningOperations.values
          .where((operation) => operation.canRetryBroadcast)
          .toList(growable: false);
  bool roastTransactionSigningInProgress(String setupId) =>
      _pendingRoastSends.keys.any((key) => key.startsWith('$setupId:'));
  bool roastMessageSigningInProgress(String setupId) =>
      _pendingRoastMessages.keys.any((key) => key.startsWith('$setupId:'));
  RoastSigningProgress? roastMessageSigningProgress(String setupId) =>
      _pendingRoastMessageProgress.entries
          .where((entry) => entry.key.startsWith('$setupId:'))
          .firstOrNull
          ?.value;

  RoastSignedMessage? completedRoastMessage(String setupId) =>
      _completedRoastMessages[setupId];

  RoastSigningOperation? recoverableBroadcastForSetup(String setupId) =>
      recoverableRoastSigningOperations
          .where((operation) => operation.setupId == setupId)
          .firstOrNull;

  bool hasDismissibleRoastSigningOperation(String accountId) =>
      _dismissibleRoastSigningOperation(accountId) != null;

  Future<void> dismissRoastSigningOperation(String accountId) async {
    final operation = _dismissibleRoastSigningOperation(accountId);
    if (operation == null) return;
    await _saveRoastSigningOperation(
      operation.copyWith(reservationsReleased: true),
    );
  }

  RoastSigningOperation? _dismissibleRoastSigningOperation(String accountId) =>
      _storedRoastSigningOperations.values
          .where(
            (operation) =>
                operation.accountId == accountId &&
                operation.state == RoastSigningOperationState.interrupted &&
                operation.rawTransactionHex == null &&
                operation.reservesUtxos,
          )
          .firstOrNull;

  String roastOutputAddress(
    RoastSigningInboxItem item,
    RoastSigningOutput output,
  ) {
    final setup = _setupById(item.setupId);
    final network = _networkById(setup.blockchainId, setup.networkId);
    return _roastKeyService.addressForScript(network, output.scriptHex);
  }

  bool isRoastChangeOutput(
    RoastSigningInboxItem item,
    RoastSigningOutput output,
  ) {
    final account = accounts.firstWhere(
      (account) => account.sourceId == item.setupId,
    );
    final address = account.address;
    if (address == null) return false;
    return output.scriptHex ==
        _roastKeyService.scriptHexForAddress(
          networkForAccount(account),
          address,
        );
  }

  Future<void> refreshBalances() => _restartElectrumxSync();

  Future<String> broadcastTransaction(String rawTransactionHex) {
    final account = selectedAccount;
    final service = account == null
        ? null
        : _networkServices[networkForAccount(account).storageId];
    if (service == null) {
      throw const WalletBroadcastFailure(
        WalletBroadcastFailureKind.unavailable,
        'ElectrumX is unavailable for this wallet. Reconnect and retry.',
      );
    }
    return service.broadcastTransaction(rawTransactionHex);
  }

  WalletTransactionPreview prepareSend(WalletSendRequest request) {
    final account = selectedAccount;
    final address = account?.address;
    if (account == null ||
        account.derivationState != WalletDerivationState.ready ||
        address == null) {
      throw const WalletSigningUnavailable();
    }
    return _transactionService.prepare(
      accountId: account.id,
      network: networkForAccount(account),
      sourceAddress: address,
      availableUtxos: availableUtxosFor(account),
      request: request,
    );
  }

  static String _utxoKey(ElectrumxUtxo utxo) => '${utxo.txHash}:${utxo.txPos}';

  Future<RoastSignedMessage> signRoastMessage(
    WalletAccount account, {
    required String text,
    String message = '',
    Duration requestTimeout = defaultRoastSigningRequestTimeout,
  }) async {
    if (account.derivationState != WalletDerivationState.ready) {
      throw const WalletSigningUnavailable();
    }
    final setup = setupForAccount(account);
    final runtime = _roastRuntime;
    if (setup == null || runtime == null || setup.groupKeyHex == null) {
      throw const WalletSigningUnavailable();
    }
    _requireRoastCoordinator(setup);
    if (roastMessageSigningInProgress(setup.id)) {
      throw StateError('A message signature request is already active.');
    }
    final proposal = runtime.createMessageSigningProposal(
      setup,
      text,
      message: message,
      timeout: requestTimeout,
    );
    final pendingKey = '${setup.id}:${proposal.idHex}';
    if (_pendingRoastMessages.containsKey(pendingKey)) {
      throw StateError('This message signature request is already active.');
    }
    final completer = Completer<RoastSignedMessage>();
    _pendingRoastMessages[pendingKey] = completer;
    _pendingRoastMessageProgress[pendingKey] = RoastSigningProgress(
      threshold: setup.threshold,
      contributingParticipants: const [],
      stage: 'sending',
    );
    _notifyListeners();
    try {
      await _recordActivity(
        id: 'message-signature-requested:$pendingKey',
        accountId: account.id,
        type: WalletActivityType.messageSignatureRequested,
        expiresAt: proposal.expiry,
        reference: proposal.idHex,
        details: text,
      );
      await runtime.requestSignatures(setup, proposal);
      final progress = _pendingRoastMessageProgress[pendingKey];
      if (progress?.stage == 'sending') {
        _pendingRoastMessageProgress[pendingKey] = RoastSigningProgress(
          threshold: progress!.threshold,
          contributingParticipants: progress.contributingParticipants,
          stage: 'collecting',
        );
        _notifyListeners();
      }
      return await completer.future.timeout(
        proposal.expiry.difference(DateTime.now()),
        onTimeout: () => throw const WalletSigningFailure(
          WalletSigningFailureKind.expired,
          'The signing request expired before enough signatures arrived.',
        ),
      );
    } finally {
      _pendingRoastMessages.remove(pendingKey);
      _pendingRoastMessageProgress.remove(pendingKey);
      _notifyListeners();
    }
  }

  Future<WalletSendResult> sendTransaction(
    WalletTransactionPreview preview, {
    Duration signatureRequestTimeout = defaultRoastSigningRequestTimeout,
  }) async {
    if (_sending) {
      throw const WalletTransactionRejected(
        'Another transaction is already being submitted.',
      );
    }
    _sending = true;
    try {
      final account = accounts
          .where((candidate) => candidate.id == preview.accountId)
          .firstOrNull;
      if (account == null) {
        throw const WalletSigningUnavailable();
      }
      if (account.derivationState != WalletDerivationState.ready) {
        throw const WalletSigningUnavailable();
      }
      final reservedOutpoints = _reservedOutpointsFor(account.id);
      if (preview.selectedUtxos.any(
        (utxo) => reservedOutpoints.contains(_utxoKey(utxo)),
      )) {
        throw const WalletTransactionRejected(
          'A transaction input is reserved by another signing request.',
        );
      }
      final SignedWalletTransaction signed;
      RoastSigningOperation? signingOperation;
      if (account.keySource == WalletKeySource.watchOnly) {
        throw const WalletSigningUnavailable();
      } else if (account.keySource == WalletKeySource.personal) {
        final privateKeyHex = account.privateKeyHex;
        if (privateKeyHex == null) throw const WalletSigningUnavailable();
        signed = _transactionService.sign(
          network: networkForAccount(account),
          preview: preview,
          privateKeyHex: privateKeyHex,
        );
        await _recordActivity(
          id: 'transaction-signed:${account.id}:${signed.transactionId}',
          accountId: account.id,
          type: WalletActivityType.transactionSigned,
          reference: signed.transactionId,
        );
      } else {
        final setup = setupForAccount(account);
        final runtime = _roastRuntime;
        if (setup == null || runtime == null || setup.groupKeyHex == null) {
          throw const WalletSigningUnavailable();
        }
        _requireRoastCoordinator(setup);
        final network = networkForAccount(account);
        final derived = _roastKeyService.deriveAddress(
          groupKeyHex: setup.groupKeyHex!,
          threshold: setup.threshold,
          network: network,
          accountIndex: account.accountIndex,
          pathLabel: account.derivationPath,
        );
        final transaction = _transactionService.prepareThresholdSigning(
          network: network,
          preview: preview,
        );
        final proposal = runtime.createTransactionSigningProposal(
          setup,
          transaction,
          derived.path,
          message: preview.signingMessage,
          timeout: signatureRequestTimeout,
        );
        final pendingKey = '${setup.id}:${proposal.idHex}';
        final completer = Completer<_RoastSendOutcome>();
        _pendingRoastSends[pendingKey] = _PendingRoastSend(
          completer: completer,
        );
        signingOperation = RoastSigningOperation(
          setupId: setup.id,
          accountId: account.id,
          requestIdHex: proposal.idHex,
          proposalHex: proposal.proposalHex,
          expectedInternalKeyHex: derived.internalKeyHex,
          derivationPath: List.unmodifiable(derived.path),
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
            details: preview.signingMessage.isEmpty
                ? null
                : preview.signingMessage,
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
          signed = outcome.signed!;
          signingOperation = _storedRoastSigningOperations[pendingKey];
        } on Object catch (error, stackTrace) {
          final current = _storedRoastSigningOperations[pendingKey];
          if (current != null && current.rawTransactionHex == null) {
            final expired =
                current.expiry.isBefore(DateTime.now()) ||
                error is WalletSigningFailure &&
                    error.kind == WalletSigningFailureKind.expired;
            final rejected =
                error is WalletSigningFailure &&
                error.kind == WalletSigningFailureKind.rejected;
            await _saveRoastSigningOperation(
              current.copyWith(
                state: expired
                    ? RoastSigningOperationState.expired
                    : rejected
                    ? RoastSigningOperationState.rejected
                    : RoastSigningOperationState.interrupted,
                errorMessage: '$error',
              ),
            );
            if (expired) {
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
      return signingOperation == null
          ? await _broadcastSigned(account, signed)
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
      final result = await _broadcastSigned(account, signed);
      current = current.copyWith(
        state: RoastSigningOperationState.broadcasted,
        serverTransactionId: result.serverTransactionId,
        clearError: true,
      );
      await _saveRoastSigningOperation(current);
      return result;
    } on Object catch (error) {
      await _saveRoastSigningOperation(
        current.copyWith(
          state: RoastSigningOperationState.broadcastUnknown,
          errorMessage: '$error',
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

  Future<WalletSendResult> _broadcastSigned(
    WalletAccount account,
    SignedWalletTransaction signed,
  ) async {
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
        'ElectrumX rejected the transaction: '
        '${_sanitizeBroadcastError(cause.message)} (code ${cause.code})',
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

  String _sanitizeBroadcastError(String message) {
    final clean = message
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    const maxLength = 240;
    if (clean.length <= maxLength) return clean;
    return '${clean.substring(0, maxLength - 1)}…';
  }

  String _sendFailureMessage(Object error) => switch (error) {
    NoosphereWorkerException(:final message) =>
      'ROAST signing failed: ${_sanitizeBroadcastError(message)}',
    TimeoutException() =>
      'Transaction signing timed out. Check signer connectivity and retry.',
    StateError(:final message) =>
      'Transaction submission failed: ${_sanitizeBroadcastError(message)}',
    _ => 'Transaction submission failed. Check the application log and retry.',
  };

  void _requireRoastCoordinator(RoastSetup setup) {
    if (setup.isActive &&
        roastCoordinatorState(setup.id) ==
            RoastCoordinatorLocalState.connected) {
      return;
    }
    throw const WalletSigningFailure(
      WalletSigningFailureKind.interrupted,
      'The ROAST signer is not connected to the coordinator. Start or '
      'reconnect it before requesting approvals.',
    );
  }

  Future<void> acceptRoastSigningRequest(RoastSigningInboxItem item) async {
    final setup = _setupById(item.setupId);
    _validateRoastSigningRequest(setup, item.request);
    await _roastRuntime!.acceptSignatures(setup.id, item.request.idHex);
    final requestKey = '${setup.id}:${item.request.idHex}';
    final current = _roastSigningRequests[requestKey];
    if (current != null) {
      _roastSigningRequests[requestKey] = RoastSigningInboxItem(
        setupId: current.setupId,
        walletName: current.walletName,
        request: current.request.copyWith(status: 'accepted'),
      );
    }
    await _recordSetupActivity(
      setup,
      id: 'signature-request-approved:${setup.id}:${item.request.idHex}',
      type: WalletActivityType.signatureRequestApproved,
      reference: item.request.idHex,
    );
    _notifyListeners();
  }

  Future<void> rejectRoastSigningRequest(RoastSigningInboxItem item) async {
    final setup = _setupById(item.setupId);
    await _roastRuntime!.rejectSignatures(item.setupId, item.request.idHex);
    final requestKey = '${item.setupId}:${item.request.idHex}';
    final current = _roastSigningRequests[requestKey];
    if (current != null) {
      _roastSigningRequests[requestKey] = RoastSigningInboxItem(
        setupId: current.setupId,
        walletName: current.walletName,
        request: current.request.copyWith(status: 'rejected'),
      );
    }
    await _recordSetupActivity(
      setup,
      id: 'signature-request-rejected:${setup.id}:${item.request.idHex}',
      type: WalletActivityType.signatureRequestRejected,
      reference: item.request.idHex,
    );
    _notifyListeners();
  }

  void _validateRoastSigningRequest(
    RoastSetup setup,
    RoastSigningRequest request,
  ) {
    if (request.expiry.isBefore(DateTime.now())) {
      throw const WalletSigningFailure(
        WalletSigningFailureKind.expired,
        'The signing request is expired.',
      );
    }
    if (request.kind == RoastSigningRequestKind.message) {
      final validMessage =
          request.signedMessageText != null &&
          request.usesUntweakedKey &&
          request.masterGroupKeys.length == 1 &&
          request.masterGroupKeys.single == setup.groupKeyHex &&
          request.derivationPaths.length == 1 &&
          request.derivationPaths.single.isEmpty;
      if (!validMessage) {
        throw const WalletTransactionRejected(
          'The message signature request does not belong to this setup.',
        );
      }
      return;
    }
    if (request.kind != RoastSigningRequestKind.transaction ||
        !request.hasTransactionMetadata ||
        !request.usesSupportedSighash ||
        !request.usesExpectedTaprootTweak) {
      throw const WalletTransactionRejected(
        'The transaction signature request has unsupported metadata.',
      );
    }
    final account = accounts.firstWhere(
      (item) => item.sourceId == setup.id && item.accountIndex == 0,
    );
    final network = networkForAccount(account);
    final derived = _roastKeyService.deriveAddress(
      groupKeyHex: setup.groupKeyHex!,
      threshold: setup.threshold,
      network: network,
      accountIndex: account.accountIndex,
      pathLabel: account.derivationPath,
    );
    final expectedScript = _roastKeyService.scriptHexForAddress(
      network,
      derived.address,
    );
    final validKeys =
        request.masterGroupKeys.isNotEmpty &&
        request.masterGroupKeys.every((key) => key == setup.groupKeyHex);
    final validPaths =
        request.derivationPaths.length == request.masterGroupKeys.length &&
        request.derivationPaths.every((path) => _samePath(path, derived.path));
    final validInputs =
        request.previousOutputScripts.length == request.transactionInputCount &&
        request.previousOutputScripts.every(
          (script) => script == expectedScript,
        );
    final signsEveryInput =
        request.transactionInputCount == request.signedInputIndexes.length &&
        request.transactionInputCount == request.masterGroupKeys.length &&
        request.signedInputIndexes.indexed.every(
          (entry) => entry.$1 == entry.$2,
        );
    final knownOutpoints = spendableUtxosFor(account).map(_utxoKey).toSet();
    final reservedOutpoints = _reservedOutpointsFor(
      account.id,
      includeIncomingRequests: false,
    );
    final validOutpoints =
        request.inputOutpoints.length == request.transactionInputCount &&
        request.inputOutpoints.every(knownOutpoints.contains) &&
        request.inputOutpoints.every(
          (outpoint) => !reservedOutpoints.contains(outpoint),
        );
    if (!validKeys ||
        !validPaths ||
        !validInputs ||
        !validOutpoints ||
        !signsEveryInput ||
        request.outputs.isEmpty ||
        request.feeSats < 0) {
      throw const WalletTransactionRejected(
        'The signing request does not belong to this wallet.',
      );
    }
  }

  static bool _samePath(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  void _announceRoastAction(String id) {
    if (_announcedRoastActions.add(id)) onRoastActionRequired?.call();
  }
}
