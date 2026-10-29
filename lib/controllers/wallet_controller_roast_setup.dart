part of 'wallet_controller.dart';

enum _RoastJoinPhase { invitation, enrollment, localSetup, signerStartup }

extension WalletRoastSetupController on WalletController {
  List<RoastSetup> get roastSetups => _vault?.roastSetups ?? const [];
  bool get roastAvailable => _roastRuntime != null;
  RoastSetup? setupForAccount(WalletAccount account) {
    final setupId = account.sourceId;
    if (account.keySource != WalletKeySource.roast || setupId == null) {
      return null;
    }
    return roastSetups.where((setup) => setup.id == setupId).firstOrNull;
  }

  bool roastOperationInProgress(String setupId) =>
      _roastOperations.contains(setupId);
  List<RoastIssuedInvitation> issuedRoastInvitations(String setupId) =>
      _setupById(setupId).invitations;
  int enrolledRoastParticipantCount(RoastSetup setup) {
    if (setup.invitations.isEmpty &&
        setup.role == RoastSetupRole.host &&
        setup.status != RoastSetupStatus.draft &&
        setup.status != RoastSetupStatus.connecting) {
      return setup.participantCount;
    }
    return 1 +
        setup.invitations.where((invitation) {
          return invitation.statusAt(DateTime.now().toUtc()) ==
              RoastInvitationDisplayStatus.joined;
        }).length;
  }

  Future<void> markRoastInvitationCopied(
    String setupId,
    String participantPublicKeyHex,
  ) => _updateRoastInvitation(
    setupId,
    participantPublicKeyHex,
    (invitation) => invitation.copyWith(copiedAt: DateTime.now().toUtc()),
  );

  Future<void> markRoastInvitationSent(
    String setupId,
    String participantPublicKeyHex,
  ) => _updateRoastInvitation(
    setupId,
    participantPublicKeyHex,
    (invitation) => invitation.copyWith(sentAt: DateTime.now().toUtc()),
  );
  Future<String> createRoastSetupDraft({
    required RoastSetupRole role,
    required String walletName,
    required String participantName,
    required int threshold,
    required int participantCount,
    required WalletNetwork network,
  }) async {
    if (_roastRuntime == null) {
      throw UnsupportedError(
        'ROAST is unavailable in this application session.',
      );
    }
    final cleanParticipantName = participantName.trim();
    if (cleanParticipantName.isEmpty) {
      throw ArgumentError('Participant name cannot be empty.');
    }
    if (participantCount < 2 || participantCount > 0xffff) {
      throw ArgumentError('Participant count must be between 2 and 65535.');
    }
    if (threshold < 2 || threshold > participantCount) {
      throw ArgumentError('Threshold must be between 2 and participant count.');
    }
    final cleanWalletName = walletName.trim().isEmpty
        ? 'Shared wallet'
        : walletName.trim();
    final material = _roastKeyService.generateParticipant();
    final setupId = _roastKeyService.newSetupId();
    final groupId = _roastKeyService.newSetupId();
    final selectedNetwork = _networkById(
      network.blockchainId,
      network.networkId,
    );
    final setup = RoastSetup(
      id: setupId,
      groupId: groupId,
      name: cleanWalletName,
      role: role,
      status: RoastSetupStatus.draft,
      threshold: threshold,
      participantCount: participantCount,
      blockchainId: selectedNetwork.blockchainId,
      networkId: selectedNetwork.networkId,
      localCardId: material.cardId,
      localParticipantPrivateKeyHex: material.privateKeyHex,
      participants: [
        RoastParticipant(
          cardId: material.cardId,
          name: cleanParticipantName,
          identifierHex: '',
          publicKeyHex: material.publicKeyHex,
        ),
      ],
      keyName: roastKeyName(groupId),
      createdAt: DateTime.now().toUtc(),
      irohIdentityIndex: irohIdentityIndexForSetup(setupId),
      usesRoomEnrollment: true,
    );
    final account = _pendingRoastAccount(setup);
    await _updateVault(
      (current) => current == null
          ? WalletVault(
              accounts: [account],
              nextAccountIndex: 0,
              roastSetups: [setup],
              selectedAccountId: account.id,
            )
          : current.copyWith(
              accounts: [...current.accounts, account],
              roastSetups: [...current.roastSetups, setup],
              selectedAccountId: account.id,
            ),
      updateSelection: true,
    );
    return setupId;
  }

