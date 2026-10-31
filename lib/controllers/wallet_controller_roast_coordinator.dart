part of 'wallet_controller.dart';

extension WalletRoastCoordinatorController on WalletController {
  bool get roastCoordinatorSwitchAvailable =>
      _roastRuntime is RoastCoordinatorRuntime;
  RoastCoordinatorLocalState roastCoordinatorState(String setupId) {
    if (_roastCoordinatorSwitches.contains(setupId)) {
      return RoastCoordinatorLocalState.switching;
    }
    if (_roastCoordinatorRecovery.containsKey(setupId)) {
      return RoastCoordinatorLocalState.recoveryRequired;
    }
    final presence = _roastPresence[setupId];
    if (presence?.connected == true && presence?.signerRunning == true) {
      return RoastCoordinatorLocalState.connected;
    }
    final setup = _setupById(setupId);
    if (presence != null &&
        setup.status == RoastSetupStatus.ready &&
        setup.role == RoastSetupRole.host &&
        setup.usesRoomEnrollment &&
        enrolledRoastParticipantCount(setup) < setup.participantCount) {
      return RoastCoordinatorLocalState.enrolling;
    }
    return RoastCoordinatorLocalState.stopped;
  }

  RoastCoordinatorSwitchFailure? roastCoordinatorRecovery(String setupId) =>
      _roastCoordinatorRecovery[setupId];

  RoastCoordinatorAddress parseRoastCoordinatorAddress({
    required String id,
    required Iterable<String> relayUrls,
    required Iterable<String> ipAddrs,
  }) => RoastCoordinatorAddress.parse(
    id: id,
    relayUrls: relayUrls,
    ipAddrs: ipAddrs,
  );
  int onlineSignerCount(RoastSetup setup) {
    return setup.participants
        .where((participant) => isRoastParticipantOnline(setup, participant))
        .length;
  }

  bool isRoastParticipantOnline(
    RoastSetup setup,
    RoastParticipant participant,
  ) {
    final presence = _roastPresence[setup.id];
    if (presence?.connected != true) return false;
    if (participant.cardId == setup.localCardId) {
      return presence!.signerRunning;
    }
    return presence!.onlineParticipantIds.contains(participant.identifierHex);
  }

  List<String> onlineRoastParticipantIds(String setupId) {
    final presence = _roastPresence[setupId];
    return presence?.connected == true
        ? presence!.onlineParticipantIds
        : const [];
  }

  bool _setRoastPresence(
    String setupId, {
    required bool connected,
    required bool signerRunning,
    required List<String> onlineParticipantIds,
  }) {
    final previous = _roastPresence[setupId];
    if (previous?.connected == connected &&
        previous?.signerRunning == signerRunning &&
        listEquals(previous?.onlineParticipantIds, onlineParticipantIds)) {
      return false;
    }
    _roastPresence[setupId] = _RoastPresence(
      connected: connected,
      signerRunning: signerRunning,
      onlineParticipantIds: List.unmodifiable(onlineParticipantIds),
    );
    return true;
  }

