part of 'wallet_controller.dart';

extension WalletSigningController on WalletController {
  List<RoastSigningInboxItem> get roastSigningRequests =>
      List.unmodifiable(_roastSigningRequests.values);
  List<RoastSigningInboxItem> roastSigningRequestsForSetup(String setupId) =>
      roastSigningRequests
          .where((item) => item.setupId == setupId)
          .toList(growable: false);
  List<RoastSigningOperation> get recoverableRoastSigningOperations =>
      _storedRoastSigningOperations.values
          .where((operation) => operation.canRetryBroadcast)
          .toList(growable: false);
  bool roastMessageSigningInProgress(String setupId) =>
      _pendingRoastMessages.keys.any((key) => key.startsWith('$setupId:'));

  RoastSignedMessage? completedRoastMessage(String setupId) =>
      _completedRoastMessages[setupId];

  RoastSigningOperation? recoverableBroadcastForSetup(String setupId) =>
      recoverableRoastSigningOperations
          .where((operation) => operation.setupId == setupId)
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
      throw StateError('ElectrumX is not configured.');
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
  }) async {
    if (account.derivationState != WalletDerivationState.ready) {
      throw const WalletSigningUnavailable();
    }
    final setup = setupForAccount(account);
    final runtime = _roastRuntime;
    if (setup == null ||
        runtime == null ||
        !setup.isActive ||
        setup.groupKeyHex == null) {
      throw const WalletSigningUnavailable();
    }
    if (roastMessageSigningInProgress(setup.id)) {
      throw StateError('A message signature request is already active.');
    }
    final proposal = runtime.createMessageSigningProposal(
      setup,
      text,
      message: message,
    );
    final pendingKey = '${setup.id}:${proposal.idHex}';
    if (_pendingRoastMessages.containsKey(pendingKey)) {
      throw StateError('This message signature request is already active.');
    }
    final completer = Completer<RoastSignedMessage>();
    _pendingRoastMessages[pendingKey] = completer;
    _notifyListeners();
    try {
      await _recordActivity(
        id: 'message-signature-requested:$pendingKey',
        accountId: account.id,
        type: WalletActivityType.messageSignatureRequested,
        reference: proposal.idHex,
        details: text,
      );
      await runtime.requestSignatures(setup, proposal);
      return await completer.future.timeout(
        proposal.expiry.difference(DateTime.now()),
      );
    } finally {
      _pendingRoastMessages.remove(pendingKey);
      _notifyListeners();
    }
  }

  Future<WalletSendResult> sendTransaction(
    WalletTransactionPreview preview,
  ) async {
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
      final SignedWalletTransaction signed;
      RoastSigningOperation? signingOperation;
      if (account.keySource == WalletKeySource.personal) {
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
        if (setup == null ||
            runtime == null ||
            !setup.isActive ||
            setup.groupKeyHex == null) {
          throw const WalletSigningUnavailable();
        }
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
          await runtime.requestSignatures(setup, proposal);
          final outcome = await completer.future.timeout(
            proposal.expiry.difference(DateTime.now()),
          );
          if (outcome.error case final error?) {
            Error.throwWithStackTrace(
              error,
              outcome.stackTrace ?? StackTrace.current,
            );
          }
          signed = outcome.signed!;
          signingOperation = _storedRoastSigningOperations[pendingKey];
        } on Object catch (error) {
          final current = _storedRoastSigningOperations[pendingKey];
          if (current != null && current.rawTransactionHex == null) {
            final expired =
                current.expiry.isBefore(DateTime.now()) ||
                error.toString().toLowerCase().contains('expired');
            final rejected =
                error is WalletTransactionRejected &&
                error.message == 'Signing request failed.';
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
      throw WalletTransactionRejected(_sendFailureMessage(error));
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
      late final String serverTransactionId;
      try {
        final service = _networkServices[networkForAccount(account).storageId];
        if (service == null) {
          throw StateError('ElectrumX is not configured.');
        }
        serverTransactionId = await service.broadcastTransaction(
          signed.rawTransactionHex,
        );
      } on Object catch (error, stackTrace) {
        final network = networkForAccount(account);
        AppLogger.error(
          '[ELECTRUMX ${network.storageId}] Transaction broadcast failed; '
          'localTxId=${signed.transactionId}; '
          'rawBytes=${(signed.rawTransactionHex.length + 1) ~/ 2}',
          error: error,
          stackTrace: stackTrace,
        );
        throw WalletTransactionRejected(_broadcastFailureMessage(error));
      }
      _broadcastedTransactionIds.add(signed.transactionId);
      await _recordActivity(
        id: 'transaction-broadcast:${account.id}:${signed.transactionId}',
        accountId: account.id,
        type: WalletActivityType.transactionBroadcast,
        reference: signed.transactionId,
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

  String _broadcastFailureMessage(Object error) {
    Object cause = error;
    for (var depth = 0; depth < 8; depth++) {
      if (cause is ElectrumxException && cause.cause != null) {
        cause = cause.cause!;
        continue;
      }
      break;
    }

    if (cause is Map) {
      final message = cause['message'];
      final code = cause['code'];
      if (message is String && message.trim().isNotEmpty) {
        final detail = _sanitizeBroadcastError(message);
        final codeSuffix = code == null ? '' : ' (code $code)';
        return 'ElectrumX rejected the transaction: $detail$codeSuffix';
      }
    }
    if (cause is TimeoutException) {
      return 'Broadcast timed out. Verify the network connection and retry.';
    }
    if (cause is StateError) {
      return 'ElectrumX is unavailable for this wallet. Reconnect and retry.';
    }
    if (cause is ElectrumxException) {
      return 'ElectrumX could not broadcast the transaction. '
          'Verify the network connection and retry.';
    }
    return 'Broadcast failed. Verify the network connection and retry.';
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

  Future<void> acceptRoastSigningRequest(RoastSigningInboxItem item) async {
    final setup = _setupById(item.setupId);
    _validateRoastSigningRequest(setup, item.request);
    await _roastRuntime!.acceptSignatures(setup.id, item.request.idHex);
    _roastSigningRequests.remove('${setup.id}:${item.request.idHex}');
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
    _roastSigningRequests.remove('${item.setupId}:${item.request.idHex}');
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
      throw const WalletTransactionRejected('The signing request is expired.');
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
    final reservedOutpoints = _reservedOutpointsFor(account.id);
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
