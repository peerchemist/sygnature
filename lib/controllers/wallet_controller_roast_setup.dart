part of 'wallet_controller.dart';

extension WalletRoastSetupController on WalletController {
  List<RoastSetup> get roastSetups => _vault?.roastSetups ?? const [];
  List<WalletGroupTransition> get groupTransitions =>
      _vault?.groupTransitions ?? const [];
  bool get roastAvailable => _roastRuntime != null;
  bool get roastCoordinatorSwitchAvailable =>
      _roastRuntime is RoastCoordinatorRuntime;
  RoastSetup? setupForAccount(WalletAccount account) {
    final setupId = account.sourceId;
    if (account.keySource != WalletKeySource.roast || setupId == null) {
      return null;
    }
    return roastSetups.where((setup) => setup.id == setupId).firstOrNull;
  }

  bool roastOperationInProgress(String setupId) =>
      _roastOperations.contains(setupId);
  RoastCoordinatorLocalState roastCoordinatorState(String setupId) {
    if (_roastCoordinatorSwitches.contains(setupId)) {
      return RoastCoordinatorLocalState.switching;
    }
    if (_roastCoordinatorRecovery.containsKey(setupId)) {
      return RoastCoordinatorLocalState.recoveryRequired;
    }
    final presence = _roastPresence[setupId];
    return presence?.connected == true && presence?.signerRunning == true
        ? RoastCoordinatorLocalState.connected
        : RoastCoordinatorLocalState.stopped;
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
      irohIdentityIndex: irohIdentityIndexForSetup(setupId),
      usesRoomEnrollment: true,
    );
    final account = WalletAccount(
      id: 'roast-$setupId-${selectedNetwork.storageId}-0',
      name: cleanWalletName,
      accountIndex: 0,
      blockchainId: selectedNetwork.blockchainId,
      networkId: selectedNetwork.networkId,
      derivationState: WalletDerivationState.pending,
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
    _selectedAccountId = account.id;
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

  /// Any signer in an active source setup may host a proposed successor.
  Future<RoastGroupTransitionCreation> proposeRoastGroupTransition({
    required String sourceSetupId,
    required String successorWalletName,
    required int successorThreshold,
    required List<({String name, String publicKeyHex})> otherParticipants,
    SygnatureWalletTransitionPolicy? migrationPolicy,
    Duration validity = const Duration(days: 7),
  }) async {
    final runtime = _roastRuntime;
    final current = _vault;
    if (runtime == null) {
      throw UnsupportedError(
        'ROAST is available on supported desktop platforms only.',
      );
    }
    if (current == null) {
      throw StateError('Wallet is not initialized.');
    }
    if (validity <= Duration.zero) {
      throw ArgumentError.value(validity, 'validity', 'must be positive');
    }
    final source = _setupById(sourceSetupId);
    if (!source.isActive || source.groupKeyHex == null) {
      throw StateError('Only an active ROAST setup can be transitioned.');
    }
    final sourceAccount = current.accounts.singleWhere(
      (account) => account.sourceId == source.id,
      orElse: () => throw StateError(
        'The source ROAST setup does not have a wallet account.',
      ),
    );
    final network = PeercoinNetworks.fromWalletNetwork(
      _networkById(source.blockchainId, source.networkId),
    );
    final transitionPolicy =
        migrationPolicy ??
        SygnatureWalletTransitionPolicy(
          sourceAccountId: sourceAccount.id,
          blockchainId: source.blockchainId,
          networkId: source.networkId,
          keyId: sourceAccount.keyId ?? source.keyName,
          destinationDerivationPath: thresholdBip86DerivationPath(
            coinType: network.coinType,
            account: 0,
          ),
          maxTotalFeeSats: 0,
          maxFeeRateSatsPerKb: network.network.feePerKb.toInt(),
          minimumConfirmations: 6,
          maxMigrationAttempts: 1,
          sweepLateDeposits: false,
        );
    if (transitionPolicy.sourceAccountId != sourceAccount.id ||
        transitionPolicy.blockchainId != source.blockchainId ||
        transitionPolicy.networkId != source.networkId ||
        transitionPolicy.keyId != sourceAccount.keyId) {
      throw ArgumentError.value(
        transitionPolicy,
        'migrationPolicy',
        'does not match the source wallet account',
      );
    }
    final existingTransition = current.groupTransitions
        .where(
          (transition) =>
              transition.sourceSetupId == source.id &&
              transition.phase != WalletGroupTransitionPhase.failed &&
              transition.phase != WalletGroupTransitionPhase.retired,
        )
        .firstOrNull;
    if (existingTransition != null) {
      throw StateError(
        'This wallet already has an unfinished signer-group change.',
      );
    }
    final participantCount = otherParticipants.length + 1;
    if (successorThreshold < 2 || successorThreshold > participantCount) {
      throw ArgumentError.value(
        successorThreshold,
        'successorThreshold',
        'must be between 2 and the successor participant count',
      );
    }
    final successorName = successorWalletName.trim();
    if (successorName.isEmpty) {
      throw ArgumentError('Successor wallet name cannot be empty.');
    }

    final local = source.localParticipant;
    final participantCards = <String>[];
    for (final candidate in otherParticipants) {
      final publicKeyHex = _roastKeyService.normalizeParticipantPublicKey(
        candidate.publicKeyHex,
      );
      if (publicKeyHex == local.publicKeyHex) {
        throw ArgumentError(
          'The initiating signer is already included in the successor group.',
        );
      }
      final retained = source.participants
          .where((participant) => participant.publicKeyHex == publicKeyHex)
          .firstOrNull;
      participantCards.add(
        retained == null
            ? _roastKeyService.participantCardFromPublicKey(
                name: candidate.name,
                publicKeyHex: publicKeyHex,
              )
            : RoastExchangeCodec.encodeParticipantCard(
                cardId: retained.cardId,
                name: candidate.name.trim().isEmpty
                    ? retained.name
                    : candidate.name.trim(),
                publicKeyHex: retained.publicKeyHex,
              ),
      );
    }

    final successorSetupId = _roastKeyService.newSetupId();
    final successorGroupId = _roastKeyService.newSetupId();
    final transitionId = _roastKeyService.newSetupId();
    var successor = RoastSetup(
      id: successorSetupId,
      groupId: successorGroupId,
      name: successorName,
      role: RoastSetupRole.host,
      status: RoastSetupStatus.connecting,
      threshold: successorThreshold,
      participantCount: participantCount,
      blockchainId: source.blockchainId,
      networkId: source.networkId,
      localCardId: local.cardId,
      localParticipantPrivateKeyHex: source.localParticipantPrivateKeyHex,
      participants: [
        RoastParticipant(
          cardId: local.cardId,
          name: local.name,
          identifierHex: '',
          publicKeyHex: local.publicKeyHex,
        ),
      ],
      onlineParticipantIds: const [],
      keyName: roastKeyName(successorGroupId),
      createdAt: DateTime.now().toUtc(),
      irohIdentityIndex: irohIdentityIndexForSetup(successorSetupId),
      usesRoomEnrollment: true,
    );
    final participants = _roastKeyService.finalizeRoster(
      successor,
      participantCards,
    );
    successor = successor.copyWith(
      participants: participants,
      hostParticipantId: participants
          .singleWhere((participant) => participant.cardId == local.cardId)
          .identifierHex,
    );
    successor = successor.copyWith(
      groupFingerprintHex: _roastKeyService.groupFingerprint(successor),
    );

    RoastSetup? persistedSuccessor;
    WalletGroupTransition? persistedTransition;
    try {
      final room = await runtime.createRoom(
        successor,
        beforeInvitations: (preparedRoom) async {
          final now = DateTime.now().toUtc();
          final expiresAt = now.add(validity);
          final dkgDetails = NewDkgDetails(
            name: successor.keyName,
            description: roastKeyDescription(successor),
            threshold: successor.threshold,
            expiry: Expiry.fromTime(expiresAt),
          );
          final keyPlan = GroupTransitionKeyPlan(
            keyId: transitionPolicy.keyId,
            sourceGroupKey: ECCompressedPublicKey.fromHex(source.groupKeyHex!),
            sourceThreshold: source.threshold,
            targetThreshold: successor.threshold,
            dkgDetailsHash: dkgDetails.sigHash,
          );
          final proposal = GroupTransitionProposal(
            transitionId: transitionId,
            sourceGroup: GroupConfig(
              id: source.groupId,
              participants: {
                for (final participant in source.participants)
                  Identifier.fromHex(participant.identifierHex):
                      ECCompressedPublicKey.fromHex(participant.publicKeyHex),
              },
            ),
            successorRoomId: successor.groupId,
            coordinatorEndpointId: preparedRoom.coordinatorEndpointId,
            successorParticipants: [
              for (final participant in successor.participants)
                ECCompressedPublicKey.fromHex(participant.publicKeyHex),
            ],
            keyPlans: [keyPlan],
            migrationPolicy: transitionPolicy.noospherePolicy,
            createdAt: now,
            expiresAt: expiresAt,
          );
          var transition = WalletGroupTransition.proposed(
            sourceSetupId: source.id,
            successorSetupId: successor.id,
            proposal: proposal,
            dkgDetailsByKey: {transitionPolicy.keyId: dkgDetails},
            now: now,
          );
          transition = transition.withApproval(
            GroupTransitionApproval.forProposal(
              proposal: proposal,
              participantPublicKey: ECCompressedPublicKey.fromHex(
                local.publicKeyHex,
              ),
              approvedAt: now,
            ).sign(ECPrivateKey.fromHex(source.localParticipantPrivateKeyHex)),
            now: now,
          );
          final preparedSuccessor = successor.copyWith(
            coordinatorId: preparedRoom.coordinatorId,
            coordinatorRelayUrls: preparedRoom.coordinatorRelayUrls,
            coordinatorIpAddrs: preparedRoom.coordinatorIpAddrs,
          );
          final successorAccount = WalletAccount(
            id:
                'roast-${successor.id}-'
                '${source.blockchainId}:${source.networkId}-0',
            name: successor.name,
            accountIndex: 0,
            blockchainId: source.blockchainId,
            networkId: source.networkId,
            derivationState: WalletDerivationState.pending,
            keySource: WalletKeySource.roast,
            sourceId: successor.id,
            keyId: successor.keyName,
            createdAt: now,
          );
          final latest = _vault;
          if (latest == null ||
              !latest.roastSetups.any((setup) => setup.id == source.id)) {
            throw StateError('The source ROAST setup is no longer available.');
          }
          final next = latest.copyWith(
            accounts: [...latest.accounts, successorAccount],
            roastSetups: [...latest.roastSetups, preparedSuccessor],
            groupTransitions: [...latest.groupTransitions, transition],
          );
          await _repository.save(next);
          _vault = next;
          _selectedAccountId = successorAccount.id;
          persistedSuccessor = preparedSuccessor;
          persistedTransition = transition;
          _notifyListeners();
        },
      );
      final savedSetup = persistedSuccessor;
      final savedTransition = persistedTransition;
      if (savedSetup == null || savedTransition == null) {
        throw StateError(
          'The transition proposal was not persisted before invitations.',
        );
      }
      final invitations = [
        for (final invite in room.invites)
          RoastIssuedInvitation(
            participantName: savedSetup.participants
                .singleWhere(
                  (participant) =>
                      participant.publicKeyHex ==
                      invite.participantPublicKeyHex,
                )
                .name,
            participantPublicKeyHex: invite.participantPublicKeyHex,
            encoded: RoastExchangeCodec.encodeInvitation(
              savedSetup,
              roomInvite: invite.encoded,
              participantPublicKeyHex: invite.participantPublicKeyHex,
              expiresAt: invite.expiresAt,
              transitionSourceGroupId: source.groupId,
            ),
          ),
      ];
      _issuedRoastInvitations[savedSetup.id] = invitations;
      _notifyListeners();
      return RoastGroupTransitionCreation(
        transitionId: savedTransition.transitionId,
        successorSetupId: savedSetup.id,
        invitations: List.unmodifiable(invitations),
      );
    } catch (error) {
      final savedSetup = persistedSuccessor;
      if (savedSetup != null) {
        await _replaceSetup(
          savedSetup.copyWith(
            status: RoastSetupStatus.error,
            errorMessage: _cleanRoastError(error),
          ),
        );
      }
      rethrow;
    }
  }

  /// Creates a successor draft with the identity already used in [sourceSetupId].
  /// The room invitation still supplies and validates the successor roster.
  Future<String> createRoastTransitionJoinDraft({
    required String sourceSetupId,
    required String walletName,
    required int threshold,
    required int participantCount,
  }) async {
    final current = _vault;
    if (current == null) throw StateError('Wallet is not initialized.');
    final source = _setupById(sourceSetupId);
    if (!source.isActive || source.groupKeyHex == null) {
      throw StateError('The source ROAST wallet is not active.');
    }
    if (threshold < 2 || threshold > participantCount) {
      throw ArgumentError('Invalid successor signing threshold.');
    }
    final setupId = _roastKeyService.newSetupId();
    final local = source.localParticipant;
    final name = walletName.trim().isEmpty
        ? 'Shared wallet'
        : walletName.trim();
    final draftGroupId = _roastKeyService.newSetupId();
    final setup = RoastSetup(
      id: setupId,
      groupId: draftGroupId,
      name: name,
      role: RoastSetupRole.member,
      status: RoastSetupStatus.draft,
      threshold: threshold,
      participantCount: participantCount,
      blockchainId: source.blockchainId,
      networkId: source.networkId,
      localCardId: local.cardId,
      localParticipantPrivateKeyHex: source.localParticipantPrivateKeyHex,
      participants: [
        RoastParticipant(
          cardId: local.cardId,
          name: local.name,
          identifierHex: '',
          publicKeyHex: local.publicKeyHex,
        ),
      ],
      onlineParticipantIds: const [],
      keyName: roastKeyName(draftGroupId),
      createdAt: DateTime.now().toUtc(),
      irohIdentityIndex: irohIdentityIndexForSetup(setupId),
      usesRoomEnrollment: true,
    );
    final account = WalletAccount(
      id: 'roast-$setupId-${source.blockchainId}:${source.networkId}-0',
      name: name,
      accountIndex: 0,
      blockchainId: source.blockchainId,
      networkId: source.networkId,
      derivationState: WalletDerivationState.pending,
      keySource: WalletKeySource.roast,
      sourceId: setupId,
      keyId: setup.keyName,
      createdAt: DateTime.now().toUtc(),
    );
    final next = current.copyWith(
      accounts: [...current.accounts, account],
      roastSetups: [...current.roastSetups, setup],
    );
    await _repository.save(next);
    _vault = next;
    _selectedAccountId = account.id;
    _notifyListeners();
    return setupId;
  }

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
      derivationState: WalletDerivationState.pending,
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
      if (snapshot.connected && snapshot.signerRunning) {
        _roastCoordinatorRecovery.remove(setup.id);
      }
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
        _sameStrings(setup.coordinatorRelayUrls, newCoordinator.relayUrls) &&
        _sameStrings(setup.coordinatorIpAddrs, newCoordinator.ipAddrs);
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
    if (!setup.isFinalized || _roastOperations.contains(setupId)) return;
    await _startRoastRuntime(
      setup.copyWith(status: RoastSetupStatus.connecting),
    );
  }

