part of 'wallet_controller.dart';

extension WalletRoastEventController on WalletController {
  void _queueRoastEvent(RoastRuntimeEvent event) {
    _roastEventQueue = _roastEventQueue.then(
      (_) => _handleRoastEventSafely(event),
    );
  }

  void _queueRoastStreamFailure(Object error) {
    _roastEventQueue = _roastEventQueue.then(
      (_) => _handleRoastStreamFailure(error),
    );
  }

  Future<void> _handleRoastEventSafely(RoastRuntimeEvent event) async {
    try {
      await _handleRoastEvent(event);
    } catch (error, stackTrace) {
      if (event case RoastRuntimeSigningResultEvent()) {
        final pending =
            _pendingRoastSends['${event.setupId}:${event.requestIdHex}'];
        if (pending != null && !pending.completer.isCompleted) {
          pending.completer.complete(
            _RoastSendOutcome(error: error, stackTrace: stackTrace),
          );
        }
      }
      if (_disposed || !roastSetups.any((item) => item.id == event.setupId)) {
        return;
      }
      try {
        final setup = _setupById(event.setupId);
        await _replaceSetup(
          setup.copyWith(
            status: RoastSetupStatus.error,
            errorMessage: WalletRoastSetupController._cleanRoastError(error),
          ),
        );
      } on Object {
        // A persistence failure must not poison the serialized event queue.
      }
    }
  }

