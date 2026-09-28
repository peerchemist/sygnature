part of 'wallet_controller.dart';

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
      _issuedRoastInvitations[setupId] ?? const [];
  int onlineSignerCount(RoastSetup setup) {
    return setup.participants
        .where((participant) => isRoastParticipantOnline(setup, participant))
        .length;
  }

  bool isRoastParticipantOnline(
    RoastSetup setup,
    RoastParticipant participant,
  ) {
    if (participant.cardId == setup.localCardId) {
      final presence = _roastPresence[setup.id];
      return presence?.connected == true && presence?.signerRunning == true;
    }
    return setup.onlineParticipantIds.contains(participant.identifierHex);
  }

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
        'ROAST is available on supported desktop platforms only.',
      );
    }
    final cleanParticipantName = participantName.trim();
    if (cleanParticipantName.isEmpty) {
      throw ArgumentError('Participant name cannot be empty.');
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
      onlineParticipantIds: const [],
      keyName: roastKeyName(groupId),
      createdAt: DateTime.now().toUtc(),
      usesRoomEnrollment: true,
    );
    final account = WalletAccount(
      id: 'roast-$setupId-${selectedNetwork.storageId}-0',
      name: cleanWalletName,
      accountIndex: 0,
      blockchainId: selectedNetwork.blockchainId,
      networkId: selectedNetwork.networkId,
      keySource: WalletKeySource.roast,
      sourceId: setupId,
      keyId: setup.keyName,
      createdAt: DateTime.now().toUtc(),
    );
    final current = _vault;
    final next = current == null
        ? WalletVault(
            accounts: [account],
            nextAccountIndex: 0,
            roastSetups: [setup],
          )
        : current.copyWith(
            accounts: [...current.accounts, account],
            roastSetups: [...current.roastSetups, setup],
          );
    await _repository.save(next);
    _vault = next;
    _selectedAccount = next.accounts.length - 1;
    _notifyListeners();
    return setupId;
  }

  String participantCard(String setupId) {
    final setup = _setupById(setupId);
    final participant = setup.localParticipant;
    return RoastExchangeCodec.encodeParticipantCard(
      cardId: participant.cardId,
      name: participant.name,
      publicKeyHex: participant.publicKeyHex,
    );
  }

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
  ) async {
    final draft = _setupById(setupId);
    if (draft.role != RoastSetupRole.host) {
      throw StateError('Only a host can finalize this participant roster.');
    }
    final participants = _roastKeyService.finalizeRoster(
      draft,
      participantCards,
    );
    var setup = draft.copyWith(
      participants: participants,
      hostParticipantId: participants
          .singleWhere((participant) => participant.cardId == draft.localCardId)
          .identifierHex,
      status: RoastSetupStatus.connecting,
      clearError: true,
    );
    setup = setup.copyWith(
      groupFingerprintHex: _roastKeyService.groupFingerprint(setup),
    );
    await _replaceSetup(setup);
    try {
      final room = await _roastRuntime!.createRoom(setup);
      setup = setup.copyWith(
        coordinatorId: room.coordinatorId,
        coordinatorRelayUrls: room.coordinatorRelayUrls,
        coordinatorIpAddrs: room.coordinatorIpAddrs,
      );
      await _replaceSetup(setup);
      final invitations = [
        for (final invite in room.invites)
          RoastIssuedInvitation(
            participantName: participants
                .singleWhere(
                  (participant) =>
                      participant.publicKeyHex ==
                      invite.participantPublicKeyHex,
                )
                .name,
            participantPublicKeyHex: invite.participantPublicKeyHex,
            encoded: RoastExchangeCodec.encodeInvitation(
              setup,
              roomInvite: invite.encoded,
              participantPublicKeyHex: invite.participantPublicKeyHex,
              expiresAt: invite.expiresAt,
            ),
          ),
      ];
      _issuedRoastInvitations[setup.id] = invitations;
      _notifyListeners();
      return invitations;
    } catch (error) {
      await _replaceSetup(
        setup.copyWith(
          status: RoastSetupStatus.error,
          errorMessage: _cleanRoastError(error),
        ),
      );
      rethrow;
    }
  }

  Future<void> joinRoastSetup(String setupId, String invitation) async {
    final draft = _setupById(setupId);
    if (draft.role != RoastSetupRole.member) {
      throw StateError('This setup is not waiting for an invitation.');
    }
    final decoded = _roastKeyService.applyInvitation(draft, invitation);
    final setup = decoded.setup.copyWith(
      status: RoastSetupStatus.connecting,
      clearError: true,
    );
    final current = _vault!;
    final account = current.accounts.firstWhere(
      (item) => item.sourceId == setupId,
    );
    final replacementAccount = WalletAccount(
      id: 'roast-$setupId-${setup.blockchainId}:${setup.networkId}-0',
      name: account.name,
      accountIndex: 0,
      blockchainId: setup.blockchainId,
      networkId: setup.networkId,
      keySource: WalletKeySource.roast,
      sourceId: setupId,
      keyId: setup.keyName,
      createdAt: account.createdAt,
    );
    final next = current.copyWith(
      roastSetups: [
        for (final item in current.roastSetups)
          if (item.id == setupId) setup else item,
      ],
      accounts: [
        for (final item in current.accounts)
          if (item.sourceId == setupId) replacementAccount else item,
      ],
    );
    await _repository.save(next);
    _vault = next;
    _notifyListeners();
    try {
      final snapshot = await _roastRuntime!.joinRoom(setup, decoded.roomInvite);
      _roastPresence[setup.id] = _RoastPresence(
        connected: snapshot.connected,
        signerRunning: snapshot.signerRunning,
      );
      await _replaceSetup(
        setup.copyWith(
          status: snapshot.connected
              ? RoastSetupStatus.ready
              : RoastSetupStatus.connecting,
          onlineParticipantIds: snapshot.onlineParticipantIds,
          coordinatorId: snapshot.coordinatorId,
          coordinatorRelayUrls: snapshot.coordinatorRelayUrls,
          coordinatorIpAddrs: snapshot.coordinatorIpAddrs,
          clearError: true,
        ),
      );
    } catch (error) {
      await _replaceSetup(
        setup.copyWith(
          status: RoastSetupStatus.error,
          errorMessage: _cleanRoastError(error),
        ),
      );
      rethrow;
    }
  }

  Future<void> resumeRoastSetup(String setupId) async {
    final setup = _setupById(setupId);
    if (!setup.isFinalized || _roastOperations.contains(setupId)) return;
    await _startRoastRuntime(
      setup.copyWith(status: RoastSetupStatus.connecting),
    );
  }

  Future<void> startRoastDkg(String setupId) async {
    await _guardRoastOperation(setupId, () async {
      final setup = _setupById(setupId);
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
      await _replaceSetup(
        dkgSetup.copyWith(
          status: RoastSetupStatus.creatingKey,
          clearError: true,
        ),
      );
      try {
        await _roastRuntime!.requestDkg(dkgSetup);
      } on Object catch (error) {
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

  Future<void> acceptRoastDkg(String setupId) async {
    await _guardRoastOperation(setupId, () async {
      final setup = _setupById(setupId);
      final proposal = setup.pendingDkgProposalHex;
      if (proposal == null ||
          setup.pendingDkgName != setup.keyName ||
          setup.pendingDkgThreshold != setup.threshold ||
          setup.pendingDkgCreatorId != setup.hostParticipantId ||
          setup.pendingDkgExpiry?.isAfter(DateTime.now()) != true) {
        throw StateError('There is no DKG proposal to accept.');
      }
      await _replaceSetup(
        setup.copyWith(status: RoastSetupStatus.creatingKey, clearError: true),
      );
      await _roastRuntime!.acceptDkg(setupId, proposal);
    });
  }

  Future<void> rejectRoastDkg(String setupId) async {
    await _guardRoastOperation(setupId, () async {
      final setup = _setupById(setupId);
      final proposal = setup.pendingDkgProposalHex;
      if (proposal == null) {
        throw StateError('There is no DKG proposal to reject.');
      }
      await _roastRuntime!.rejectDkg(setupId, proposal);
      await _replaceSetup(
        setup.copyWith(
          status: RoastSetupStatus.ready,
          clearPendingDkgProposal: true,
        ),
      );
    });
  }

  Future<void> _guardRoastOperation(
    String setupId,
    Future<void> Function() operation,
  ) async {
    if (!_roastOperations.add(setupId)) return;
    _notifyListeners();
    try {
      await operation();
    } catch (error) {
      if (roastSetups.any((setup) => setup.id == setupId)) {
        await _replaceSetup(
          _setupById(setupId).copyWith(
            status: RoastSetupStatus.error,
            errorMessage: _cleanRoastError(error),
          ),
        );
      }
      rethrow;
    } finally {
      _roastOperations.remove(setupId);
      _notifyListeners();
    }
  }

  Future<void> _startRoastRuntime(RoastSetup setup) async {
    final runtime = _roastRuntime;
    if (runtime == null || !_roastOperations.add(setup.id)) return;
    _notifyListeners();
    try {
      await _replaceSetup(setup.copyWith(status: RoastSetupStatus.connecting));
      final snapshot = await runtime.startSetup(setup);
      _roastPresence[setup.id] = _RoastPresence(
        connected: snapshot.connected,
        signerRunning: snapshot.signerRunning,
      );
      final connected = setup.copyWith(
        status: snapshot.groupKeyHex == null
            ? snapshot.pendingDkgProposalHex == null
                  ? RoastSetupStatus.ready
                  : snapshot.pendingDkgStage != 'waiting'
                  ? RoastSetupStatus.creatingKey
                  : RoastSetupStatus.awaitingDkgApproval
            : RoastSetupStatus.active,
        onlineParticipantIds: snapshot.onlineParticipantIds,
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
        clearError: true,
      );
      await _replaceSetup(connected);
      final pendingDkgProposalHex = connected.pendingDkgProposalHex;
      if (connected.status == RoastSetupStatus.awaitingDkgApproval &&
          pendingDkgProposalHex != null) {
        _announceRoastAction('dkg:${connected.id}:$pendingDkgProposalHex');
      }
      if (snapshot.groupKeyHex != null) {
        await _activateRoastAccount(connected, snapshot.groupKeyHex!);
      }
    } catch (error) {
      _roastPresence.remove(setup.id);
      await _replaceSetup(
        setup.copyWith(
          status: RoastSetupStatus.error,
          errorMessage: _cleanRoastError(error),
        ),
      );
    } finally {
      _roastOperations.remove(setup.id);
      _notifyListeners();
    }
  }

  RoastSetup _setupById(String setupId) => roastSetups.firstWhere(
    (setup) => setup.id == setupId,
    orElse: () => throw ArgumentError.value(setupId, 'setupId'),
  );

  Future<void> _replaceSetup(RoastSetup replacement) async {
    final current = _vault;
    if (current == null) return;
    final previous = current.roastSetups
        .where((setup) => setup.id == replacement.id)
        .firstOrNull;
    if (previous != null && previous.status != replacement.status) {
      AppLogger.info(
        '${_roastLogScope(replacement.id)} State '
        '${previous.status.name} -> ${replacement.status.name}; '
        'dkgStage=${replacement.pendingDkgStage ?? '-'}, '
        'confirmed=${replacement.pendingDkgCompletedParticipantIds.length}/'
        '${replacement.participantCount}',
      );
    }
    final next = current.copyWith(
      roastSetups: [
        for (final setup in current.roastSetups)
          if (setup.id == replacement.id) replacement else setup,
      ],
    );
    await _repository.save(next);
    _vault = next;
    _notifyListeners();
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
    final current = _vault;
    if (current == null) return;
    final network = _networkById(setup.blockchainId, setup.networkId);
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
    final next = current.copyWith(
      accounts: [
        for (final account in current.accounts)
          if (account.sourceId == setup.id)
            account.copyWith(
              keyId: setup.keyName,
              derivationPath: derived.pathLabel,
              address: derived.address,
            )
          else
            account,
      ],
    );
    await _ensureNetworkService(network);
    await _repository.save(next);
    _vault = next;
    await _restartElectrumxSync();
  }

  static String _cleanRoastError(Object error) => switch (error) {
    NoosphereWorkerException(:final message) => message,
    ArgumentError() => error.toString(),
    StateError(:final message) => message,
    _ => 'Unable to connect to the ROAST coordinator.',
  };

  static String _roastLogScope(String setupId) {
    final shortId = setupId.length <= 8 ? setupId : setupId.substring(0, 8);
    return '[ROAST $shortId]';
  }
}
