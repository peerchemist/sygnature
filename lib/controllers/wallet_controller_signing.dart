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

  Future<void> cancelRoastMessageSigning(String setupId) =>
      _cancelRoastSigningRequest(
        setupId,
        _pendingRoastMessages.keys
            .where((key) => key.startsWith('$setupId:'))
            .singleOrNull,
      );

  Future<void> cancelRoastTransactionSigning(String setupId) =>
      _cancelRoastSigningRequest(
        setupId,
        _pendingRoastSends.keys
            .where((key) => key.startsWith('$setupId:'))
            .singleOrNull,
      );

  Future<void> _cancelRoastSigningRequest(
    String setupId,
    String? pendingKey,
  ) async {
    if (_backupInProgress) throw const WalletBusyFailure();
    final prefix = '$setupId:';
    if (pendingKey == null) {
      throw StateError('There is no active local signing request.');
    }
    if (!_cancellingRoastRequests.add(pendingKey)) return;
    _notifyListeners();
    try {
      final result = await _roastRuntime!.cancelSignatures(
        setupId,
        pendingKey.substring(prefix.length),
      );
      switch (result) {
        case RoastSigningCancellationResult.cancelled ||
            RoastSigningCancellationResult.alreadyCancelled:
          return;
        case RoastSigningCancellationResult.alreadyCompleted:
          throw StateError('The signing request has already completed.');
        case RoastSigningCancellationResult.alreadyTerminal:
          throw StateError('The signing request is already closed.');
        case RoastSigningCancellationResult.notFound:
          throw StateError('The signing request was not found.');
      }
    } finally {
      _cancellingRoastRequests.remove(pendingKey);
      _notifyListeners();
    }
  }

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

  bool isRoastChangeOutput(RoastSigningInboxItem item, int outputIndex) =>
      item.request.changeOutputIndex == outputIndex;

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

  static String _utxoKey(ElectrumxUtxo utxo) => '${utxo.txHash}:${utxo.txPos}';

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

  Future<RoastSignedMessage> signRoastMessage(
    WalletAccount account, {
    required String text,
    String message = '',
    Duration requestTimeout = defaultRoastSigningRequestTimeout,
  }) async {
    if (_backupInProgress) throw const WalletBusyFailure();
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
    if (_backupInProgress) throw const WalletBusyFailure();
    if (_sending) {
      throw const WalletTransactionRejected(
        'Another transaction is already being submitted.',
      );
    }
    _sending = true;
    try {
      final foundAccount = accounts
          .where((candidate) => candidate.id == preview.accountId)
          .firstOrNull;
      if (foundAccount == null) {
        throw const WalletSigningUnavailable();
      }
      var account = foundAccount;
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
            preview.changeAddressIndex <=
                    account.highestAllocatedAddressIndex &&
                !operationIsKnown) {
          throw const WalletTransactionRejected(
            'Wallet state changed after review. Review the transaction again.',
          );
        }
        if (preview.changeAddressIndex > account.highestAllocatedAddressIndex) {
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
          account = accounts.firstWhere((item) => item.id == preview.accountId);
          await _restartElectrumxSync();
        }
      }
      final SignedWalletTransaction signed;
      RoastSigningOperation? signingOperation;
      if (account.keySource == WalletKeySource.watchOnly) {
        throw const WalletSigningUnavailable();
      } else if (account.keySource == WalletKeySource.personal) {
        signed = _transactionService.sign(
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
      } else {
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
            _roastKeyService
                .deriveAddress(
                  groupKeyHex: setup.groupKeyHex!,
                  threshold: setup.threshold,
                  network: network,
                  accountIndex: account.accountIndex,
                  pathLabel: 'R/${path.join('/')}',
                )
                .internalKeyHex,
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
        _pendingRoastSends[pendingKey] = _PendingRoastSend(
          completer: completer,
        );
        signingOperation = RoastSigningOperation(
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
            final cancelled =
                error is WalletSigningFailure &&
                error.kind == WalletSigningFailureKind.cancelled;
            await _saveRoastSigningOperation(
              current.copyWith(
                state: expired
                    ? RoastSigningOperationState.expired
                    : rejected
                    ? RoastSigningOperationState.rejected
                    : cancelled
                    ? RoastSigningOperationState.cancelled
                    : RoastSigningOperationState.interrupted,
                errorMessage: expired
                    ? 'The signing request expired before enough signatures arrived.'
                    : rejected
                    ? 'The signing request was rejected.'
                    : cancelled
                    ? 'The signing request was cancelled.'
                    : 'The signing request was interrupted.',
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

  void _requireRoastCoordinator(RoastSetup setup) {
    if (setup.requiresBackupReconciliation) {
      throw const WalletSigningFailure(
        WalletSigningFailureKind.interrupted,
        'Verify the restored group with the live participants before signing.',
      );
    }
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
    if (_backupInProgress) throw const WalletBusyFailure();
    final setup = _setupById(item.setupId);
    final learnedIndex = _validateRoastSigningRequest(setup, item.request);
    if (learnedIndex != null) {
      await _persistLearnedRoastAllocation(setup.id, learnedIndex);
    }
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
    if (_backupInProgress) throw const WalletBusyFailure();
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

  int? _validateRoastSigningRequest(
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
      return null;
    }
    if (request.kind != RoastSigningRequestKind.transaction ||
        !request.hasTransactionMetadata ||
        !request.usesSupportedSighash ||
        !request.usesExpectedTaprootTweak ||
        request.addressSchemeVersion == null ||
        request.accountIndex == null) {
      throw const WalletTransactionRejected(
        'The transaction signature request has unsupported metadata.',
      );
    }
    final account = accounts
        .where(
          (item) =>
              item.sourceId == setup.id &&
              item.accountIndex == request.accountIndex,
        )
        .firstOrNull;
    if (account == null) {
      throw const WalletTransactionRejected(
        'The signing request does not belong to this wallet.',
      );
    }
    final network = networkForAccount(account);
    final derivationPath = account.derivationPath;
    if (derivationPath == null) {
      throw const WalletTransactionRejected(
        'The signing request does not belong to this wallet.',
      );
    }
    final receivePath = _roastPath(derivationPath);
    bool pathIsAllowed(List<int> path) =>
        path.length == receivePath.length &&
        path.isNotEmpty &&
        path.last >= 0 &&
        path.last <= account.highestAllocatedAddressIndex + 100 &&
        listEquals(
          path.take(path.length - 1).toList(),
          receivePath.take(receivePath.length - 1).toList(),
        );
    final requestedAddressesByPath = <String, RoastDerivedAddress>{};
    for (final path in request.derivationPaths) {
      if (!pathIsAllowed(path)) continue;
      requestedAddressesByPath[path.join('/')] = _roastKeyService.deriveAddress(
        groupKeyHex: setup.groupKeyHex!,
        threshold: setup.threshold,
        network: network,
        accountIndex: account.accountIndex,
        pathLabel: 'R/${path.join('/')}',
      );
    }
    final validKeys =
        request.masterGroupKeys.isNotEmpty &&
        request.masterGroupKeys.every((key) => key == setup.groupKeyHex);
    final validPaths =
        request.derivationPaths.length == request.masterGroupKeys.length &&
        request.derivationPaths.every(
          (path) => requestedAddressesByPath.containsKey(path.join('/')),
        );
    final validInputs =
        request.previousOutputScripts.length == request.transactionInputCount &&
        request.previousOutputScripts.indexed.every((entry) {
          if (entry.$1 >= request.derivationPaths.length) return false;
          final derivedAddress =
              requestedAddressesByPath[request.derivationPaths[entry.$1].join(
                '/',
              )];
          return derivedAddress != null &&
              entry.$2 ==
                  _roastKeyService.scriptHexForAddress(
                    network,
                    derivedAddress.address,
                  );
        });
    final signsEveryInput =
        request.transactionInputCount == request.signedInputIndexes.length &&
        request.transactionInputCount == request.masterGroupKeys.length &&
        request.signedInputIndexes.indexed.every(
          (entry) => entry.$1 == entry.$2,
        );
    final knownUtxos = {
      for (final owned in _addressesForSync(account))
        for (final utxo
            in _utxosByAddress[owned.address] ?? const <ElectrumxUtxo>[])
          if (utxo.isConfirmed) _utxoKey(utxo): utxo,
    };
    final reservedOutpoints = _reservedOutpointsFor(
      account.id,
      includeIncomingRequests: false,
    );
    final validOutpoints =
        request.inputOutpoints.length == request.transactionInputCount &&
        request.inputOutpoints.every(knownUtxos.containsKey) &&
        request.inputOutpoints.every(
          (outpoint) => !reservedOutpoints.contains(outpoint),
        );
    final validInputValues =
        request.previousOutputValues.length == request.transactionInputCount &&
        request.previousOutputValues.indexed.every(
          (entry) =>
              knownUtxos[request.inputOutpoints[entry.$1]]?.value == entry.$2,
        );
    int? learnedIndex = request.derivationPaths
        .where(pathIsAllowed)
        .map((path) => path.last)
        .where((index) => index > account.highestAllocatedAddressIndex)
        .fold<int?>(
          null,
          (highest, index) =>
              highest == null || index > highest ? index : highest,
        );
    var validChange =
        request.addressSchemeVersion == account.addressSchemeVersion &&
        request.accountIndex == account.accountIndex;
    final changePath = request.changeDerivationPath;
    final changeOutputIndex = request.changeOutputIndex;
    if ((changePath == null) != (changeOutputIndex == null)) {
      validChange = false;
    } else if (changePath != null && changeOutputIndex != null) {
      if (!pathIsAllowed(changePath) ||
          changeOutputIndex < 0 ||
          changeOutputIndex >= request.outputs.length) {
        validChange = false;
      } else {
        final index = changePath.last;
        final derivedChange = _roastKeyService.deriveAddress(
          groupKeyHex: setup.groupKeyHex!,
          threshold: setup.threshold,
          network: network,
          accountIndex: account.accountIndex,
          pathLabel: 'R/${changePath.join('/')}',
        );
        validChange =
            request.outputs[changeOutputIndex].scriptHex ==
            _roastKeyService.scriptHexForAddress(
              network,
              derivedChange.address,
            );
        if (validChange && index > account.highestAllocatedAddressIndex) {
          if (learnedIndex == null || index > learnedIndex) {
            learnedIndex = index;
          }
        }
      }
    }
    if (!validKeys ||
        !validPaths ||
        !validInputs ||
        !validOutpoints ||
        !validInputValues ||
        !validChange ||
        !signsEveryInput ||
        request.outputs.isEmpty ||
        request.feeSats < 0) {
      throw const WalletTransactionRejected(
        'The signing request does not belong to this wallet.',
      );
    }
    return learnedIndex;
  }

  Future<void> _persistLearnedRoastAllocation(
    String setupId,
    int highestIndex,
  ) async {
    var changed = false;
    await _updateVault((current) {
      if (current == null) return current;
      return current.copyWith(
        accounts: [
          for (final account in current.accounts)
            if (account.sourceId == setupId &&
                highestIndex > account.highestAllocatedAddressIndex)
              () {
                changed = true;
                return account.copyWith(
                  highestAllocatedAddressIndex: highestIndex,
                );
              }()
            else
              account,
        ],
      );
    });
    if (changed) await _restartElectrumxSync();
  }

  static List<int> _roastPath(String label) =>
      label.split('/').skip(1).map(int.parse).toList(growable: false);

  Future<void> _announceRoastAction(String id, VoidCallback? notify) async {
    if (!_announcedRoastActions.add(id)) return;
    try {
      await _updateVault((current) {
        if (current == null || current.announcedRoastActionIds.contains(id)) {
          return current;
        }
        return current.copyWith(
          announcedRoastActionIds: [id, ...current.announcedRoastActionIds]
              .take(WalletController._maxAnnouncedRoastActions)
              .toList(growable: false),
        );
      });
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Unable to persist ROAST notification state',
        error: error,
        stackTrace: stackTrace,
      );
    }
    notify?.call();
  }
}