  Future<void> _handleRoastStreamFailure(Object error) async {
    if (_disposed) return;
    for (final pending in _pendingRoastSends.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.complete(_RoastSendOutcome(error: error));
      }
    }
    for (final setup in [...roastSetups]) {
      _roastPresence.remove(setup.id);
      try {
        await _replaceSetup(
          _setupById(setup.id).copyWith(
            status: RoastSetupStatus.interrupted,
            errorMessage: WalletRoastSetupController._cleanRoastError(error),
          ),
        );
      } on Object {
        // Keep processing the remaining setups even if one save fails.
      }
    }
  }

  Future<void> _handleRoastEvent(RoastRuntimeEvent event) async {
    if (_disposed || !roastSetups.any((setup) => setup.id == event.setupId)) {
      return;
    }
    final setup = _setupById(event.setupId);
    switch (event) {
      case RoastRuntimeSnapshotEvent():
        _roastPresence[event.setupId] = _RoastPresence(
          connected: event.connected,
          signerRunning: event.signerRunning,
        );
        await _replaceSetup(
          setup.copyWith(
            onlineParticipantIds: event.onlineParticipantIds,
            coordinatorId: event.coordinatorId,
            coordinatorRelayUrls: event.coordinatorRelayUrls,
            coordinatorIpAddrs: event.coordinatorIpAddrs,
            status:
                setup.status == RoastSetupStatus.connecting && event.connected
                ? RoastSetupStatus.ready
                : setup.status,
          ),
        );
      case RoastRuntimeDkgEvent():
        if (event.rejected) {
          if (WalletRoastSetupController._dkgDefinitionMatchesSetup(
                event,
                setup,
              ) &&
              (setup.pendingDkgProposalHex == null ||
                  setup.pendingDkgProposalHex == event.proposalHex)) {
            await _replaceSetup(
              setup.copyWith(
                status: RoastSetupStatus.ready,
                clearPendingDkgProposal: true,
                errorMessage: event.failure ?? 'The DKG proposal was rejected.',
              ),
            );
            await _recordSetupActivity(
              setup,
              id: 'dkg-failed:${setup.id}:${event.proposalHex}',
              type: WalletActivityType.dkgFailed,
              reference: event.proposalHex,
              details: event.failure ?? 'The DKG proposal was rejected.',
            );
          }
          return;
        }
        if (!WalletRoastSetupController._dkgMatchesSetup(event, setup)) {
          await _roastRuntime?.rejectDkg(event.setupId, event.proposalHex);
          return;
        }
        await _replaceSetup(
          setup.copyWith(
            status: event.failure != null
                ? RoastSetupStatus.error
                : event.stage != 'waiting'
                ? RoastSetupStatus.creatingKey
                : RoastSetupStatus.awaitingDkgApproval,
            pendingDkgProposalHex: event.proposalHex,
            pendingDkgStage: event.stage,
            pendingDkgCompletedParticipantIds: event.completedParticipantIds,
            pendingDkgName: event.name,
            pendingDkgThreshold: event.threshold,
            pendingDkgCreatorId: event.creator,
            pendingDkgExpiry: event.expiry,
            errorMessage: event.failure,
          ),
        );
        if (event.failure == null && event.stage == 'waiting') {
          _announceRoastAction('dkg:${setup.id}:${event.proposalHex}');
        }
        await _recordSetupActivity(
          setup,
          id: event.failure == null
              ? 'dkg-started:${setup.id}:${event.proposalHex}'
              : 'dkg-failed:${setup.id}:${event.proposalHex}',
          type: event.failure == null
              ? WalletActivityType.dkgStarted
              : WalletActivityType.dkgFailed,
          reference: event.proposalHex,
          details: event.failure,
        );
      case RoastRuntimeKeyEvent():
        if (event.keyName != setup.keyName) return;
        final active = setup.copyWith(
          status: RoastSetupStatus.active,
          groupKeyHex: event.groupKeyHex,
          clearPendingDkgProposal: true,
          clearError: true,
        );
        await _replaceSetup(active);
        await _activateRoastAccount(active, event.groupKeyHex);
        await _markTransitionReadyForSetup(setup.id);
        await _recordSetupActivity(
          active,
          id: 'dkg-completed:${setup.id}:${event.keyName}',
          type: WalletActivityType.dkgCompleted,
          reference: event.keyName,
        );
      case RoastRuntimeFailureEvent():
        if (event.operation == 'signatures' ||
            event.operation == 'signingPersistence') {
          final error = WalletTransactionRejected(event.message);
          final pendingEntries = event.requestIdHex == null
              ? _pendingRoastSends.entries.where(
                  (entry) => entry.key.startsWith('${event.setupId}:'),
                )
              : _pendingRoastSends.entries.where(
                  (entry) =>
                      entry.key == '${event.setupId}:${event.requestIdHex}',
                );
          for (final entry in pendingEntries) {
            if (!entry.value.completer.isCompleted) {
              entry.value.completer.complete(_RoastSendOutcome(error: error));
            }
          }
          final pendingMessageEntries = event.requestIdHex == null
              ? _pendingRoastMessages.entries.where(
                  (entry) => entry.key.startsWith('${event.setupId}:'),
                )
              : _pendingRoastMessages.entries.where(
                  (entry) =>
                      entry.key == '${event.setupId}:${event.requestIdHex}',
                );
          for (final entry in pendingMessageEntries) {
            if (!entry.value.isCompleted) entry.value.completeError(error);
          }
          if (event.requestIdHex case final requestId?) {
            _roastSigningRequests.remove('${event.setupId}:$requestId');
          }
          _notifyListeners();
          return;
        }
        if (event.operation.toLowerCase().contains('dkg') ||
            event.operation == 'keyReadiness') {
          await _recordSetupActivity(
            setup,
            id:
                'dkg-failed:${setup.id}:'
                '${setup.pendingDkgProposalHex ?? setup.keyName}:'
                '${event.operation}',
            type: WalletActivityType.dkgFailed,
            reference: setup.pendingDkgProposalHex ?? setup.keyName,
            details: event.message,
          );
        }
        if (event.interrupted) _roastPresence.remove(event.setupId);
        await _replaceSetup(
          setup.copyWith(
            status: event.interrupted
                ? RoastSetupStatus.interrupted
                : RoastSetupStatus.error,
            errorMessage: event.message,
          ),
        );
      case RoastRuntimeSigningRequestEvent():
        final requestKey = '${setup.id}:${event.request.idHex}';
        if (event.request.status != 'waiting') {
          final removed = _roastSigningRequests.remove(requestKey);
          final type = switch (event.request.status) {
            'accepted' => WalletActivityType.signatureRequestApproved,
            'rejected' => WalletActivityType.signatureRequestRejected,
            _ => null,
          };
          if (type != null && removed != null) {
            await _recordSetupActivity(
              setup,
              id: event.request.status == 'accepted'
                  ? 'signature-request-approved:$requestKey'
                  : 'signature-request-rejected:$requestKey',
              type: type,
              reference: event.request.idHex,
            );
          }
          _notifyListeners();
          return;
        }
        if (event.request.creator == setup.localParticipant.identifierHex) {
          return;
        }
        try {
          _validateRoastSigningRequest(setup, event.request);
          final account = accounts.firstWhere(
            (item) => item.sourceId == setup.id,
          );
          _roastSigningRequests[requestKey] = RoastSigningInboxItem(
            setupId: setup.id,
            walletName: account.name,
            request: event.request,
          );
          _announceRoastAction('signatures:$requestKey');
          await _recordActivity(
            id: 'signature-request-received:$requestKey',
            accountId: account.id,
            type: WalletActivityType.signatureRequestReceived,
            reference: event.request.idHex,
            details: event.request.message.isEmpty
                ? null
                : event.request.message,
          );
          _notifyListeners();
        } on Object {
          // Unsupported or foreign proposals are deliberately not rendered.
        }
      case RoastRuntimeSigningRequestRemovedEvent():
        final removed = _roastSigningRequests.remove(
          '${event.setupId}:${event.requestIdHex}',
        );
        if (event.expired && removed != null) {
          await _recordSetupActivity(
            setup,
            id:
                'signature-request-expired:${event.setupId}:'
                '${event.requestIdHex}',
            type: WalletActivityType.signatureRequestExpired,
            reference: event.requestIdHex,
          );
        }
        _notifyListeners();
      case RoastRuntimeSigningResultEvent():
        final pendingKey = '${setup.id}:${event.requestIdHex}';
        if (event.creator != setup.localParticipant.identifierHex) return;
        var operation = await _roastSigningOperations.getSigningOperation(
          pendingKey,
        );
        if (operation == null || operation.proposalHex != event.proposalHex) {
          throw StateError(
            'The completed ROAST proposal does not match local state.',
          );
        }
        _storedRoastSigningOperations[pendingKey] = operation;
        if (operation.rawTransactionHex == null) {
          operation = await _completeRoastSigningOperation(operation);
        }
        final pending = _pendingRoastSends[pendingKey];
        if (pending != null && !pending.completer.isCompleted) {
          pending.completer.complete(
            _RoastSendOutcome(
              signed: SignedWalletTransaction(
                transactionId: operation.transactionId!,
                rawTransactionHex: operation.rawTransactionHex!,
              ),
            ),
          );
        }
      case RoastRuntimeMessageSigningResultEvent():
        if (event.creator != setup.localParticipant.identifierHex) return;
        _completedRoastMessages[setup.id] = event.signedMessage;
        final pending =
            _pendingRoastMessages['${setup.id}:${event.requestIdHex}'];
        if (pending != null && !pending.isCompleted) {
          pending.complete(event.signedMessage);
        }
        await _recordSetupActivity(
          setup,
          id: 'message-signed:${setup.id}:${event.requestIdHex}',
          type: WalletActivityType.messageSigned,
          reference: event.requestIdHex,
          details: event.signedMessage.text,
        );
        _notifyListeners();
    }
  }
}