  WalletAccount _pendingRoastAccount(
    RoastSetup setup, {
    String? name,
    DateTime? createdAt,
  }) => WalletAccount(
    id: 'roast-${setup.id}-${setup.blockchainId}:${setup.networkId}-0',
    name: name ?? setup.name,
    accountIndex: 0,
    blockchainId: setup.blockchainId,
    networkId: setup.networkId,
    derivationState: WalletDerivationState.pending,
    keySource: WalletKeySource.roast,
    sourceId: setup.id,
    keyId: setup.keyName,
    createdAt: createdAt ?? DateTime.now().toUtc(),
  );

  String participantPublicKey(String setupId) =>
      _setupById(setupId).localParticipant.publicKeyHex;

  String normalizeRoastParticipantPublicKey(String value) =>
      _roastKeyService.normalizeParticipantPublicKey(value);

  Future<List<RoastIssuedInvitation>> createHostedRoastInvitations(
    String setupId,
    List<({String name, String publicKeyHex})> invitees,
  ) => finalizeHostedRoastSetup(setupId, [
    for (final invitee in invitees)
      _roastKeyService.participantCardFromPublicKey(
        name: invitee.name,
        publicKeyHex: invitee.publicKeyHex,
      ),
  ]);

  Future<List<RoastIssuedInvitation>> finalizeHostedRoastSetup(
    String setupId,
    List<String> participantCards,
  ) => _guardRoastOperation(setupId, () async {
    final draft = _setupById(setupId);
    if (draft.role != RoastSetupRole.host) {
      throw StateError('Only a host can finalize this participant roster.');
    }
    final setup = _finalizeRoastRoster(draft, participantCards);
    await _updateSetup(setup.id, (_) => setup);
    return _createHostedRoastInvitations(setup);
  }, errorMessage: _cleanRoastInvitationError);

  RoastSetup _finalizeRoastRoster(RoastSetup draft, List<String> cards) {
    final participants = _roastKeyService.finalizeRoster(draft, cards);
    final setup = draft.copyWith(
      participants: participants,
      hostParticipantId: participants
          .singleWhere((participant) => participant.cardId == draft.localCardId)
          .identifierHex,
      status: RoastSetupStatus.connecting,
      clearError: true,
    );
    return setup.copyWith(
      groupFingerprintHex: _roastKeyService.groupFingerprint(setup),
    );
  }

  Future<List<RoastIssuedInvitation>> retryHostedRoastInvitations(
    String setupId,
  ) => _guardRoastOperation(setupId, () async {
    final setup = _setupById(setupId);
    if (!setup.needsInvitationCreation) {
      throw StateError('Signer invitations are not waiting to be created.');
    }
    await _updateSetup(
      setup.id,
      (latest) => latest.copyWith(
        status: RoastSetupStatus.connecting,
        clearError: true,
      ),
    );
    return _createHostedRoastInvitations(_setupById(setupId));
  }, errorMessage: _cleanRoastInvitationError);