  Future<void> switchRoastCoordinator(
    String setupId,
    RoastCoordinatorAddress newCoordinator, {
    required bool approved,
  }) async {
    if (!approved) {
      throw StateError(
        'Approve the exact coordinator endpoint ID before switching.',
      );
    }
    final runtime = _roastRuntime;
    if (runtime == null || runtime is! RoastCoordinatorRuntime) {
      throw UnsupportedError('Coordinator switching is not available.');
    }
    final coordinatorRuntime = runtime as RoastCoordinatorRuntime;
    final setup = _setupById(setupId);
    if (!setup.isFinalized || setup.coordinatorId == null) {
      throw StateError('The ROAST signer setup is not ready to switch.');
    }
    final unchangedIdentity = setup.coordinatorId == newCoordinator.id;
    final unchangedAddress =
        unchangedIdentity &&
        listEquals(setup.coordinatorRelayUrls, newCoordinator.relayUrls) &&
        listEquals(setup.coordinatorIpAddrs, newCoordinator.ipAddrs);
    if (unchangedAddress) {
      throw StateError('This coordinator address is already selected.');
    }
    if (!_roastOperations.add(setupId)) {
      throw StateError('Another ROAST operation is already in progress.');
    }
    _roastCoordinatorSwitches.add(setupId);
    _notifyListeners();
    Future<void>? persistence;
    try {
      final RoastRuntimeSnapshot snapshot;
      if (unchangedIdentity) {
        final write = _persistCoordinatorSelection(setupId, newCoordinator);
        persistence = write;
        try {
          await write;
        } on Object catch (error, stackTrace) {
          Error.throwWithStackTrace(
            RoastCoordinatorSwitchFailure(
              kind: RoastCoordinatorSwitchFailureKind.persistence,
              code: 'host_state',
              cause: error,
            ),
            stackTrace,
          );
        }
        snapshot = await coordinatorRuntime.updateCoordinatorAddress(
          _setupById(setupId),
          newCoordinator,
        );
      } else {
        snapshot = await coordinatorRuntime.switchCoordinator(
          setup,
          newCoordinator: newCoordinator,
          persist: (address) {
            final write = _persistCoordinatorSelection(setupId, address);
            persistence = write;
            return write;
          },
        );
      }
      _roastCoordinatorRecovery.remove(setupId);
      await _applyCoordinatorSnapshot(setupId, snapshot);
    } on RoastCoordinatorSwitchFailure catch (failure, stackTrace) {
      if (failure.kind == RoastCoordinatorSwitchFailureKind.persistence) {
        try {
          await persistence;
        } on Object {
          // The durable repository is authoritative after an ambiguous write.
        }
        await _recoverCoordinatorPersistence(setupId, runtime, failure);
      } else {
        await _requireCoordinatorRecovery(setupId, failure);
      }
      Error.throwWithStackTrace(failure, stackTrace);
    } on Object catch (error, stackTrace) {
      final failure = RoastCoordinatorSwitchFailure(
        kind: RoastCoordinatorSwitchFailureKind.connection,
        code: 'application_failure',
        cause: error,
      );
      await _requireCoordinatorRecovery(setupId, failure);
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      _roastCoordinatorSwitches.remove(setupId);
      _roastOperations.remove(setupId);
      _notifyListeners();
    }
  }

  Future<void> resumeRoastSetup(String setupId) async {
    final setup = _setupById(setupId);
    if (setup.requiresBackupReconciliation) {
      throw StateError(
        'Compare the restored group with authenticated live participants before reconnecting.',
      );
    }
    if (!setup.isFinalized || _roastOperations.contains(setupId)) return;
    _cancelRoastReconnect(setupId);
    await _startRoastRuntime(
      setup.copyWith(status: RoastSetupStatus.connecting),
    );
  }

  Future<void> resetHostedRoastCoordinator(String setupId) async {
    final setup = _setupById(setupId);
    if (setup.role != RoastSetupRole.host) {
      throw StateError('Only the coordinator device can reset it.');
    }
    if (!setup.isFinalized) {
      throw StateError('Finalize the participant roster before resetting.');
    }
    final runtime = _roastRuntime;
    if (runtime == null) throw UnsupportedError('ROAST is unavailable.');
    await _guardRoastOperation(setupId, () async {
      _cancelRoastReconnect(setupId);
      await runtime.stopSetup(setupId);
      _roastPresence.remove(setupId);
    });
    await resumeRoastSetup(setupId);
    final state = roastCoordinatorState(setupId);
    if (state != RoastCoordinatorLocalState.connected &&
        state != RoastCoordinatorLocalState.enrolling) {
      throw StateError('The ROAST coordinator could not be restarted.');
    }
  }

  Future<void> _persistCoordinatorSelection(
    String setupId,
    RoastCoordinatorAddress address,
  ) => _updateSetup(setupId, (existing) {
    if (existing.coordinatorId == address.id &&
        listEquals(existing.coordinatorRelayUrls, address.relayUrls) &&
        listEquals(existing.coordinatorIpAddrs, address.ipAddrs)) {
      return existing;
    }
    return existing.copyWith(
      coordinatorId: address.id,
      coordinatorRelayUrls: List.unmodifiable(address.relayUrls),
      coordinatorIpAddrs: List.unmodifiable(address.ipAddrs),
    );
  });

  Future<void> _recoverCoordinatorPersistence(
    String setupId,
    RoastRuntime runtime,
    RoastCoordinatorSwitchFailure failure,
  ) async {
    try {
      final selected = await _queueVaultMutation(() async {
        final stored = await _repository.load();
        if (stored == null) throw StateError('The wallet vault is missing.');
        final selected = stored.roastSetups.singleWhere(
          (setup) => setup.id == setupId,
        );
        _vault = stored;
        _vaultNeedsReload = false;
        _notifyListeners();
        return selected;
      });
      final snapshot = await runtime.startSetup(selected);
      _roastCoordinatorRecovery.remove(setupId);
      await _applyCoordinatorSnapshot(setupId, snapshot);
    } on Object catch (recoveryError) {
      await _requireCoordinatorRecovery(
        setupId,
        RoastCoordinatorSwitchFailure(
          kind: RoastCoordinatorSwitchFailureKind.persistence,
          code: failure.code,
          cause: recoveryError,
        ),
      );
    }
  }

