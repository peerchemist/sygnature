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
      AppLogger.error(
        '${WalletRoastSetupController._roastLogScope(event.setupId)} '
        'Unable to process ${event.runtimeType}',
        error: error,
        stackTrace: stackTrace,
      );
      if (event case RoastRuntimeSigningResultEvent()) {
        final pending =
            _pendingRoastSends['${event.setupId}:${event.requestIdHex}'];
        if (pending != null && !pending.completer.isCompleted) {
          pending.completer.complete(
            _RoastSendOutcome(error: error, stackTrace: stackTrace),
          );
        }
      }
      if (_disposed || !_hasActiveAccountForSetup(event.setupId)) {
        return;
      }
      try {
        final setup = _setupById(event.setupId);
        await _updateSetup(
          setup.id,
          (setup) => setup.copyWith(
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
    for (final setup in [
      ...roastSetups.where((setup) => _hasActiveAccountForSetup(setup.id)),
    ]) {
      _roastPresence.remove(setup.id);
      try {
        await _updateSetup(
          setup.id,
          (setup) => setup.copyWith(
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
    if (_disposed || !_hasActiveAccountForSetup(event.setupId)) {
      return;
    }
    final setup = _setupById(event.setupId);
    switch (event) {
      case RoastRuntimeEnrollmentEvent():
        final runtimeInvitations = {
          for (final invitation in event.invitations)
            invitation.participantPublicKeyHex: invitation,
        };
        final enrolledParticipants = {
          for (final participant in event.participants)
            participant.participantPublicKeyHex: participant,
        };
        await _updateSetup(
          setup.id,
          (setup) => setup.copyWith(
            invitations: [
              for (final invitation in setup.invitations)
                invitation.copyWith(
                  serverStatus:
                      runtimeInvitations[invitation.participantPublicKeyHex]
                          ?.status,
                  joinedAt:
                      enrolledParticipants[invitation.participantPublicKeyHex]
                          ?.enrolledAt ??
                      runtimeInvitations[invitation.participantPublicKeyHex]
                          ?.usedAt,
                ),
            ],
          ),
        );
      case RoastRuntimeSnapshotEvent():
        final previousPresence = _roastPresence[event.setupId];
        final presenceChanged =
            previousPresence?.connected != event.connected ||
            previousPresence?.signerRunning != event.signerRunning;
        _roastPresence[event.setupId] = _RoastPresence(
          connected: event.connected,
          signerRunning: event.signerRunning,
        );
        var setupChanged = false;
        await _updateSetup(setup.id, (setup) {
          final recovered =
              event.connected &&
              event.signerRunning &&
              (setup.status == RoastSetupStatus.connecting ||
                  setup.status == RoastSetupStatus.interrupted);
          if (!recovered &&
              listEquals(
                setup.onlineParticipantIds,
                event.onlineParticipantIds,
              ) &&
              (event.coordinatorId == null ||
                  setup.coordinatorId == event.coordinatorId) &&
              listEquals(
                setup.coordinatorRelayUrls,
                event.coordinatorRelayUrls,
              ) &&
              listEquals(setup.coordinatorIpAddrs, event.coordinatorIpAddrs)) {
            return setup;
          }
          setupChanged = true;
          return setup.copyWith(
            onlineParticipantIds: event.onlineParticipantIds,
            coordinatorId: event.coordinatorId,
            coordinatorRelayUrls: event.coordinatorRelayUrls,
            coordinatorIpAddrs: event.coordinatorIpAddrs,
            status: recovered ? _restoredRoastStatus(setup) : setup.status,
            clearError: recovered,
          );
        });
        if (presenceChanged && !setupChanged) _notifyListeners();
      case RoastRuntimeDkgEvent()
          when event.rejected &&
              WalletRoastSetupController._dkgDefinitionMatchesSetup(
                event,
                setup,
              ) &&
              (setup.pendingDkgProposalHex == null ||
                  setup.pendingDkgProposalHex == event.proposalHex):
        await _updateSetup(
          setup.id,
          (setup) => setup.copyWith(
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
        return;
      case RoastRuntimeDkgEvent() when event.rejected:
        return;
      case RoastRuntimeDkgEvent()
          when !WalletRoastSetupController._dkgMatchesSetup(event, setup):
        await _roastRuntime?.rejectDkg(event.setupId, event.proposalHex);
        return;
      case RoastRuntimeDkgEvent():
        await _updateSetup(
          setup.id,
          (setup) => setup.copyWith(
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
        await _updateSetup(
          setup.id,
          (setup) => setup.copyWith(
            status: RoastSetupStatus.active,
            groupKeyHex: event.groupKeyHex,
            clearPendingDkgProposal: true,
            clearError: true,
          ),
        );
        final active = _setupById(setup.id);
        await _activateRoastAccount(active, event.groupKeyHex);
        await _markTransitionReadyForSetup(setup.id);
        await _recordSetupActivity(
          active,
          id: 'dkg-completed:${setup.id}:${event.keyName}',
          type: WalletActivityType.dkgCompleted,
          reference: event.keyName,
        );
      case RoastRuntimeFailureEvent()
          when event.operation == RoastRuntimeOperation.signatures ||
              event.operation == RoastRuntimeOperation.signingPersistence:
        final error = WalletSigningFailure(
          event.operation == RoastRuntimeOperation.signatures &&
                  !event.interrupted
              ? WalletSigningFailureKind.rejected
              : WalletSigningFailureKind.interrupted,
          event.message,
        );
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
      case RoastRuntimeFailureEvent():
        if (event.operation == RoastRuntimeOperation.dkg ||
            event.operation == RoastRuntimeOperation.keyReadiness) {
          await _recordSetupActivity(
            setup,
            id:
                'dkg-failed:${setup.id}:'
                '${setup.pendingDkgProposalHex ?? setup.keyName}:'
                '${event.operation.name}',
            type: WalletActivityType.dkgFailed,
            reference: setup.pendingDkgProposalHex ?? setup.keyName,
            details: event.message,
          );
        }
        if (event.interrupted) _roastPresence.remove(event.setupId);
        await _updateSetup(
          setup.id,
          (setup) => setup.copyWith(
            status: event.interrupted
                ? RoastSetupStatus.interrupted
                : RoastSetupStatus.error,
            errorMessage: event.message,
          ),
        );
      case RoastRuntimeSigningRequestEvent()
          when event.request.creator == setup.localParticipant.identifierHex:
        final requestKey = '${setup.id}:${event.request.idHex}';
        if (event.request.kind == RoastSigningRequestKind.message &&
            _pendingRoastMessages.containsKey(requestKey)) {
          _pendingRoastMessageProgress[requestKey] = event.request.progress;
          _notifyListeners();
        }
        return;
      case RoastRuntimeSigningRequestEvent():
        final requestKey = '${setup.id}:${event.request.idHex}';
        try {
          _validateRoastSigningRequest(setup, event.request);
          final account = accounts.firstWhere(
            (item) => item.sourceId == setup.id,
          );
          final isNew = !_roastSigningRequests.containsKey(requestKey);
          final inboxItem = RoastSigningInboxItem(
            setupId: setup.id,
            walletName: account.name,
            request: event.request,
          );
          _roastSigningRequests[requestKey] = inboxItem;
          if (isNew && event.request.status == 'waiting') {
            _announceRoastAction('signatures:$requestKey');
            final transactionRecipients = [
              if (event.request.kind == RoastSigningRequestKind.transaction)
                for (final output in event.request.outputs)
                  if (!isRoastChangeOutput(inboxItem, output))
                    WalletActivityRecipient(
                      address: roastOutputAddress(inboxItem, output),
                      amountSats: output.valueSats,
                    ),
            ];
            await _recordActivity(
              id: 'signature-request-received:$requestKey',
              accountId: account.id,
              type: WalletActivityType.signatureRequestReceived,
              reference: event.request.idHex,
              details: event.request.message.isEmpty
                  ? null
                  : event.request.message,
              transactionRecipients: transactionRecipients,
              transactionFeeSats:
                  event.request.kind == RoastSigningRequestKind.transaction
                  ? event.request.feeSats
                  : null,
            );
          }
          _notifyListeners();
        } on WalletTransactionFailure {
          // Unsupported or foreign proposals are deliberately not rendered.
        }
      case RoastRuntimeSigningRequestRemovedEvent():
        final requestKey = '${event.setupId}:${event.requestIdHex}';
        final removed = _roastSigningRequests.remove(requestKey);
        final wasLocallyRequestedMessage =
            _vault?.activities.any(
              (activity) =>
                  activity.id == 'message-signature-requested:$requestKey',
            ) ??
            false;
        if (event.expired && (removed != null || wasLocallyRequestedMessage)) {
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
        _roastSigningRequests.remove(pendingKey);
        _notifyListeners();
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
        _roastSigningRequests.remove('${setup.id}:${event.requestIdHex}');
        _notifyListeners();
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
          signedMessagePublicKeyHex: event.signedMessage.publicKeyHex,
          signedMessageSignatureHex: event.signedMessage.signatureHex,
          signedMessageEncoded: event.signedMessage.encoded,
        );
        _notifyListeners();
    }
  }
}

RoastSetupStatus _restoredRoastStatus(RoastSetup setup) {
  if (setup.groupKeyHex != null) return RoastSetupStatus.active;
  if (setup.pendingDkgProposalHex == null) return RoastSetupStatus.ready;
  return setup.pendingDkgStage == 'waiting'
      ? RoastSetupStatus.awaitingDkgApproval
      : RoastSetupStatus.creatingKey;
}