  Future<List<RoastIssuedInvitation>> _createHostedRoastInvitations(
    RoastSetup setup,
  ) async {
    try {
      final room = await _roastRuntime!.createRoom(
        setup,
        beforeInvitations: (room) => _updateSetup(
          setup.id,
          (latest) => latest.copyWith(
            coordinatorId: room.coordinatorId,
            coordinatorRelayUrls: room.coordinatorRelayUrls,
            coordinatorIpAddrs: room.coordinatorIpAddrs,
          ),
        ),
      );
      setup = _setupById(setup.id);
      final invitations = _roomInvitations(setup, room);
      await _updateSetup(
        setup.id,
        (latest) => latest.copyWith(invitations: invitations),
      );
      return invitations;
    } catch (error, stackTrace) {
      AppLogger.error(
        '${_roastLogScope(setup.id)} Signer invitation creation failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  List<RoastIssuedInvitation> _roomInvitations(
    RoastSetup setup,
    RoastRoomCreation room,
  ) => [
    for (final invite in room.invites)
      RoastIssuedInvitation(
        participantName: setup.participants
            .singleWhere(
              (participant) =>
                  participant.publicKeyHex ==
                  invite.invite.expectedParticipantPublicKey.hex,
            )
            .name,
        participantPublicKeyHex: invite.invite.expectedParticipantPublicKey.hex,
        issuedAt: DateTime.now().toUtc(),
        expiresAt: invite.invite.expiresAt,
        encoded: invite.encode(),
      ),
  ];

  Future<void> joinRoastSetup(String setupId, String invitation) async {
    final draft = _setupById(setupId);
    if (!draft.isWaitingForInvitation) {
      throw StateError('This setup is not waiting for an invitation.');
    }
    var phase = _RoastJoinPhase.invitation;
    try {
      // This validates the bound identity key before the runtime opens Iroh.
      final invite = NoosphereRoomInvite.decode(
        normalizeSygnatureRoomInvite(invitation),
        prefix: sygnatureRoomInvitePrefix,
      );
      _roastKeyService.validateRoomInvite(draft, invite);
      phase = _RoastJoinPhase.enrollment;
      final enrollment = await _roastRuntime!.joinRoom(draft, invite);
      phase = _RoastJoinPhase.localSetup;
      final enrolled = _roastKeyService.applyRoomEnrollment(
        draft,
        invite.invite,
        enrollment,
      );
      await _updateVault((current) {
        if (current == null) throw StateError('Wallet is not initialized.');
        final account = current.accounts.firstWhere(
          (item) => item.sourceId == setupId,
        );
        final replacementAccount = _pendingRoastAccount(
          enrolled,
          name: account.name,
          createdAt: account.createdAt,
        );
        return current.copyWith(
          roastSetups: [
            for (final item in current.roastSetups)
              if (item.id == setupId) enrolled else item,
          ],
          accounts: [
            for (final item in current.accounts)
              if (item.sourceId == setupId) replacementAccount else item,
          ],
        );
      });
      phase = _RoastJoinPhase.signerStartup;
      final snapshot = await _roastRuntime.startSetup(enrolled);
      _setRoastPresence(
        enrolled.id,
        connected: snapshot.connected,
        signerRunning: snapshot.signerRunning,
        onlineParticipantIds: snapshot.onlineParticipantIds,
      );
      if (snapshot.connected && snapshot.signerRunning) {
        _roastCoordinatorRecovery.remove(enrolled.id);
      }
      await _updateSetup(
        enrolled.id,
        (setup) => setup.copyWith(
          status: snapshot.connected
              ? RoastSetupStatus.ready
              : RoastSetupStatus.connecting,
          coordinatorId: snapshot.coordinatorId,
          clearError: true,
        ),
      );
    } catch (error) {
      AppLogger.error(
        '${_roastLogScope(draft.id)} Join failed during ${phase.name}',
        error: error,
      );
      await _updateSetup(
        draft.id,
        (setup) => setup.copyWith(
          status: setup.isFinalized
              ? RoastSetupStatus.error
              : RoastSetupStatus.draft,
          errorMessage: _cleanRoastJoinError(error, phase),
        ),
      );
      rethrow;
    }
  }

  Future<void> _updateRoastInvitation(
    String setupId,
    String participantPublicKeyHex,
    RoastIssuedInvitation Function(RoastIssuedInvitation invitation) update,
  ) async {
    await _updateSetup(setupId, (setup) {
      final invitations = [
        for (final invitation in setup.invitations)
          if (invitation.participantPublicKeyHex == participantPublicKeyHex)
            update(invitation)
          else
            invitation,
      ];
      if (!setup.invitations.any(
        (invitation) =>
            invitation.participantPublicKeyHex == participantPublicKeyHex,
      )) {
        throw StateError('The participant invitation is not available.');
      }
      return setup.copyWith(invitations: invitations);
    });
  }

  Future<void> startRoastDkg(
    String setupId, {
    required String confirmedGroupFingerprintHex,
  }) async {
    await _guardRoastOperation(setupId, () async {
      final setup = _setupById(setupId);
      _requireRoastManifestConfirmation(setup, confirmedGroupFingerprintHex);
      if (setup.role != RoastSetupRole.host) {
        throw StateError('Only the setup host can start key creation.');
      }
      if (onlineSignerCount(setup) < setup.participantCount) {
        throw StateError(
          'All participants must be online before key creation.',
        );
      }
      final dkgSetup = setup.copyWith(
        keyName: normalizeRoastKeyName(setup.groupId, setup.keyName),
      );
      final transition = groupTransitions
          .where((item) => item.successorSetupId == setupId)
          .firstOrNull;
      final keyPlan = transition?.proposal.keyPlans.single;
      final approvedDetails = keyPlan == null
          ? null
          : transition!.dkgDetailsByKey[keyPlan.keyId];
      if (transition != null && approvedDetails == null) {
        throw StateError('The approved transition DKG details are missing.');
      }
      await _updateSetup(
        dkgSetup.id,
        (latest) => latest.copyWith(
          keyName: dkgSetup.keyName,
          status: RoastSetupStatus.creatingKey,
          clearError: true,
        ),
      );
      if (transition != null) {
        await _updateGroupTransition(
          transition.transitionId,
          (transition) => transition.copyWith(
            phase: WalletGroupTransitionPhase.preparing,
            clearError: true,
          ),
        );
      }
      try {
        await _roastRuntime!.requestDkg(
          dkgSetup,
          approvedDetails: approvedDetails,
          transitionKeyPlan: keyPlan,
        );
      } on Object catch (error) {
        if (transition != null) {
          await _updateGroupTransition(
            transition.transitionId,
            (transition) => transition.copyWith(
              phase: WalletGroupTransitionPhase.failed,
              errorMessage: _cleanRoastError(error),
            ),
          );
        }
        await _recordSetupActivity(
          dkgSetup,
          id:
              'dkg-failed:${dkgSetup.id}:request:'
              '${DateTime.now().microsecondsSinceEpoch}',
          type: WalletActivityType.dkgFailed,
          reference: dkgSetup.keyName,
          details: _cleanRoastError(error),
        );
        rethrow;
      }
    });
  }

  Future<void> acceptRoastDkg(
    String setupId, {
    required String confirmedGroupFingerprintHex,
  }) async {
    await _guardRoastOperation(setupId, () async {
      final setup = _setupById(setupId);
      _requireRoastManifestConfirmation(setup, confirmedGroupFingerprintHex);
      final proposal = setup.pendingDkgProposalHex;
      if (proposal == null ||
          setup.pendingDkgName != setup.keyName ||
          setup.pendingDkgThreshold != setup.threshold ||
          setup.pendingDkgCreatorId != setup.hostParticipantId ||
          setup.pendingDkgExpiry?.isAfter(DateTime.now()) != true) {
        throw StateError('There is no DKG proposal to accept.');
      }
      await _updateSetup(
        setup.id,
        (setup) => setup.copyWith(
          status: RoastSetupStatus.creatingKey,
          clearError: true,
        ),
      );
      await _roastRuntime!.acceptDkg(setupId, proposal);
    });
  }

  static void _requireRoastManifestConfirmation(
    RoastSetup setup,
    String confirmedGroupFingerprintHex,
  ) {
    final fingerprint = setup.groupFingerprintHex;
    if (fingerprint == null ||
        fingerprint.isEmpty ||
        confirmedGroupFingerprintHex != fingerprint) {
      throw StateError(
        'Confirm the current ROAST group manifest before key creation.',
      );
    }
  }

  Future<void> rejectRoastDkg(String setupId) async {
    await _guardRoastOperation(setupId, () async {
      final setup = _setupById(setupId);
      final proposal = setup.pendingDkgProposalHex;
      if (proposal == null) {
        throw StateError('There is no DKG proposal to reject.');
      }
      await _roastRuntime!.rejectDkg(setupId, proposal);
      await _updateSetup(
        setup.id,
        (setup) => setup.copyWith(
          status: RoastSetupStatus.ready,
          clearPendingDkgProposal: true,
        ),
      );
    });
  }

  Future<T> _guardRoastOperation<T>(
    String setupId,
    Future<T> Function() operation, {
    String Function(Object error)? errorMessage,
  }) async {
    if (_busy) throw const WalletBusyFailure();
    if (_setupById(setupId).requiresBackupReconciliation) {
      throw StateError('Restored group requires live reconciliation.');
    }
    if (!_roastOperations.add(setupId)) throw const WalletBusyFailure();
    _notifyListeners();
    try {
      return await operation();
    } catch (error) {
      if (roastSetups.any(
        (setup) => setup.id == setupId && setup.isFinalized,
      )) {
        await _updateSetup(
          setupId,
          (setup) => setup.copyWith(
            status: RoastSetupStatus.error,
            errorMessage: errorMessage?.call(error) ?? _cleanRoastError(error),
          ),
        );
      }
      rethrow;
    } finally {
      _roastOperations.remove(setupId);
      _notifyListeners();
    }
  }

  RoastSetup _setupById(String setupId) => roastSetups.firstWhere(
    (setup) => setup.id == setupId,
    orElse: () => throw ArgumentError.value(setupId, 'setupId'),
  );

  Future<void> _updateSetup(
    String setupId,
    RoastSetup Function(RoastSetup setup) update, {
    bool notifyIfUnchanged = false,
  }) async {
    var changed = false;
    await _updateVault((current) {
      if (current == null) return current;
      final previous = current.roastSetups
          .where((setup) => setup.id == setupId)
          .firstOrNull;
      if (previous == null) return current;
      final replacement = update(previous);
      if (identical(previous, replacement)) return current;
      changed = true;
      if (previous.status != replacement.status) {
        AppLogger.info(
          '${_roastLogScope(replacement.id)} State '
          '${previous.status.name} -> ${replacement.status.name}; '
          'dkgStage=${replacement.pendingDkgStage ?? '-'}, '
          'confirmed=${replacement.pendingDkgCompletedParticipantIds.length}/'
          '${replacement.participantCount}',
        );
      }
      return current.copyWith(
        roastSetups: [
          for (final setup in current.roastSetups)
            if (setup.id == setupId) replacement else setup,
        ],
      );
    });
    if (notifyIfUnchanged && !changed) _notifyListeners();
  }

  static bool _dkgMatchesSetup(RoastRuntimeDkgEvent event, RoastSetup setup) =>
      _dkgDefinitionMatchesSetup(event, setup) &&
      event.creator == setup.hostParticipantId &&
      event.expiry.isAfter(DateTime.now());

  static bool _dkgDefinitionMatchesSetup(
    RoastRuntimeDkgEvent event,
    RoastSetup setup,
  ) =>
      event.name == setup.keyName &&
      event.threshold == setup.threshold &&
      event.description == roastKeyDescription(setup);

  Future<void> _activateRoastAccount(
    RoastSetup setup,
    String groupKeyHex,
  ) async {
    final network = _networkById(setup.blockchainId, setup.networkId);
    final previousService = _networkServices[network.storageId];
    await _ensureNetworkService(network);
    var accountChanged = false;
    await _updateVault((current) {
      if (current == null) return current;
      final account = current.accounts.firstWhere(
        (item) => item.sourceId == setup.id,
      );
      final derived = _roastKeyService.deriveAddress(
        groupKeyHex: groupKeyHex,
        threshold: setup.threshold,
        network: network,
        accountIndex: 0,
        pathLabel: account.derivationPath,
      );
      if (account.keyId == setup.keyName &&
          account.derivationState == WalletDerivationState.ready &&
          account.derivationPath == derived.pathLabel &&
          account.address == derived.address) {
        return current;
      }
      accountChanged = true;
      return current.copyWith(
        accounts: [
          for (final account in current.accounts)
            if (account.sourceId == setup.id)
              account.copyWith(
                keyId: setup.keyName,
                derivationState: WalletDerivationState.ready,
                derivationPath: derived.pathLabel,
                addressPathPrefix: derived.pathLabel.substring(
                  0,
                  derived.pathLabel.lastIndexOf('/') + 1,
                ),
                address: derived.address,
              )
            else
              account,
        ],
      );
    });
    if (accountChanged ||
        !identical(previousService, _networkServices[network.storageId])) {
      await _restartElectrumxSync();
    }
  }

  static String _cleanRoastError(Object error) => switch (error) {
    RoastEnrollmentFailure(
      kind: RoastEnrollmentFailureKind.rejected,
      :final roomFailureCode,
    ) =>
      switch (roomFailureCode) {
        6 => 'This room invitation has expired.',
        7 => 'This room invitation has already been used.',
        8 => 'This room invitation was revoked.',
        0xffff => 'The coordinator rejected room enrollment.',
        _ =>
          'The coordinator rejected room enrollment '
              '(room code $roomFailureCode).',
      },
    RoastEnrollmentFailure(kind: RoastEnrollmentFailureKind.timeout) =>
      'Room enrollment timed out. The invitation may already be used; check '
          'the coordinator before retrying.',
    RoastEnrollmentFailure(
      kind: RoastEnrollmentFailureKind.malformedResponse,
    ) =>
      'The coordinator returned an invalid enrollment response. The '
          'invitation may already be used; check the coordinator before '
          'retrying.',
    RoastEnrollmentFailure(kind: RoastEnrollmentFailureKind.connection) =>
      'The enrollment connection was interrupted. The invitation may already '
          'be used; check the coordinator before retrying.',
    NoosphereWorkerException(:final code) => switch (code) {
      'invalid_state' =>
        'The ROAST operation is not valid in the current state.',
      'timeout' || 'host_timeout' => 'The ROAST operation timed out.',
      'worker_closed' ||
      'worker_closing' ||
      'worker_exited' => 'The ROAST worker is unavailable.',
      _ => 'The ROAST operation failed.',
    },
    _ => 'Unable to connect to the ROAST coordinator.',
  };

  static String _cleanRoastInvitationError(Object error) => switch (error) {
    TimeoutException() ||
    NoosphereWorkerException(code: 'timeout' || 'host_timeout') =>
      'Creating signer invitations timed out. Check the network connection '
          'and try again.',
    NoosphereWorkerException(
      code: 'worker_closed' || 'worker_closing' || 'worker_exited',
    ) =>
      'The ROAST service stopped while creating signer invitations. Try '
          'again.',
    _ =>
      'Could not create signer invitations. Check the network connection and '
          'try again.',
  };

  static String _cleanRoastJoinError(
    Object error,
    _RoastJoinPhase phase,
  ) => switch (phase) {
    _RoastJoinPhase.invitation =>
      'This ROAST invitation is invalid, expired, or belongs to another '
          'signer.',
    _RoastJoinPhase.enrollment => _cleanRoastError(error),
    _RoastJoinPhase.localSetup =>
      'Room enrollment succeeded, but this device could not configure the '
          'shared wallet. The invitation has already been used.',
    _RoastJoinPhase.signerStartup =>
      'Room enrollment was saved, but the signer could not finish starting. '
          'Use Reconnect after the coordinator is ready.',
  };

  static String _roastLogScope(String setupId) {
    final shortId = setupId.length <= 8 ? setupId : setupId.substring(0, 8);
    return '[ROAST $shortId]';
  }
}