  Future<void> _persistCoordinatorSelection(
    String setupId,
    RoastCoordinatorAddress address,
  ) async {
    final current = _vault;
    if (current == null) throw StateError('Wallet is not initialized.');
    final existing = _setupById(setupId);
    if (existing.coordinatorId == address.id &&
        _sameStrings(existing.coordinatorRelayUrls, address.relayUrls) &&
        _sameStrings(existing.coordinatorIpAddrs, address.ipAddrs)) {
      return;
    }
    final replacement = existing.copyWith(
      coordinatorId: address.id,
      coordinatorRelayUrls: List.unmodifiable(address.relayUrls),
      coordinatorIpAddrs: List.unmodifiable(address.ipAddrs),
    );
    final next = current.copyWith(
      roastSetups: [
        for (final setup in current.roastSetups)
          if (setup.id == setupId) replacement else setup,
      ],
    );
    await _repository.save(next);
    _vault = next;
    _notifyListeners();
  }

  Future<void> _recoverCoordinatorPersistence(
    String setupId,
    RoastRuntime runtime,
    RoastCoordinatorSwitchFailure failure,
  ) async {
    try {
      final stored = await _repository.load();
      if (stored == null) throw StateError('The wallet vault is missing.');
      final selected = stored.roastSetups.singleWhere(
        (setup) => setup.id == setupId,
      );
      _vault = stored;
      _notifyListeners();
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
    await _replaceSetup(
      setup.copyWith(
        status: RoastSetupStatus.interrupted,
        errorMessage: _coordinatorSwitchError(failure),
      ),
    );
  }

  Future<void> _applyCoordinatorSnapshot(
    String setupId,
    RoastRuntimeSnapshot snapshot,
  ) async {
    _roastPresence[setupId] = _RoastPresence(
      connected: snapshot.connected,
      signerRunning: snapshot.signerRunning,
    );
    final setup = _setupById(setupId);
    await _replaceSetup(
      setup.copyWith(
        status: snapshot.connected
            ? setup.groupKeyHex == null
                  ? RoastSetupStatus.ready
                  : RoastSetupStatus.active
            : RoastSetupStatus.interrupted,
        onlineParticipantIds: snapshot.onlineParticipantIds,
        coordinatorId: snapshot.coordinatorId,
        coordinatorRelayUrls: snapshot.coordinatorRelayUrls,
        coordinatorIpAddrs: snapshot.coordinatorIpAddrs,
        clearError: snapshot.connected,
      ),
    );
  }

  static bool _sameStrings(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
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
      await _replaceSetup(
        dkgSetup.copyWith(
          status: RoastSetupStatus.creatingKey,
          clearError: true,
        ),
      );
      if (transition != null) {
        await _replaceGroupTransition(
          transition.copyWith(
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
          await _replaceGroupTransition(
            transition.copyWith(
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
      if (snapshot.connected && snapshot.signerRunning) {
        _roastCoordinatorRecovery.remove(setup.id);
      }
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
        await _markTransitionReadyForSetup(setup.id);
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

  Future<void> _replaceGroupTransition(
    WalletGroupTransition replacement,
  ) async {
    final current = _vault;
    if (current == null) return;
    final next = current.copyWith(
      groupTransitions: [
        for (final transition in current.groupTransitions)
          if (transition.transitionId == replacement.transitionId)
            replacement
          else
            transition,
      ],
    );
    await _repository.save(next);
    _vault = next;
    _notifyListeners();
  }

  Future<void> _markTransitionReadyForSetup(String setupId) async {
    final transition = groupTransitions
        .where((item) => item.successorSetupId == setupId)
        .firstOrNull;
    if (transition == null ||
        transition.phase == WalletGroupTransitionPhase.ready) {
      return;
    }
    await _replaceGroupTransition(
      transition.copyWith(
        phase: WalletGroupTransitionPhase.ready,
        clearError: true,
      ),
    );
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
              derivationState: WalletDerivationState.ready,
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
    RoastEnrollmentFailure(
      kind: RoastEnrollmentFailureKind.rejected,
      :final roomFailureCode,
    ) =>
      roomFailureCode == 0xffff
          ? 'The coordinator rejected room enrollment.'
          : 'The coordinator rejected room enrollment '
                '(room code $roomFailureCode).',
    RoastEnrollmentFailure(kind: RoastEnrollmentFailureKind.timeout) =>
      'Room enrollment timed out. Check coordinator state before retrying.',
    RoastEnrollmentFailure(
      kind: RoastEnrollmentFailureKind.malformedResponse,
    ) =>
      'The coordinator returned an invalid enrollment response. Check '
          'coordinator state before retrying.',
    RoastEnrollmentFailure(kind: RoastEnrollmentFailureKind.connection) =>
      'The enrollment connection was interrupted. Check coordinator state '
          'before retrying.',
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
