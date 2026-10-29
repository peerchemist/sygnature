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

  Future<void> cancelRoastMessageSigning(String setupId, String requestIdHex) =>
      _cancelRoastSigningRequest(setupId, '$setupId:$requestIdHex');

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

  Future<void> acceptRoastSigningRequest(RoastSigningInboxItem item) =>
      _respondToRoastSigningRequest(item, approve: true);

  Future<void> rejectRoastSigningRequest(RoastSigningInboxItem item) =>
      _respondToRoastSigningRequest(item, approve: false);

  Future<void> _respondToRoastSigningRequest(
    RoastSigningInboxItem item, {
    required bool approve,
  }) async {
    if (_backupInProgress) throw const WalletBusyFailure();
    final setup = _setupById(item.setupId);
    if (approve) {
      final learnedIndex = _validateRoastSigningRequest(setup, item.request);
      if (learnedIndex != null) {
        await _persistLearnedRoastAllocation(setup.id, learnedIndex);
      }
      await _roastRuntime!.acceptSignatures(setup.id, item.request.idHex);
    } else {
      await _roastRuntime!.rejectSignatures(setup.id, item.request.idHex);
    }
    final requestKey = '${setup.id}:${item.request.idHex}';
    if (_roastSigningRequests[requestKey] case final current?) {
      _roastSigningRequests[requestKey] = RoastSigningInboxItem(
        setupId: current.setupId,
        walletName: current.walletName,
        request: current.request.copyWith(
          status: approve ? 'accepted' : 'rejected',
        ),
      );
    }
    await _recordSetupActivity(
      setup,
      id: 'signature-request-${approve ? 'approved' : 'rejected'}:$requestKey',
      type: approve
          ? WalletActivityType.signatureRequestApproved
          : WalletActivityType.signatureRequestRejected,
      reference: item.request.idHex,
    );
    _notifyListeners();
  }

  RoastDerivedAddress _deriveRoastAddress(
    RoastSetup setup,
    WalletAccount account,
    List<int> path,
  ) => _roastKeyService.deriveAddress(
    groupKeyHex: setup.groupKeyHex!,
    threshold: setup.threshold,
    network: networkForAccount(account),
    accountIndex: account.accountIndex,
    pathLabel: 'R/${path.join('/')}',
  );

  int? _validateRoastSigningRequest(
    RoastSetup setup,
    RoastSigningRequest request, {
    bool completed = false,
  }) {
    if (!completed && request.expiry.isBefore(DateTime.now())) {
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
        (completed && request.thresholdTransaction == null) ||
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
      requestedAddressesByPath[path.join('/')] = _deriveRoastAddress(
        setup,
        account,
        path,
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
        (completed ||
            request.inputOutpoints.every(knownUtxos.containsKey) &&
                request.inputOutpoints.every(
                  (outpoint) => !reservedOutpoints.contains(outpoint),
                ));
    final validInputValues =
        request.previousOutputValues.length == request.transactionInputCount &&
        (completed ||
            request.previousOutputValues.indexed.every(
              (entry) =>
                  knownUtxos[request.inputOutpoints[entry.$1]]?.value ==
                  entry.$2,
            ));
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
        final derivedChange = _deriveRoastAddress(setup, account, changePath);
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

  RoastSigningOperation _completedRoastSigningOperation(
    RoastSetup setup,
    RoastSigningRequest request,
    List<Uint8List> signatures,
  ) {
    _validateRoastSigningRequest(setup, request, completed: true);
    final account = accounts.firstWhere(
      (item) =>
          item.sourceId == setup.id &&
          item.accountIndex == request.accountIndex,
    );
    final expectedInternalKeysHex = [
      for (final path in request.derivationPaths)
        _deriveRoastAddress(setup, account, path).internalKeyHex,
    ];
    return RoastSigningOperation(
      setupId: setup.id,
      accountId: account.id,
      requestIdHex: request.idHex,
      proposalHex: request.proposalHex,
      expectedInternalKeysHex: expectedInternalKeysHex,
      thresholdTransaction: request.thresholdTransaction!.toJson(),
      reservedOutpoints: request.inputOutpoints,
      expiry: request.expiry,
      state: RoastSigningOperationState.awaitingSignatures,
      updatedAt: DateTime.now().toUtc(),
      signaturesHex: [
        for (final signature in signatures) bytesToHex(signature),
      ],
    );
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

List<int> _roastPath(String label) =>
    label.split('/').skip(1).map(int.parse).toList(growable: false);