  Future<void> _requireCoordinatorRecovery(
    String setupId,
    RoastCoordinatorSwitchFailure failure,
  ) async {
    _roastCoordinatorRecovery[setupId] = failure;
    _roastPresence.remove(setupId);
    final setup = _setupById(setupId);
    await _updateSetup(
      setup.id,
      (setup) => setup.copyWith(
        status: RoastSetupStatus.interrupted,
        errorMessage: _coordinatorSwitchError(failure),
      ),
    );
  }

  Future<void> _applyCoordinatorSnapshot(
    String setupId,
    RoastRuntimeSnapshot snapshot,
  ) async {
    final presenceChanged = _setRoastPresence(
      setupId,
      connected: snapshot.connected,
      signerRunning: snapshot.signerRunning,
      onlineParticipantIds: snapshot.onlineParticipantIds,
    );
    final setup = _setupById(setupId);
    await _updateSetup(
      setup.id,
      (setup) => setup.copyWith(
        status: snapshot.connected && snapshot.signerRunning
            ? setup.groupKeyHex == null
                  ? RoastSetupStatus.ready
                  : RoastSetupStatus.active
            : RoastSetupStatus.interrupted,
        coordinatorId: snapshot.coordinatorId,
        coordinatorRelayUrls: snapshot.coordinatorRelayUrls,
        coordinatorIpAddrs: snapshot.coordinatorIpAddrs,
        clearError: snapshot.connected && snapshot.signerRunning,
      ),
      notifyIfUnchanged: presenceChanged,
    );
  }

  static String _coordinatorSwitchError(
    RoastCoordinatorSwitchFailure failure,
  ) => switch (failure.kind) {
    RoastCoordinatorSwitchFailureKind.pendingSigningOperations =>
      'Coordinator switch stopped because signing operations or nonce records '
          'are still pending. Reconcile them before retrying.',
    RoastCoordinatorSwitchFailureKind.persistence =>
      'Coordinator storage outcome requires recovery. The signer remains '
          'stopped until the durable selection is reconciled.',
    RoastCoordinatorSwitchFailureKind.connection =>
      'The approved coordinator is saved but the signer could not connect. '
          'Verify that it serves this exact group, then retry explicitly.',
  };

  Future<void> _startRoastRuntime(RoastSetup setup) {
    final pending = _roastStarts[setup.id];
    if (pending != null) return pending;
    final starting = _startRoastRuntimeNow(setup).whenComplete(() {
      _roastStarts.remove(setup.id);
    });
    _roastStarts[setup.id] = starting;
    return starting;
  }

