part of 'wallet_controller.dart';

extension WalletGroupTransitionController on WalletController {
  List<WalletGroupTransition> get groupTransitions =>
      _vault?.groupTransitions ?? const [];

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
        'ROAST is unavailable in this application session.',
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
      keyName: roastKeyName(successorGroupId),
      createdAt: DateTime.now().toUtc(),
      irohIdentityIndex: irohIdentityIndexForSetup(successorSetupId),
      usesRoomEnrollment: true,
    );
    successor = _finalizeRoastRoster(successor, participantCards);

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
            groupFingerprint: hexToBytes(successor.groupFingerprintHex!),
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
          final successorAccount = _pendingRoastAccount(
            preparedSuccessor,
            createdAt: now,
          );
          await _updateVault((latest) {
            if (latest == null ||
                !latest.roastSetups.any((setup) => setup.id == source.id)) {
              throw StateError(
                'The source ROAST setup is no longer available.',
              );
            }
            return latest.copyWith(
              accounts: [...latest.accounts, successorAccount],
              roastSetups: [...latest.roastSetups, preparedSuccessor],
              groupTransitions: [...latest.groupTransitions, transition],
              selectedAccountId: successorAccount.id,
            );
          }, updateSelection: true);
          persistedSuccessor = preparedSuccessor;
          persistedTransition = transition;
        },
      );
      final savedSetup = persistedSuccessor;
      final savedTransition = persistedTransition;
      if (savedSetup == null || savedTransition == null) {
        throw StateError(
          'The transition proposal was not persisted before invitations.',
        );
      }
      final invitations = _roomInvitations(savedSetup, room);
      await _updateSetup(
        savedSetup.id,
        (savedSetup) => savedSetup.copyWith(invitations: invitations),
      );
      return RoastGroupTransitionCreation(
        transitionId: savedTransition.transitionId,
        successorSetupId: savedSetup.id,
        invitations: List.unmodifiable(invitations),
      );
    } catch (error) {
      final savedSetup = persistedSuccessor;
      if (savedSetup != null) {
        await _updateSetup(
          savedSetup.id,
          (savedSetup) => savedSetup.copyWith(
            status: RoastSetupStatus.error,
            errorMessage: WalletRoastSetupController._cleanRoastError(error),
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
    if (participantCount < 2 || participantCount > 0xffff) {
      throw ArgumentError('Invalid successor participant count.');
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
      keyName: roastKeyName(draftGroupId),
      createdAt: DateTime.now().toUtc(),
      irohIdentityIndex: irohIdentityIndexForSetup(setupId),
      usesRoomEnrollment: true,
    );
    final account = _pendingRoastAccount(setup);
    await _updateVault((current) {
      if (current == null) throw StateError('Wallet is not initialized.');
      return current.copyWith(
        accounts: [...current.accounts, account],
        roastSetups: [...current.roastSetups, setup],
        selectedAccountId: account.id,
      );
    }, updateSelection: true);
    return setupId;
  }

  Future<void> _updateGroupTransition(
    String transitionId,
    WalletGroupTransition Function(WalletGroupTransition transition) update,
  ) => _updateVault((current) {
    if (current == null) return current;
    return current.copyWith(
      groupTransitions: [
        for (final transition in current.groupTransitions)
          if (transition.transitionId == transitionId)
            update(transition)
          else
            transition,
      ],
    );
  });

  Future<void> _markTransitionReadyForSetup(String setupId) async {
    final transition = groupTransitions
        .where((item) => item.successorSetupId == setupId)
        .firstOrNull;
    if (transition == null ||
        transition.phase == WalletGroupTransitionPhase.ready) {
      return;
    }
    await _updateGroupTransition(
      transition.transitionId,
      (transition) => transition.copyWith(
        phase: WalletGroupTransitionPhase.ready,
        clearError: true,
      ),
    );
  }
}