  Future<void> _startRoastRuntimeNow(RoastSetup setup) async {
    if (_busy) throw const WalletBusyFailure();
    if (setup.requiresBackupReconciliation) {
      throw StateError('Restored group requires live reconciliation.');
    }
    final runtime = _roastRuntime;
    if (runtime == null || !_roastOperations.add(setup.id)) return;
    _notifyListeners();
    try {
      await _updateSetup(
        setup.id,
        (setup) => setup.copyWith(status: RoastSetupStatus.connecting),
      );
      final snapshot = await runtime.startSetup(setup);
      final waitingForEnrollment =
          setup.role == RoastSetupRole.host &&
          setup.usesRoomEnrollment &&
          setup.groupKeyHex == null &&
          enrolledRoastParticipantCount(setup) < setup.participantCount &&
          snapshot.coordinatorId != null &&
          !snapshot.connected &&
          !snapshot.signerRunning;
      _setRoastPresence(
        setup.id,
        connected: snapshot.connected,
        signerRunning: snapshot.signerRunning,
        onlineParticipantIds: snapshot.onlineParticipantIds,
      );
      if (snapshot.connected && snapshot.signerRunning) {
        _roastCoordinatorRecovery.remove(setup.id);
        _cancelRoastReconnect(setup.id);
      }
      final groupWasActive =
          setup.groupKeyHex == snapshot.groupKeyHex &&
          accounts.any(
            (account) =>
                account.sourceId == setup.id &&
                account.derivationState == WalletDerivationState.ready,
          );
      await _updateSetup(
        setup.id,
        (setup) => setup.copyWith(
          status: waitingForEnrollment
              ? RoastSetupStatus.ready
              : !snapshot.connected || !snapshot.signerRunning
              ? RoastSetupStatus.interrupted
              : snapshot.groupKeyHex == null
              ? snapshot.pendingDkgProposalHex == null
                    ? RoastSetupStatus.ready
                    : snapshot.pendingDkgStage != 'waiting'
                    ? RoastSetupStatus.creatingKey
                    : RoastSetupStatus.awaitingDkgApproval
              : RoastSetupStatus.active,
          coordinatorId: snapshot.coordinatorId,
          coordinatorRelayUrls: snapshot.coordinatorRelayUrls,
          coordinatorIpAddrs: snapshot.coordinatorIpAddrs,
          groupKeyHex: snapshot.groupKeyHex,
          pendingDkgProposalHex: snapshot.pendingDkgProposalHex,
          pendingDkgStage: snapshot.pendingDkgStage,
          pendingDkgCompletedParticipantIds:
              snapshot.pendingDkgCompletedParticipantIds,
          pendingDkgName: snapshot.pendingDkgName,
          pendingDkgThreshold: snapshot.pendingDkgThreshold,
          pendingDkgCreatorId: snapshot.pendingDkgCreator,
          pendingDkgExpiry: snapshot.pendingDkgExpiry,
          clearPendingDkgProposal: snapshot.pendingDkgProposalHex == null,
          clearError:
              waitingForEnrollment ||
              snapshot.connected && snapshot.signerRunning,
        ),
      );
      final connected = _setupById(setup.id);
      final pendingDkgProposalHex = connected.pendingDkgProposalHex;
      if (connected.status == RoastSetupStatus.awaitingDkgApproval &&
          pendingDkgProposalHex != null) {
        await _announceRoastAction(
          'dkg:${connected.id}:$pendingDkgProposalHex',
          onDkgRequest,
        );
      }
      if (snapshot.groupKeyHex != null) {
        await _activateRoastAccount(connected, snapshot.groupKeyHex!);
        await _markTransitionReadyForSetup(setup.id);
        if (!groupWasActive) {
          await _announceRoastAction(
            'group-created:${setup.id}:${connected.keyName}',
            onRoastGroupCreated,
          );
        }
      }
    } catch (error) {
      _roastPresence.remove(setup.id);
      await _updateSetup(
        setup.id,
        (setup) => setup.copyWith(
          status: RoastSetupStatus.error,
          errorMessage: WalletRoastSetupController._cleanRoastError(error),
        ),
      );
      if (_shouldAutoReconnectRoastSetup(setup.id)) {
        _scheduleRoastReconnect(setup.id);
      }
    } finally {
      _roastOperations.remove(setup.id);
      _notifyListeners();
    }
  }

  bool _shouldAutoReconnectRoastSetup(String setupId) =>
      !_disposed &&
      !_roastCoordinatorRecovery.containsKey(setupId) &&
      accounts.any(
        (account) =>
            !account.isArchived &&
            account.keySource == WalletKeySource.roast &&
            account.sourceId == setupId,
      );

  void _scheduleRoastReconnect(String setupId) {
    if (!_shouldAutoReconnectRoastSetup(setupId) ||
        _roastReconnectTimers.containsKey(setupId)) {
      return;
    }
    final attempt = _roastReconnectAttempts[setupId] ?? 0;
    final multiplier = 1 << (attempt > 4 ? 4 : attempt);
    final retryMilliseconds =
        WalletController._initialRoastReconnectDelay.inMilliseconds *
        multiplier;
    final maxMilliseconds =
        WalletController._maxRoastReconnectDelay.inMilliseconds;
    final delay = Duration(
      milliseconds: retryMilliseconds < maxMilliseconds
          ? retryMilliseconds
          : maxMilliseconds,
    );
    _roastReconnectAttempts[setupId] = attempt + 1;
    AppLogger.info(
      '${WalletRoastSetupController._roastLogScope(setupId)} Reconnecting in ${delay.inSeconds}s',
    );
    _roastReconnectTimers[setupId] = Timer(delay, () {
      _roastReconnectTimers.remove(setupId);
      unawaited(_retryRoastSetup(setupId));
    });
  }

  Future<void> _retryRoastSetup(String setupId) async {
    if (!_shouldAutoReconnectRoastSetup(setupId)) {
      _cancelRoastReconnect(setupId);
      return;
    }
    if (_busy || _roastOperations.contains(setupId)) {
      _scheduleRoastReconnect(setupId);
      return;
    }
    try {
      final setup = _setupById(setupId);
      await _startRoastRuntime(
        setup.copyWith(status: RoastSetupStatus.connecting),
      );
    } catch (error, stackTrace) {
      AppLogger.error(
        '${WalletRoastSetupController._roastLogScope(setupId)} Automatic reconnect failed',
        error: error,
        stackTrace: stackTrace,
      );
      _scheduleRoastReconnect(setupId);
    }
  }

  void _cancelRoastReconnect(String setupId) {
    _roastReconnectTimers.remove(setupId)?.cancel();
    _roastReconnectAttempts.remove(setupId);
  }
}
