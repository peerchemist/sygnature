import 'dart:async';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart'
    show
        Expiry,
        GroupTransitionKeyPlan,
        HDKeyInfo,
        Identifier,
        MessageSignatureMetadata,
        NewDkgDetails,
        NoosphereFlutter,
        SignaturesRequestDetails;
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/models/electrumx_utxo.dart';
import 'package:sygnature_ng/models/group_transition.dart';
import 'package:sygnature_ng/models/roast_setup.dart';
import 'package:sygnature_ng/models/roast_signing_operation.dart';
import 'package:sygnature_ng/models/wallet_account.dart';
import 'package:sygnature_ng/models/wallet_activity.dart';
import 'package:sygnature_ng/models/wallet_transaction.dart';
import 'package:sygnature_ng/models/wallet_vault.dart';
import 'package:sygnature_ng/services/electrumx_service.dart';
import 'package:sygnature_ng/services/peercoin_network_service.dart';
import 'package:sygnature_ng/services/roast_key_service.dart';
import 'package:sygnature_ng/services/roast_runtime_manager.dart';
import 'package:sygnature_ng/services/wallet_transaction_service.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';

void main() {
  setUpAll(() async {
    await loadCoinlib();
    await NoosphereFlutter.initializeNative();
  });

  test(
    'preserves overlapping invitation delivery and enrollment updates',
    () async {
      final repository = _CoordinatorRepository();
      final runtime = _CoordinatorRoastRuntime();
      final controller = _coordinatorController(repository, runtime);
      final setup = repository.value!.roastSetups.single;
      final publicKey = setup.participants.last.publicKeyHex;
      repository.value = repository.value!.copyWith(
        roastSetups: [
          setup.copyWith(
            invitations: [
              RoastIssuedInvitation(
                participantName: 'Member',
                participantPublicKeyHex: publicKey,
                encoded: 'invite',
                issuedAt: DateTime.now(),
                expiresAt: DateTime.now().add(const Duration(days: 1)),
              ),
            ],
          ),
        ],
      );
      await controller.load();
      await _flushEvents();
      repository.saveStarted = Completer<void>();
      repository.saveGate = Completer<void>();
      final copied = controller.markRoastInvitationCopied(setup.id, publicKey);
      await repository.saveStarted!.future;
      final sent = controller.markRoastInvitationSent(setup.id, publicKey);
      final enrolledAt = DateTime.now();
      runtime.emit(
        RoastRuntimeEnrollmentEvent(
          setup.id,
          invitations: [],
          participants: [
            RoastRuntimeParticipantEnrollment(
              participantPublicKeyHex: publicKey,
              enrolledAt: enrolledAt,
            ),
          ],
        ),
      );
      await _flushEvents();
      repository.saveGate!.complete();
      await Future.wait([copied, sent]);
      await _flushEvents();

      final invitation =
          repository.value!.roastSetups.single.invitations.single;
      expect(invitation.copiedAt, isNotNull);
      expect(invitation.sentAt, isNotNull);
      expect(invitation.joinedAt, enrolledAt);
      final saves = repository.saveCount;
      var notifications = 0;
      controller.addListener(() => notifications++);
      runtime.emit(
        RoastRuntimeEnrollmentEvent(
          setup.id,
          invitations: [],
          participants: [
            RoastRuntimeParticipantEnrollment(
              participantPublicKeyHex: publicKey,
              enrolledAt: enrolledAt,
            ),
          ],
        ),
      );
      await _flushEvents();
      expect(repository.saveCount, saves);
      expect(notifications, 0);
      controller.dispose();
    },
  );

  test('skips unchanged snapshots while publishing presence changes', () async {
    final repository = _CoordinatorRepository();
    final runtime = _CoordinatorRoastRuntime();
    final controller = _coordinatorController(repository, runtime);
    await controller.load();
    await _flushEvents();
    final setup = controller.roastSetups.single;
    RoastRuntimeSnapshotEvent snapshot({
      bool connected = true,
      List<String>? online,
    }) => RoastRuntimeSnapshotEvent(
      setup.id,
      connected: connected,
      signerRunning: connected,
      onlineParticipantIds:
          online ?? List.of(controller.onlineRoastParticipantIds(setup.id)),
      coordinatorId: setup.coordinatorId,
      coordinatorRelayUrls: List.of(setup.coordinatorRelayUrls),
      coordinatorIpAddrs: List.of(setup.coordinatorIpAddrs),
    );
    final saves = repository.saveCount;
    var notifications = 0;
    controller.addListener(() => notifications++);
    runtime.emit(snapshot());
    runtime.emit(snapshot());
    await _flushEvents();
    expect(repository.saveCount, saves);
    expect(notifications, 0);

    runtime.emit(snapshot(connected: false));
    await _flushEvents();
    expect(repository.saveCount, saves);
    expect(notifications, 1);
    expect(
      controller.roastCoordinatorState(setup.id),
      RoastCoordinatorLocalState.stopped,
    );

    runtime.emit(snapshot(online: const ['01']));
    await _flushEvents();
    expect(repository.saveCount, saves);
    expect(controller.onlineRoastParticipantIds(setup.id), ['01']);
    expect(notifications, 2);
    controller.dispose();
  });

  test('keeps presence out of saved and restored setup state', () async {
    final repository = _CoordinatorRepository();
    final runtime = _CoordinatorRoastRuntime();
    final controller = _coordinatorController(repository, runtime);
    await controller.load();
    await _flushEvents();
    final setup = controller.roastSetups.single;
    final saves = repository.saveCount;
    runtime.emit(
      RoastRuntimeSnapshotEvent(
        setup.id,
        connected: true,
        signerRunning: true,
        onlineParticipantIds: const ['02'],
        coordinatorId: setup.coordinatorId,
        coordinatorRelayUrls: setup.coordinatorRelayUrls,
        coordinatorIpAddrs: setup.coordinatorIpAddrs,
      ),
    );
    await _flushEvents();
    expect(repository.saveCount, saves);
    expect(controller.onlineSignerCount(setup), 2);
    expect(controller.roastSetups.single, same(setup));
    await controller.renameAccount('shared', 'Renamed');
    final json = repository.value!.roastSetups.single.toJson();
    expect(json.containsKey('onlineParticipantIds'), isFalse);
    final legacy = RoastSetup.fromJson({
      ...json,
      'onlineParticipantIds': ['stale'],
    });
    expect(legacy.toJson().containsKey('onlineParticipantIds'), isFalse);
    controller.dispose();

    final restored = WalletController(repository);
    await restored.load();
    expect(restored.onlineSignerCount(restored.roastSetups.single), 0);
    expect(restored.onlineRoastParticipantIds(setup.id), isEmpty);
    restored.dispose();
  });

  test(
    'persists coordinator address changes without saving presence',
    () async {
      final repository = _CoordinatorRepository();
      final runtime = _CoordinatorRoastRuntime();
      final controller = _coordinatorController(repository, runtime);
      await controller.load();
      await _flushEvents();
      final setup = controller.roastSetups.single;
      final saves = repository.saveCount;
      runtime.emit(
        RoastRuntimeSnapshotEvent(
          setup.id,
          connected: true,
          signerRunning: true,
          onlineParticipantIds: const ['02'],
          coordinatorId: setup.coordinatorId,
          coordinatorRelayUrls: const ['https://relay.example.com'],
          coordinatorIpAddrs: const ['127.0.0.1:1234'],
        ),
      );
      await _flushEvents();
      expect(repository.saveCount, saves + 1);
      final stored = repository.value!.roastSetups.single;
      expect(stored.coordinatorRelayUrls, ['https://relay.example.com']);
      expect(stored.coordinatorIpAddrs, ['127.0.0.1:1234']);
      expect(stored.toJson().containsKey('onlineParticipantIds'), isFalse);
      controller.dispose();
    },
  );

  test('skips repeated DKG progress saves and notifications', () async {
    final repository = _CoordinatorRepository();
    final runtime = _CoordinatorRoastRuntime();
    final controller = _coordinatorController(repository, runtime);
    await controller.load();
    await _flushEvents();
    final setup = controller.roastSetups.single;
    final expiry = DateTime.now().add(const Duration(hours: 1));
    RoastRuntimeDkgEvent progress() => RoastRuntimeDkgEvent(
      setup.id,
      proposalHex: 'proposal',
      name: setup.keyName,
      threshold: setup.threshold,
      creator: setup.hostParticipantId!,
      expiry: expiry,
      description: roastKeyDescription(setup),
      stage: 'sharing',
      rejected: false,
      completedParticipantIds: List.of(['01']),
    );
    runtime.emit(progress());
    await _flushEvents();
    final saves = repository.saveCount;
    var notifications = 0;
    controller.addListener(() => notifications++);
    runtime.emit(progress());
    await _flushEvents();
    expect(repository.saveCount, saves);
    expect(notifications, 0);
    expect(controller.roastSetups.single.pendingDkgCompletedParticipantIds, [
      '01',
    ]);
    controller.dispose();
  });

  test('surfaces unexpected signing request validation errors', () async {
    final runtime = _FakeRoastRuntime()..snapshotGroupKey = 'expected-key';
    final keyService = _FakeRoastKeyService();
    final controller = _controller(
      runtime: runtime,
      keyService: keyService,
      active: true,
    );
    await controller.load();
    await _flushEvents();
    keyService.failNextDerivation = true;
    runtime.emit(
      RoastRuntimeSigningRequestEvent(
        'setup',
        request: _signingRequest('ab' * 16),
      ),
    );
    await _flushEvents();

    expect(controller.roastSigningRequests, isEmpty);
    expect(controller.roastSetups.single.status, RoastSetupStatus.error);
    expect(
      controller.roastSetups.single.errorMessage,
      contains('injected derivation failure'),
    );
    controller.dispose();
  });

  test('uses the threshold BIP-86 hierarchy for new ROAST accounts', () {
    final service = const RoastKeyService();
    final mainnet = service.deriveAddress(
      groupKeyHex: ECPrivateKey.fromHex('${'0' * 63}1').pubkey.hex,
      threshold: 2,
      network: PeercoinNetworks.mainnet,
      accountIndex: 2,
    );
    final testnet = service.deriveAddress(
      groupKeyHex: ECPrivateKey.fromHex('${'0' * 63}1').pubkey.hex,
      threshold: 2,
      network: PeercoinNetworks.testnet,
      accountIndex: 2,
    );

    expect(mainnet.path, [86, 6, 2, 0, 0]);
    expect(mainnet.pathLabel, 'R/86/6/2/0/0');
    expect(testnet.path, [86, 1, 2, 0, 0]);
    expect(testnet.pathLabel, 'R/86/1/2/0/0');

    final legacy = service.deriveAddress(
      groupKeyHex: ECPrivateKey.fromHex('${'0' * 63}1').pubkey.hex,
      threshold: 2,
      network: PeercoinNetworks.mainnet,
      accountIndex: 2,
      pathLabel: 'R/0/6/0/2/0/0',
    );
    expect(legacy.path, [0, 6, 0, 2, 0, 0]);
    expect(legacy.pathLabel, 'R/0/6/0/2/0/0');
  });

  test(
    'uses the wallet name for setup and keeps later renames local',
    () async {
      final repository = MemoryWalletRepository();
      final controller = WalletController(
        repository,
        roastRuntime: _FakeRoastRuntime(),
      );
      await controller.load();

      await controller.createRoastSetupDraft(
        role: RoastSetupRole.host,
        walletName: 'Family treasury',
        participantName: 'This device',
        threshold: 2,
        participantCount: 2,
        network: PeercoinNetworks.mainnet,
      );

      final account = controller.accounts.single;
      final setup = controller.roastSetups.single;
      expect(account.name, 'Family treasury');
      expect(setup.name, 'Family treasury');
      expect(setup.keyName, roastKeyName(setup.groupId));
      expect(setup.keyName.length, lessThanOrEqualTo(maxRoastKeyNameLength));
      expect(roastDkgAttemptTtl, const Duration(hours: 1));
      expect(
        () => NewDkgDetails(
          name: setup.keyName,
          description: 'ROAST wallet',
          threshold: setup.threshold,
          expiry: Expiry(roastDkgAttemptTtl),
        ),
        returnsNormally,
      );

      await controller.renameAccount(account.id, 'My local wallet');

      expect(controller.accounts.single.name, 'My local wallet');
      expect(controller.roastSetups.single.name, 'Family treasury');
      controller.dispose();
    },
  );

  test('creates serialized transaction and message proposals', () async {
    final signingKey = ECPrivateKey.fromHex('${'0' * 63}1');
    final destinationKey = ECPrivateKey.fromHex('${'0' * 63}2');
    final sourceAddress = const RoastKeyService()
        .deriveAddress(
          groupKeyHex: signingKey.pubkey.hex,
          threshold: 2,
          network: PeercoinNetworks.mainnet,
          accountIndex: 0,
        )
        .address;
    final destinationAddress = P2TRAddress.fromTweakedKey(
      destinationKey.pubkey,
      hrp: Network.mainnet.bech32Hrp,
    ).toString();
    final preview = const CoinlibWalletTransactionService().prepare(
      accountId: 'shared',
      network: PeercoinNetworks.mainnet,
      sourceAddress: sourceAddress,
      availableUtxos: [
        ElectrumxUtxo(
          address: sourceAddress,
          txHash: 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
          txPos: 0,
          height: 100,
          value: 2000000,
        ),
      ],
      request: WalletSendRequest(
        destinationAddress: destinationAddress,
        amountSats: 1000000,
        feeRateSatsPerKb: 10000,
      ),
    );
    final transaction = const CoinlibWalletTransactionService()
        .prepareThresholdSigning(
          network: PeercoinNetworks.mainnet,
          preview: preview,
        );
    final runtime = RoastRuntimeManager(
      RoastPersistenceFactory(),
      getWalletBip39Seed: () => Uint8List(64),
    );
    addTearDown(runtime.close);

    final proposal = runtime.createTransactionSigningProposal(
      _setup(
        RoastSetupRole.host,
        active: true,
      ).copyWith(groupKeyHex: signingKey.pubkey.hex),
      transaction,
      const [0, 6, 0, 0, 0, 0],
      message: 'Quarterly hosting bill',
    );
    final persisted = SignaturesRequestDetails.fromHex(proposal.proposalHex);

    expect(proposal.expiry, persisted.expiry.time);
    expect(
      proposal.expiry.difference(DateTime.now()),
      greaterThan(const Duration(minutes: 29)),
    );
    expect(proposal.expiry.microsecond % 1000, 0);
    expect(proposal.idHex, bytesToHex(persisted.id.toBytes()));
    expect(persisted.message, 'Quarterly hosting bill');

    final proposalWithoutMessage = runtime.createTransactionSigningProposal(
      _setup(
        RoastSetupRole.host,
        active: true,
      ).copyWith(groupKeyHex: signingKey.pubkey.hex),
      transaction,
      const [0, 6, 0, 0, 0, 0],
    );
    expect(
      SignaturesRequestDetails.fromHex(proposalWithoutMessage.proposalHex)
          .message,
      isEmpty,
    );
    expect(
      () => runtime.createTransactionSigningProposal(
        _setup(
          RoastSetupRole.host,
          active: true,
        ).copyWith(groupKeyHex: signingKey.pubkey.hex),
        transaction,
        const [0, 6, 0, 0, 0, 0],
        message: 'è' * (maxRoastSigningMessageBytes ~/ 2 + 1),
      ),
      throwsArgumentError,
    );

    final messageProposal = runtime.createMessageSigningProposal(
      _setup(
        RoastSetupRole.host,
        active: true,
      ).copyWith(groupKeyHex: signingKey.pubkey.hex),
      'Exact message\nwith preserved whitespace ',
      message: 'Please verify the release note.',
      timeout: maxRoastSigningRequestTimeout,
    );
    final messageDetails = SignaturesRequestDetails.fromHex(
      messageProposal.proposalHex,
    );
    final messageMetadata = messageDetails.metadata as MessageSignatureMetadata;
    expect(messageProposal.expiry, messageDetails.expiry.time);
    expect(
      messageProposal.expiry.difference(DateTime.now()),
      greaterThan(const Duration(hours: 23, minutes: 59)),
    );
    expect(messageProposal.idHex, bytesToHex(messageDetails.id.toBytes()));
    expect(
      messageMetadata.payload.text,
      'Exact message\nwith preserved whitespace ',
    );
    expect(messageDetails.message, 'Please verify the release note.');
    expect(messageDetails.requiredSigs.single.groupKey, signingKey.pubkey);
    expect(messageDetails.requiredSigs.single.hdDerivation, isEmpty);
    expect(messageDetails.requiredSigs.single.signDetails.mastHash, isNull);
    expect(
      () => runtime.createMessageSigningProposal(
        _setup(
          RoastSetupRole.host,
          active: true,
        ).copyWith(groupKeyHex: signingKey.pubkey.hex),
        'Too long-lived',
        timeout: maxRoastSigningRequestTimeout + const Duration(minutes: 1),
      ),
      throwsArgumentError,
    );
  });

  test('creates a separate room invite bound to each remote signer', () async {
    final participants = [
      RoastParticipant(
        cardId: 'member-card',
        name: 'Member',
        identifierHex: '01',
        publicKeyHex: '02${'11' * 32}',
      ),
      RoastParticipant(
        cardId: 'host-card',
        name: 'Host',
        identifierHex: '02',
        publicKeyHex: '03${'22' * 32}',
      ),
    ];
    final runtime = _FakeRoastRuntime()
      ..roomCreation = RoastRoomCreation(
        invites: [
          RoastRoomInvite(
            participantPublicKeyHex: participants.first.publicKeyHex,
            encoded: 'noosphere-bound-invite',
            expiresAt: DateTime.now().add(const Duration(days: 1)),
          ),
        ],
        coordinatorEndpointId: Uint8List(32),
        coordinatorId: 'coordinator',
        coordinatorRelayUrls: const [],
        coordinatorIpAddrs: const [],
      );
    final repository = MemoryWalletRepository()
      ..value = WalletVault(
        accounts: [
          WalletAccount(
            id: 'shared',
            name: 'Shared wallet',
            accountIndex: 0,
            blockchainId: 'peercoin',
            networkId: 'mainnet',
            derivationState: WalletDerivationState.pending,
            keySource: WalletKeySource.roast,
            sourceId: 'setup',
            keyId: 'group:generation:1',
            createdAt: DateTime.utc(2026),
          ),
        ],
        nextAccountIndex: 0,
        roastSetups: [
          RoastSetup(
            id: 'setup',
            groupId: 'group',
            name: 'Family',
            role: RoastSetupRole.host,
            status: RoastSetupStatus.draft,
            threshold: 2,
            participantCount: 2,
            blockchainId: 'peercoin',
            networkId: 'mainnet',
            localCardId: 'host-card',
            localParticipantPrivateKeyHex: '11' * 32,
            participants: [participants.last],
            keyName: 'group:generation:1',
            createdAt: DateTime.utc(2026),
            usesRoomEnrollment: true,
          ),
        ],
      );
    final controller = WalletController(
      repository,
      roastRuntime: runtime,
      roastKeyService: _RoomRoastKeyService(participants),
    );
    await controller.load();

    final invitations = await controller.createHostedRoastInvitations('setup', [
      (name: 'Member', publicKeyHex: participants.first.publicKeyHex),
    ]);

    expect(invitations, hasLength(1));
    expect(invitations.single.participantName, 'Member');
    final payload = RoastExchangeCodec.decodeInvitation(
      invitations.single.encoded,
    );
    expect(payload['roomInvite'], 'noosphere-bound-invite');
    expect(payload['participantPublicKeyHex'], participants.first.publicKeyHex);
    expect(runtime.createdRoomSetup?.hostParticipantId, '02');
    expect(controller.issuedRoastInvitations('setup'), invitations);
    expect(repository.value!.roastSetups.single.invitations, invitations);

    await controller.markRoastInvitationCopied(
      'setup',
      participants.first.publicKeyHex,
    );
    expect(
      controller
          .issuedRoastInvitations('setup')
          .single
          .statusAt(DateTime.now().toUtc()),
      RoastInvitationDisplayStatus.copied,
    );
    await controller.markRoastInvitationSent(
      'setup',
      participants.first.publicKeyHex,
    );
    expect(
      repository.value!.roastSetups.single.invitations.single.statusAt(
        DateTime.now().toUtc(),
      ),
      RoastInvitationDisplayStatus.sent,
    );

    final joinedAt = DateTime.utc(2026, 2);
    runtime.emit(
      RoastRuntimeEnrollmentEvent(
        'setup',
        invitations: [
          RoastRuntimeInvitationEnrollment(
            participantPublicKeyHex: participants.first.publicKeyHex,
            status: RoastInvitationServerStatus.used,
            usedAt: joinedAt,
          ),
        ],
        participants: [
          RoastRuntimeParticipantEnrollment(
            participantPublicKeyHex: participants.first.publicKeyHex,
            enrolledAt: joinedAt,
          ),
        ],
      ),
    );
    await _flushEvents();

    final joinedInvitation = controller.issuedRoastInvitations('setup').single;
    expect(joinedInvitation.joinedAt, joinedAt);
    expect(
      joinedInvitation.statusAt(DateTime.now().toUtc()),
      RoastInvitationDisplayStatus.joined,
    );
    expect(
      controller.enrolledRoastParticipantCount(controller.roastSetups.single),
      2,
    );
    controller.dispose();
  });

  test(
    'any signer can persist a transition before successor invites are issued',
    () async {
      final localKey = ECPrivateKey.generate();
      final localPublicKey = ECCompressedPublicKey.fromPubkey(localKey.pubkey);
      final remotePublicKey = ECCompressedPublicKey.fromPubkey(
        ECPrivateKey.generate().pubkey,
      );
      final sourceGroupKey = ECCompressedPublicKey.fromPubkey(
        ECPrivateKey.generate().pubkey,
      );
      final remoteIdentifier = Identifier.fromUint16(1).toString();
      final localIdentifier = Identifier.fromUint16(2).toString();
      final coordinatorEndpointId = Uint8List.fromList(
        List<int>.generate(32, (index) => index + 1),
      );
      final sourceSetup = RoastSetup(
        id: 'source-setup',
        groupId: 'source-group',
        name: 'Current treasury',
        role: RoastSetupRole.member,
        status: RoastSetupStatus.active,
        threshold: 2,
        participantCount: 2,
        blockchainId: 'peercoin',
        networkId: 'mainnet',
        localCardId: 'local-card',
        localParticipantPrivateKeyHex: bytesToHex(localKey.data),
        participants: [
          RoastParticipant(
            cardId: 'remote-card',
            name: 'Original host',
            identifierHex: remoteIdentifier,
            publicKeyHex: remotePublicKey.hex,
          ),
          RoastParticipant(
            cardId: 'local-card',
            name: 'This signer',
            identifierHex: localIdentifier,
            publicKeyHex: localPublicKey.hex,
          ),
        ],
        keyName: 'source-key',
        createdAt: DateTime.utc(2026),
        usesRoomEnrollment: true,
        hostParticipantId: remoteIdentifier,
        coordinatorId: 'old-coordinator',
        groupFingerprintHex: 'old-fingerprint',
        groupKeyHex: sourceGroupKey.hex,
      );
      final repository = MemoryWalletRepository()
        ..value = WalletVault(
          accounts: [
            WalletAccount(
              id: 'shared',
              name: 'Current treasury',
              accountIndex: 0,
              blockchainId: 'peercoin',
              networkId: 'mainnet',
              derivationState: WalletDerivationState.ready,
              keySource: WalletKeySource.roast,
              sourceId: sourceSetup.id,
              keyId: sourceSetup.keyName,
              derivationPath: 'R/0/6/0/0/0/0',
              address: 'pc1pshared',
              createdAt: DateTime.utc(2026),
            ),
          ],
          nextAccountIndex: 0,
          roastSetups: [sourceSetup],
        );
      final runtime = _FakeRoastRuntime()
        ..snapshotGroupKey = sourceGroupKey.hex
        ..roomCreation = RoastRoomCreation(
          invites: [
            RoastRoomInvite(
              participantPublicKeyHex: remotePublicKey.hex,
              encoded: 'successor-room-invite',
              expiresAt: DateTime.now().add(const Duration(days: 1)),
            ),
          ],
          coordinatorEndpointId: coordinatorEndpointId,
          coordinatorId: 'new-coordinator',
          coordinatorRelayUrls: const ['https://relay.example'],
          coordinatorIpAddrs: const ['127.0.0.1:443'],
        );
      var proposalWasPersistedBeforeInvitations = false;
      runtime.afterRoomPrepared = () {
        final vault = repository.value!;
        proposalWasPersistedBeforeInvitations =
            vault.groupTransitions.length == 1 &&
            vault.roastSetups.length == 2 &&
            vault.accounts.length == 2;
      };
      final controller = WalletController(repository, roastRuntime: runtime);
      await controller.load();
      await _flushEvents();

      final created = await controller.proposeRoastGroupTransition(
        sourceSetupId: sourceSetup.id,
        successorWalletName: 'Next treasury',
        successorThreshold: 2,
        otherParticipants: [
          (name: 'Original host', publicKeyHex: remotePublicKey.hex),
        ],
      );

      expect(proposalWasPersistedBeforeInvitations, isTrue);
      expect(created.invitations, hasLength(1));
      expect(
        RoastExchangeCodec.decodeInvitation(
          created.invitations.single.encoded,
        )['transitionSourceGroupId'],
        sourceSetup.groupId,
      );
      final successor = controller.roastSetups.singleWhere(
        (setup) => setup.id == created.successorSetupId,
      );
      expect(successor.role, RoastSetupRole.host);
      expect(successor.localCardId, sourceSetup.localCardId);
      expect(
        successor.localParticipantPrivateKeyHex,
        sourceSetup.localParticipantPrivateKeyHex,
      );
      expect(
        successor.participants.map((participant) => participant.cardId),
        containsAll(['local-card', 'remote-card']),
      );
      final transition = controller.groupTransitions.single;
      expect(transition.transitionId, created.transitionId);
      expect(transition.sourceSetupId, sourceSetup.id);
      expect(transition.successorSetupId, successor.id);
      expect(transition.proposal.coordinatorEndpointId, coordinatorEndpointId);
      expect(
        transition.signedApprovalsHexByParticipant,
        contains(localPublicKey.hex),
      );
      final policy = SygnatureWalletTransitionPolicy.fromBytes(
        transition.proposal.migrationPolicy.payload,
      );
      expect(policy.maxTotalFeeSats, 0);
      expect(policy.destinationDerivationPath, [86, 6, 0, 0, 0]);
      expect(runtime.createdRoomSetup?.localCardId, sourceSetup.localCardId);

      runtime.emit(
        RoastRuntimeSnapshotEvent(
          successor.id,
          connected: true,
          signerRunning: true,
          onlineParticipantIds: successor.participants
              .map((participant) => participant.identifierHex)
              .toList(),
          coordinatorId: successor.coordinatorId,
          coordinatorRelayUrls: successor.coordinatorRelayUrls,
          coordinatorIpAddrs: successor.coordinatorIpAddrs,
        ),
      );
      await _flushEvents();
      await controller.startRoastDkg(successor.id);

      expect(runtime.requestedDkgSetupIds, contains(successor.id));
      expect(runtime.lastApprovedDkgDetails?.name, successor.keyName);
      expect(runtime.lastTransitionKeyPlan?.keyId, sourceSetup.keyName);
      expect(
        controller.groupTransitions.single.phase,
        WalletGroupTransitionPhase.preparing,
      );

      runtime.emit(
        RoastRuntimeKeyEvent(
          successor.id,
          groupKeyHex: ECCompressedPublicKey.fromPubkey(
            ECPrivateKey.generate().pubkey,
          ).hex,
          keyName: successor.keyName,
          description: roastKeyDescription(successor),
        ),
      );
      await _flushEvents();
      expect(
        controller.groupTransitions.single.phase,
        WalletGroupTransitionPhase.ready,
      );

      final retainedDraftId = await controller.createRoastTransitionJoinDraft(
        sourceSetupId: sourceSetup.id,
        walletName: 'Next treasury',
        threshold: 2,
        participantCount: 2,
      );
      final retainedDraft = controller.roastSetups.singleWhere(
        (setup) => setup.id == retainedDraftId,
      );
      expect(retainedDraft.role, RoastSetupRole.member);
      expect(retainedDraft.localCardId, sourceSetup.localCardId);
      expect(
        retainedDraft.localParticipantPrivateKeyHex,
        sourceSetup.localParticipantPrivateKeyHex,
      );
      expect(
        retainedDraft.localParticipant.publicKeyHex,
        sourceSetup.localParticipant.publicKeyHex,
      );
      controller.dispose();
    },
  );

  test(
    'requires exact local approval and serializes coordinator switching',
    () async {
      final repository = _CoordinatorRepository();
      final runtime = _CoordinatorRoastRuntime()
        ..switchGate = Completer<void>()
        ..signatureRequestGate = Completer<void>();
      final controller = _coordinatorController(repository, runtime);
      await controller.load();
      await _flushEvents();
      const next = RoastCoordinatorAddress(
        id: 'approved-coordinator',
        relayUrls: [],
        ipAddrs: [],
      );

      await expectLater(
        controller.switchRoastCoordinator('setup', next, approved: false),
        throwsStateError,
      );
      expect(runtime.switchCalls, 0);

      final switching = controller.switchRoastCoordinator(
        'setup',
        next,
        approved: true,
      );
      await _flushEvents();
      expect(
        controller.roastCoordinatorState('setup'),
        RoastCoordinatorLocalState.switching,
      );
      await expectLater(
        controller.switchRoastCoordinator('setup', next, approved: true),
        throwsStateError,
      );
      expect(runtime.switchCalls, 1);
      runtime.switchGate!.complete();
      await switching;

      expect(controller.roastSetups.single.coordinatorId, next.id);
      expect(controller.roastSetups.single.groupKeyHex, 'expected-key');
      expect(
        controller.roastCoordinatorState('setup'),
        RoastCoordinatorLocalState.connected,
      );

      final signing = controller.signRoastMessage(
        controller.accounts.single,
        text: 'Coordinator switched',
      );
      await _flushEvents();
      runtime.signatureRequestGate!.complete();
      runtime.emit(
        RoastRuntimeMessageSigningResultEvent(
          'setup',
          requestIdHex: 'cc' * 16,
          creator: '01',
          signedMessage: RoastSignedMessage(
            text: 'Coordinator switched',
            publicKeyHex: '11' * 32,
            signatureHex: '22' * 64,
            encoded: 'signed-after-switch',
          ),
        ),
      );
      expect((await signing).encoded, 'signed-after-switch');
      await _flushEvents();
      controller.dispose();
    },
  );

  test(
    'uses address update when the approved endpoint ID is unchanged',
    () async {
      final repository = _CoordinatorRepository();
      final runtime = _CoordinatorRoastRuntime();
      final controller = _coordinatorController(repository, runtime);
      await controller.load();
      await _flushEvents();

      await controller.switchRoastCoordinator(
        'setup',
        const RoastCoordinatorAddress(
          id: 'coordinator',
          relayUrls: ['https://relay.example'],
          ipAddrs: ['127.0.0.1:443'],
        ),
        approved: true,
      );

      expect(runtime.addressUpdateCalls, 1);
      expect(runtime.switchCalls, 0);
      expect(controller.roastSetups.single.coordinatorRelayUrls, [
        'https://relay.example',
      ]);
      controller.dispose();
    },
  );

  test('pending signing state stops switching before persistence', () async {
    final repository = _CoordinatorRepository();
    final runtime = _CoordinatorRoastRuntime()
      ..switchFailure = RoastCoordinatorSwitchFailure(
        kind: RoastCoordinatorSwitchFailureKind.pendingSigningOperations,
        code: 'pending_signing_operations',
        cause: StateError('pending signing state'),
      );
    final controller = _coordinatorController(repository, runtime);
    await controller.load();
    await _flushEvents();

    await expectLater(
      controller.switchRoastCoordinator(
        'setup',
        const RoastCoordinatorAddress(
          id: 'new-coordinator',
          relayUrls: [],
          ipAddrs: [],
        ),
        approved: true,
      ),
      throwsA(isA<RoastCoordinatorSwitchFailure>()),
    );

    expect(repository.value!.roastSetups.single.coordinatorId, 'coordinator');
    expect(
      controller.roastCoordinatorState('setup'),
      RoastCoordinatorLocalState.recoveryRequired,
    );
    expect(
      controller.roastSetups.single.errorMessage,
      contains('signing operations or nonce records'),
    );
    controller.dispose();
  });

  for (final testCase in [
    (
      failure: _CoordinatorSaveFailure.beforeCommit,
      expectedCoordinator: 'coordinator',
    ),
    (
      failure: _CoordinatorSaveFailure.afterCommit,
      expectedCoordinator: 'new-coordinator',
    ),
  ]) {
    test(
      'recovers from ${testCase.failure.name} coordinator storage failure',
      () async {
        final repository = _CoordinatorRepository();
        final runtime = _CoordinatorRoastRuntime();
        final controller = _coordinatorController(repository, runtime);
        await controller.load();
        await _flushEvents();
        repository.failure = testCase.failure;

        await expectLater(
          controller.switchRoastCoordinator(
            'setup',
            const RoastCoordinatorAddress(
              id: 'new-coordinator',
              relayUrls: [],
              ipAddrs: [],
            ),
            approved: true,
          ),
          throwsA(isA<RoastCoordinatorSwitchFailure>()),
        );

        expect(
          repository.value!.roastSetups.single.coordinatorId,
          testCase.expectedCoordinator,
        );
        expect(
          runtime.startedCoordinatorIds.last,
          testCase.expectedCoordinator,
        );
        expect(
          controller.roastCoordinatorState('setup'),
          RoastCoordinatorLocalState.connected,
        );
        controller.dispose();
      },
    );
  }

  test('waits for a late coordinator commit after host timeout', () async {
    final repository = _CoordinatorRepository()
      ..coordinatorWriteGate = Completer<void>();
    final runtime = _CoordinatorRoastRuntime()
      ..failBeforePersistenceSettles = true;
    final controller = _coordinatorController(repository, runtime);
    await controller.load();
    await _flushEvents();
    var completed = false;

    final switching = controller
        .switchRoastCoordinator(
          'setup',
          const RoastCoordinatorAddress(
            id: 'late-coordinator',
            relayUrls: [],
            ipAddrs: [],
          ),
          approved: true,
        )
        .whenComplete(() => completed = true);
    await _flushEvents();
    expect(completed, isFalse);
    expect(
      controller.roastCoordinatorState('setup'),
      RoastCoordinatorLocalState.switching,
    );

    repository.coordinatorWriteGate!.complete();
    await expectLater(switching, throwsA(isA<RoastCoordinatorSwitchFailure>()));
    expect(
      repository.value!.roastSetups.single.coordinatorId,
      'late-coordinator',
    );
    expect(runtime.startedCoordinatorIds.last, 'late-coordinator');
    expect(
      controller.roastCoordinatorState('setup'),
      RoastCoordinatorLocalState.connected,
    );
    controller.dispose();
  });

  for (final code in ['connection_refused', 'group_mismatch']) {
    test('keeps the approved pin after coordinator $code', () async {
      final repository = _CoordinatorRepository();
      final runtime = _CoordinatorRoastRuntime()
        ..switchFailure = RoastCoordinatorSwitchFailure(
          kind: RoastCoordinatorSwitchFailureKind.connection,
          code: code,
          cause: StateError(code),
        );
      final controller = _coordinatorController(repository, runtime);
      await controller.load();
      await _flushEvents();

      await expectLater(
        controller.switchRoastCoordinator(
          'setup',
          const RoastCoordinatorAddress(
            id: 'approved-new-coordinator',
            relayUrls: [],
            ipAddrs: [],
          ),
          approved: true,
        ),
        throwsA(isA<RoastCoordinatorSwitchFailure>()),
      );

      expect(
        repository.value!.roastSetups.single.coordinatorId,
        'approved-new-coordinator',
      );
      expect(
        controller.roastCoordinatorState('setup'),
        RoastCoordinatorLocalState.recoveryRequired,
      );
      runtime.switchFailure = null;
      await controller.resumeRoastSetup('setup');
      expect(runtime.startedCoordinatorIds.last, 'approved-new-coordinator');
      expect(
        controller.roastCoordinatorState('setup'),
        RoastCoordinatorLocalState.connected,
      );
      controller.dispose();
    });
  }

  test('loads a saved coordinator pin before restart setup', () async {
    final repository = _CoordinatorRepository();
    final firstRuntime = _CoordinatorRoastRuntime()
      ..switchFailure = RoastCoordinatorSwitchFailure(
        kind: RoastCoordinatorSwitchFailureKind.connection,
        code: 'connection_refused',
        cause: StateError('offline'),
      );
    final first = _coordinatorController(repository, firstRuntime);
    await first.load();
    await _flushEvents();
    await expectLater(
      first.switchRoastCoordinator(
        'setup',
        const RoastCoordinatorAddress(
          id: 'saved-coordinator',
          relayUrls: [],
          ipAddrs: [],
        ),
        approved: true,
      ),
      throwsA(isA<RoastCoordinatorSwitchFailure>()),
    );
    first.dispose();

    final restartedRuntime = _CoordinatorRoastRuntime();
    final restarted = _coordinatorController(repository, restartedRuntime);
    await restarted.load();
    await _flushEvents();

    expect(
      restartedRuntime.startedCoordinatorIds,
      contains('saved-coordinator'),
    );
    expect(restarted.roastSetups.single.coordinatorId, 'saved-coordinator');
    restarted.dispose();
  });

  test(
    'distinguishes enrollment rejection and interruption without retrying',
    () async {
      final cases = <({RoastEnrollmentFailure failure, String message})>[
        (
          failure: RoastEnrollmentFailure(
            kind: RoastEnrollmentFailureKind.rejected,
            cause: StateError('rejected'),
            roomFailureCode: 0,
          ),
          message: 'room code 0',
        ),
        (
          failure: RoastEnrollmentFailure(
            kind: RoastEnrollmentFailureKind.timeout,
            cause: TimeoutException('timeout'),
          ),
          message: 'timed out',
        ),
        (
          failure: RoastEnrollmentFailure(
            kind: RoastEnrollmentFailureKind.malformedResponse,
            cause: const FormatException('malformed'),
          ),
          message: 'invalid enrollment response',
        ),
        (
          failure: RoastEnrollmentFailure(
            kind: RoastEnrollmentFailureKind.connection,
            cause: StateError('connection closed'),
          ),
          message: 'connection was interrupted',
        ),
      ];

      for (final testCase in cases) {
        final repository = MemoryWalletRepository();
        final runtime = _FakeRoastRuntime()..joinRoomError = testCase.failure;
        final controller = WalletController(
          repository,
          roastRuntime: runtime,
          roastKeyService: _EnrollmentRoastKeyService(),
        );
        await controller.load();
        final setupId = await controller.createRoastSetupDraft(
          role: RoastSetupRole.member,
          walletName: 'Enrollment test',
          participantName: 'Signer',
          threshold: 2,
          participantCount: 2,
          network: PeercoinNetworks.mainnet,
        );

        await expectLater(
          controller.joinRoastSetup(setupId, 'room-invite'),
          throwsA(same(testCase.failure)),
        );

        expect(runtime.joinRoomCalls, 1);
        expect(
          controller.roastSetups.single.errorMessage,
          contains(testCase.message),
        );
        controller.dispose();
      }
    },
  );

  test('deletes the last ROAST wallet and its local setup data', () async {
    final runtime = _FakeRoastRuntime();
    final operations = MemoryRoastSigningOperationRepository();
    await operations.putSigningOperation(
      RoastSigningOperation(
        setupId: 'setup',
        accountId: 'shared',
        requestIdHex: 'request',
        proposalHex: 'proposal',
        expectedInternalKeyHex: 'internal-key',
        derivationPath: const [0, 6, 0, 0, 0, 0],
        thresholdTransaction: const {},
        reservedOutpoints: const ['funding:0'],
        expiry: DateTime.now().add(const Duration(minutes: 1)),
        state: RoastSigningOperationState.broadcasted,
        updatedAt: DateTime.now(),
        rawTransactionHex: 'raw',
        transactionId: 'txid',
      ),
    );
    final controller = _controller(
      runtime: runtime,
      operationRepository: operations,
      active: true,
    );
    await controller.load();
    await _flushEvents();

    await controller.deleteAccount('shared');

    expect(controller.accounts, isEmpty);
    expect(controller.roastSetups, isEmpty);
    expect(runtime.deletedSetupIds, ['setup']);
    expect(await operations.loadSigningOperations(), isEmpty);
    controller.dispose();
  });

  test('counts the connected local signer for DKG quorum', () async {
    final runtime = _FakeRoastRuntime();
    final controller = _controller(runtime: runtime, role: RoastSetupRole.host);

    await controller.load();
    await _flushEvents();

    final setup = controller.roastSetups.single;
    expect(controller.onlineSignerCount(setup), 2);
    await controller.startRoastDkg(setup.id);
    expect(runtime.requestedDkgSetupIds, [setup.id]);

    controller.dispose();
  });

  test('asks a reconnected host to approve a pending DKG', () async {
    var notificationCount = 0;
    final expiry = DateTime.now().add(const Duration(hours: 1));
    final runtime = _FakeRoastRuntime()
      ..startSnapshot = RoastRuntimeSnapshot(
        connected: true,
        signerRunning: true,
        onlineParticipantIds: const ['02'],
        coordinatorId: 'coordinator',
        coordinatorRelayUrls: const [],
        coordinatorIpAddrs: const [],
        groupKeyHex: null,
        pendingDkgProposalHex: 'existing-proposal',
        pendingDkgStage: 'waiting',
        pendingDkgName: 'setup:generation:1',
        pendingDkgThreshold: 2,
        pendingDkgCreator: '01',
        pendingDkgExpiry: expiry,
      );
    final controller = _controller(
      runtime: runtime,
      role: RoastSetupRole.host,
      onRoastActionRequired: () => notificationCount++,
    );

    await controller.load();
    await _flushEvents();

    final setup = controller.roastSetups.single;
    expect(setup.status, RoastSetupStatus.awaitingDkgApproval);
    expect(setup.pendingDkgProposalHex, 'existing-proposal');
    expect(notificationCount, 1);

    controller.dispose();
  });

  test('rejects a DKG proposal that does not match setup policy', () async {
    final runtime = _FakeRoastRuntime();
    final controller = _controller(runtime: runtime);
    await controller.load();
    await _flushEvents();

    runtime.emit(
      RoastRuntimeDkgEvent(
        'setup',
        proposalHex: 'bad-proposal',
        name: 'setup:generation:1',
        threshold: 1,
        creator: '01',
        expiry: DateTime.now().add(const Duration(hours: 1)),
        description: roastKeyDescription(controller.roastSetups.single),
        stage: 'waiting',
        rejected: false,
      ),
    );
    await _flushEvents();

    expect(runtime.rejectedDkgProposalHexes, ['bad-proposal']);
    expect(controller.roastSetups.single.pendingDkgProposalHex, isNull);

    runtime.emit(
      RoastRuntimeDkgEvent(
        'setup',
        proposalHex: 'valid-proposal',
        name: 'setup:generation:1',
        threshold: 2,
        creator: '01',
        expiry: DateTime.now().add(const Duration(hours: 1)),
        description: roastKeyDescription(controller.roastSetups.single),
        stage: 'waiting',
        rejected: false,
      ),
    );
    await _flushEvents();

    final setup = controller.roastSetups.single;
    expect(setup.status, RoastSetupStatus.awaitingDkgApproval);
    expect(setup.pendingDkgProposalHex, 'valid-proposal');
    expect(setup.pendingDkgThreshold, 2);
    expect(
      controller
          .activitiesFor(controller.accounts.single)
          .map((item) => item.type),
      [WalletActivityType.dkgStarted],
    );

    runtime.emit(
      RoastRuntimeDkgEvent(
        'setup',
        proposalHex: 'valid-proposal',
        name: 'setup:generation:1',
        threshold: 2,
        creator: '01',
        expiry: DateTime.now().add(const Duration(hours: 1)),
        description: roastKeyDescription(controller.roastSetups.single),
        stage: 'round1',
        rejected: false,
      ),
    );
    await _flushEvents();
    expect(controller.roastSetups.single.status, RoastSetupStatus.creatingKey);

    runtime.emit(
      RoastRuntimeDkgEvent(
        'setup',
        proposalHex: 'valid-proposal',
        name: 'setup:generation:1',
        threshold: 2,
        creator: '02',
        expiry: DateTime.now().add(const Duration(hours: 1)),
        description: roastKeyDescription(controller.roastSetups.single),
        stage: 'rejected',
        rejected: true,
        failure: 'participantRejected',
      ),
    );
    await _flushEvents();

    expect(controller.roastSetups.single.status, RoastSetupStatus.ready);
    expect(controller.roastSetups.single.pendingDkgProposalHex, isNull);
    expect(runtime.rejectedDkgProposalHexes, ['bad-proposal']);
    expect(
      controller
          .activitiesFor(controller.accounts.single)
          .map((item) => item.type),
      [WalletActivityType.dkgFailed, WalletActivityType.dkgStarted],
    );

    controller.dispose();
  });

  test('ignores foreign keys and continues after an event failure', () async {
    final runtime = _FakeRoastRuntime();
    final keyService = _FakeRoastKeyService()..failNextDerivation = true;
    final controller = _controller(runtime: runtime, keyService: keyService);
    await controller.load();
    await _flushEvents();

    runtime.emit(
      RoastRuntimeKeyEvent(
        'setup',
        groupKeyHex: 'foreign-key',
        keyName: 'another-key',
        description: 'foreign',
      ),
    );
    await _flushEvents();
    expect(controller.roastSetups.single.groupKeyHex, isNull);

    runtime.emit(
      RoastRuntimeKeyEvent(
        'setup',
        groupKeyHex: 'expected-key',
        keyName: 'setup:generation:1',
        description: 'expected',
      ),
    );
    await _flushEvents();
    expect(controller.roastSetups.single.status, RoastSetupStatus.error);

    runtime.emit(
      RoastRuntimeSnapshotEvent(
        'setup',
        connected: true,
        signerRunning: true,
        onlineParticipantIds: const ['01'],
        coordinatorId: 'coordinator',
        coordinatorRelayUrls: const [],
        coordinatorIpAddrs: const [],
      ),
    );
    runtime.emit(
      RoastRuntimeKeyEvent(
        'setup',
        groupKeyHex: 'expected-key',
        keyName: 'setup:generation:1',
        description: 'expected',
      ),
    );
    await _flushEvents();

    expect(controller.roastSetups.single.status, RoastSetupStatus.active);
    expect(controller.accounts.single.address, 'pc1pshared');
    expect(
      controller.activitiesFor(controller.accounts.single).single.type,
      WalletActivityType.dkgCompleted,
    );

    final vault = controller.vault;
    var notifications = 0;
    controller.addListener(() => notifications++);
    runtime.emit(
      RoastRuntimeKeyEvent(
        'setup',
        groupKeyHex: 'expected-key',
        keyName: 'setup:generation:1',
        description: 'expected',
      ),
    );
    await _flushEvents();
    expect(controller.vault, same(vault));
    expect(notifications, 0);

    controller.dispose();
  });

  test('records the signature request lifecycle as wallet activity', () async {
    var notificationCount = 0;
    final runtime = _FakeRoastRuntime()..snapshotGroupKey = 'expected-key';
    final electrumx = _FakeElectrumxService();
    final controller = _controller(
      runtime: runtime,
      electrumx: electrumx,
      active: true,
      onRoastActionRequired: () => notificationCount++,
    );
    await controller.load();
    await _flushEvents();
    electrumx.emit('pc1pshared', const [
      ElectrumxUtxo(
        address: 'pc1pshared',
        txHash: 'funding',
        txPos: 0,
        height: 100,
        value: 2000000,
      ),
    ]);
    await _flushEvents();

    final approved = _signingRequest('aa' * 16);
    runtime.emit(RoastRuntimeSigningRequestEvent('setup', request: approved));
    await _flushEvents();
    expect(
      controller.activitiesFor(controller.accounts.single).single.details,
      approved.message,
    );
    runtime.emit(RoastRuntimeSigningRequestEvent('setup', request: approved));
    await _flushEvents();
    expect(notificationCount, 1);
    await controller.acceptRoastSigningRequest(
      controller.roastSigningRequests.single,
    );
    expect(controller.roastSigningRequests.single.request.status, 'accepted');

    final rejected = _signingRequest('bb' * 16);
    runtime.emit(RoastRuntimeSigningRequestEvent('setup', request: rejected));
    await _flushEvents();
    expect(notificationCount, 2);
    await controller.rejectRoastSigningRequest(
      controller.roastSigningRequests.singleWhere(
        (item) => item.request.idHex == rejected.idHex,
      ),
    );
    expect(
      controller.roastSigningRequests
          .singleWhere((item) => item.request.idHex == rejected.idHex)
          .request
          .status,
      'rejected',
    );

    final expired = _signingRequest('cc' * 16);
    runtime.emit(RoastRuntimeSigningRequestEvent('setup', request: expired));
    await _flushEvents();
    expect(notificationCount, 3);
    runtime.emit(
      RoastRuntimeSigningRequestRemovedEvent(
        'setup',
        requestIdHex: expired.idHex,
        expired: true,
      ),
    );
    await _flushEvents();

    expect(runtime.acceptedSigningRequestIds, [approved.idHex]);
    expect(runtime.rejectedSigningRequestIds, [rejected.idHex]);
    expect(
      controller
          .activitiesFor(controller.accounts.single)
          .map((item) => item.type),
      [
        WalletActivityType.signatureRequestExpired,
        WalletActivityType.signatureRequestReceived,
        WalletActivityType.signatureRequestRejected,
        WalletActivityType.signatureRequestReceived,
        WalletActivityType.signatureRequestApproved,
        WalletActivityType.signatureRequestReceived,
      ],
    );

    controller.dispose();
  });

  test('reserves UTXOs selected by an incoming signing request', () async {
    final runtime = _FakeRoastRuntime()..snapshotGroupKey = 'expected-key';
    final electrumx = _FakeElectrumxService();
    final controller = _controller(
      runtime: runtime,
      electrumx: electrumx,
      active: true,
    );
    await controller.load();
    await _flushEvents();
    const utxo = ElectrumxUtxo(
      address: 'pc1pshared',
      txHash: 'funding',
      txPos: 0,
      height: 100,
      value: 2000000,
    );
    const available = ElectrumxUtxo(
      address: 'pc1pshared',
      txHash: 'available',
      txPos: 0,
      height: 100,
      value: 1000000,
    );
    electrumx.emit('pc1pshared', const [
      utxo,
      available,
      ElectrumxUtxo(
        address: 'pc1pshared',
        txHash: 'pending',
        txPos: 0,
        height: 0,
        value: 500000,
      ),
      ElectrumxUtxo(
        address: 'pc1pshared',
        txHash: 'unconfirmed',
        txPos: 0,
        height: -1,
        value: 250000,
      ),
    ]);
    await _flushEvents();

    final request = _signingRequest('aa' * 16);
    final overlapping = _signingRequest('bb' * 16);
    runtime.emit(RoastRuntimeSigningRequestEvent('setup', request: request));
    runtime.emit(
      RoastRuntimeSigningRequestEvent('setup', request: overlapping),
    );
    await _flushEvents();

    final account = controller.accounts.single;
    expect(controller.roastSigningRequests, hasLength(2));
    expect(controller.availableUtxosFor(account), [available]);
    expect(controller.availableBalanceSatsFor(account), 1000000);
    expect(controller.reservedBalanceSatsFor(account), 2000000);
    expect(controller.balanceFor(account), (
      totalSats: 3750000,
      confirmedSats: 3000000,
      pendingSats: 750000,
      availableSats: 1000000,
      reservedSats: 2000000,
      utxoCount: 4,
    ));
    await expectLater(
      controller.sendTransaction(
        const WalletTransactionPreview(
          accountId: 'shared',
          sourceAddress: 'pc1pshared',
          destinationAddress: 'destination',
          amountSats: 1000000,
          feeSats: 1000,
          changeSats: 999000,
          feeRateSatsPerKb: 10000,
          selectedUtxos: [utxo],
        ),
      ),
      throwsA(
        isA<WalletTransactionRejected>().having(
          (error) => error.message,
          'message',
          'A transaction input is reserved by another signing request.',
        ),
      ),
    );

    await controller.acceptRoastSigningRequest(
      controller.roastSigningRequests.first,
    );
    expect(controller.availableUtxosFor(account), [available]);

    runtime.emit(
      RoastRuntimeSigningRequestRemovedEvent(
        'setup',
        requestIdHex: request.idHex,
        expired: false,
      ),
    );
    await _flushEvents();
    expect(controller.balanceFor(account).reservedSats, 2000000);
    expect(controller.availableUtxosFor(account), [available]);

    runtime.emit(
      RoastRuntimeSigningRequestRemovedEvent(
        'setup',
        requestIdHex: overlapping.idHex,
        expired: false,
      ),
    );
    await _flushEvents();

    expect(controller.availableUtxosFor(account), [utxo, available]);
    expect(controller.availableBalanceSatsFor(account), 3000000);
    expect(controller.reservedBalanceSatsFor(account), 0);
    expect(controller.balanceFor(account).availableSats, 3000000);
    controller.dispose();
  });

  test('excludes inactive requests from balance reservations', () async {
    final runtime = _FakeRoastRuntime()..snapshotGroupKey = 'expected-key';
    final electrumx = _FakeElectrumxService();
    final controller = _controller(
      runtime: runtime,
      electrumx: electrumx,
      active: true,
    );
    await controller.load();
    await _flushEvents();
    electrumx.emit('pc1pshared', const [
      ElectrumxUtxo(
        address: 'pc1pshared',
        txHash: 'funding',
        txPos: 0,
        height: 100,
        value: 2000000,
      ),
    ]);
    for (final request in [
      _signingRequest('aa' * 16, status: 'rejected'),
      _signingRequest('bb' * 16, stage: 'failed'),
      _signingRequest(
        'cc' * 16,
        expiry: DateTime.now().subtract(const Duration(minutes: 1)),
      ),
    ]) {
      runtime.emit(RoastRuntimeSigningRequestEvent('setup', request: request));
    }
    await _flushEvents();
    final account = controller.accounts.single;
    expect(controller.roastSigningRequests, hasLength(2));
    expect(controller.balanceFor(account).reservedSats, 0);
    expect(controller.balanceFor(account).availableSats, 2000000);
    expect(controller.availableUtxosFor(account), hasLength(1));
    controller.dispose();
  });

  test(
    'replaces signing progress for the same request until terminal flow',
    () async {
      final runtime = _FakeRoastRuntime()..snapshotGroupKey = 'expected-key';
      final controller = _controller(runtime: runtime, active: true);
      await controller.load();
      await _flushEvents();

      final requestId = 'ab' * 16;
      runtime.emit(
        RoastRuntimeSigningRequestEvent(
          'setup',
          request: _messageSigningRequest(
            requestId,
            threshold: 3,
            contributingParticipants: const ['01', '02', '03'],
          ),
        ),
      );
      await _flushEvents();

      runtime.emit(
        RoastRuntimeSigningRequestEvent(
          'setup',
          request: _messageSigningRequest(
            requestId,
            status: 'accepted',
            stage: 'signing',
            threshold: 3,
            contributingParticipants: const [],
          ),
        ),
      );
      await _flushEvents();

      expect(controller.roastSigningRequests, hasLength(1));
      expect(controller.roastSigningRequests.single.request.status, 'accepted');
      expect(
        controller.roastSigningRequests.single.request.progress.stage,
        'signing',
      );
      expect(
        controller
            .roastSigningRequests
            .single
            .request
            .progress
            .contributingParticipants,
        isEmpty,
      );

      runtime.emit(
        RoastRuntimeSigningRequestEvent(
          'setup',
          request: _messageSigningRequest(
            requestId,
            status: 'accepted',
            stage: 'completed',
            threshold: 2,
            contributingParticipants: const ['01', '02'],
          ),
        ),
      );
      await _flushEvents();

      final completed = controller.roastSigningRequests.single.request;
      expect(completed.progress.threshold, 2);
      expect(completed.progress.stage, 'completed');

      runtime.emit(
        RoastRuntimeSigningResultEvent(
          'setup',
          requestIdHex: requestId,
          proposalHex: completed.proposalHex,
          signatures: const [],
          creator: completed.creator,
        ),
      );
      await _flushEvents();
      expect(controller.roastSigningRequests, isEmpty);

      final failedId = 'cd' * 16;
      runtime.emit(
        RoastRuntimeSigningRequestEvent(
          'setup',
          request: _messageSigningRequest(
            failedId,
            status: 'accepted',
            stage: 'failed',
          ),
        ),
      );
      await _flushEvents();
      expect(
        controller.roastSigningRequests.single.request.progress.stage,
        'failed',
      );

      runtime.emit(
        RoastRuntimeFailureEvent(
          'setup',
          message: 'Signing request failed.',
          interrupted: false,
          operation: RoastRuntimeOperation.signatures,
          requestIdHex: failedId,
        ),
      );
      await _flushEvents();
      expect(controller.roastSigningRequests, isEmpty);

      controller.dispose();
    },
  );

  test(
    'accepts message requests and returns the portable signed result',
    () async {
      final runtime = _FakeRoastRuntime()..snapshotGroupKey = 'expected-key';
      runtime.signatureRequestGate = Completer<void>();
      final controller = _controller(runtime: runtime, active: true);
      await controller.load();
      await _flushEvents();

      final incoming = _messageSigningRequest('ee' * 16);
      runtime.emit(RoastRuntimeSigningRequestEvent('setup', request: incoming));
      await _flushEvents();

      expect(
        controller.roastSigningRequests.single.request.signedMessageText,
        'Deploy release 1.0',
      );
      await controller.acceptRoastSigningRequest(
        controller.roastSigningRequests.single,
      );

      final signing = controller.signRoastMessage(
        controller.accounts.single,
        text: 'Ship build 42\nunchanged ',
        message: 'Release approval',
      );
      await _flushEvents();
      expect(runtime.messageText, 'Ship build 42\nunchanged ');
      expect(runtime.messageNote, 'Release approval');
      expect(controller.roastMessageSigningInProgress('setup'), isTrue);
      expect(
        controller.activitiesFor(controller.accounts.single).first.type,
        WalletActivityType.messageSignatureRequested,
      );

      runtime.emit(
        RoastRuntimeSigningRequestEvent(
          'setup',
          request: _messageSigningRequest(
            'cc' * 16,
            creator: '02',
            status: 'accepted',
          ),
        ),
      );
      await _flushEvents();
      expect(
        controller
            .activitiesFor(controller.accounts.single)
            .where(
              (activity) =>
                  activity.type ==
                      WalletActivityType.signatureRequestApproved &&
                  activity.reference == 'cc' * 16,
            ),
        isEmpty,
      );

      runtime.signatureRequestGate!.complete();
      runtime.emit(
        RoastRuntimeMessageSigningResultEvent(
          'setup',
          requestIdHex: 'cc' * 16,
          creator: '02',
          signedMessage: RoastSignedMessage(
            text: 'Ship build 42\nunchanged ',
            publicKeyHex: '11' * 32,
            signatureHex: '22' * 64,
            encoded: '{"format":"noosphere-signed-message"}',
          ),
        ),
      );
      final result = await signing;
      await _flushEvents();

      expect(result.text, 'Ship build 42\nunchanged ');
      expect(result.encoded, contains('noosphere-signed-message'));
      expect(controller.completedRoastMessage('setup'), same(result));
      expect(controller.roastMessageSigningInProgress('setup'), isFalse);
      final signedActivity = controller
          .activitiesFor(controller.accounts.single)
          .first;
      expect(signedActivity.signedMessagePublicKeyHex, '11' * 32);
      expect(signedActivity.signedMessageSignatureHex, '22' * 64);
      expect(
        signedActivity.signedMessageEncoded,
        '{"format":"noosphere-signed-message"}',
      );
      expect(
        controller
            .activitiesFor(controller.accounts.single)
            .take(2)
            .map((activity) => activity.type),
        [
          WalletActivityType.messageSigned,
          WalletActivityType.messageSignatureRequested,
        ],
      );
      controller.dispose();
    },
  );

  test('records expiration of a locally requested message', () async {
    final requestId = 'cc' * 16;
    final runtime = _FakeRoastRuntime()..snapshotGroupKey = 'expected-key';
    final controller = _controller(
      runtime: runtime,
      active: true,
      activities: [
        WalletActivity(
          id: 'message-signature-requested:setup:$requestId',
          accountId: 'shared',
          type: WalletActivityType.messageSignatureRequested,
          occurredAt: DateTime.utc(2026),
          reference: requestId,
          details: 'Expired message',
        ),
      ],
    );
    await controller.load();
    await _flushEvents();

    runtime.emit(
      RoastRuntimeSigningRequestRemovedEvent(
        'setup',
        requestIdHex: requestId,
        expired: true,
      ),
    );
    await _flushEvents();

    expect(
      controller
          .activitiesFor(controller.accounts.single)
          .map((activity) => activity.type),
      [
        WalletActivityType.signatureRequestExpired,
        WalletActivityType.messageSignatureRequested,
      ],
    );
    controller.dispose();
  });

  test('stores replayed signed messages for every participant', () async {
    final requestId = 'ab' * 16;
    final occurredAt = DateTime.utc(2026, 1, 1);
    final runtime = _FakeRoastRuntime()..snapshotGroupKey = 'expected-key';
    final controller = _controller(
      runtime: runtime,
      active: true,
      activities: [
        WalletActivity(
          id: 'message-signed:setup:$requestId',
          accountId: 'shared',
          type: WalletActivityType.messageSigned,
          occurredAt: occurredAt,
          reference: requestId,
          details: 'Previously stored text',
        ),
      ],
    );
    await controller.load();
    await _flushEvents();

    runtime.emit(
      RoastRuntimeMessageSigningResultEvent(
        'setup',
        requestIdHex: requestId,
        creator: '01',
        signedMessage: RoastSignedMessage(
          text: 'Signed by the group',
          publicKeyHex: '11' * 32,
          signatureHex: '22' * 64,
          encoded: '{"format":"noosphere-signed-message"}',
        ),
      ),
    );
    await _flushEvents();

    final activities = controller.activitiesFor(controller.accounts.single);
    expect(activities, hasLength(1));
    expect(activities.single.occurredAt, occurredAt);
    expect(activities.single.details, 'Signed by the group');
    expect(activities.single.signedMessagePublicKeyHex, '11' * 32);
    expect(activities.single.signedMessageSignatureHex, '22' * 64);
    expect(
      activities.single.signedMessageEncoded,
      '{"format":"noosphere-signed-message"}',
    );
    expect(
      controller.completedRoastMessage('setup')?.text,
      'Signed by the group',
    );
    controller.dispose();
  });

  test('hides legacy approvals for locally requested messages', () async {
    final requestId = 'ab' * 16;
    final controller = _controller(
      runtime: _FakeRoastRuntime()..snapshotGroupKey = 'expected-key',
      active: true,
      activities: [
        WalletActivity(
          id: 'signature-request-approved:setup:$requestId',
          accountId: 'shared',
          type: WalletActivityType.signatureRequestApproved,
          occurredAt: DateTime.utc(2026, 1, 1, 0, 1),
          reference: requestId,
        ),
        WalletActivity(
          id: 'message-signature-requested:setup:$requestId',
          accountId: 'shared',
          type: WalletActivityType.messageSignatureRequested,
          occurredAt: DateTime.utc(2026),
          reference: requestId,
          details: 'Legacy request',
        ),
      ],
    );
    await controller.load();
    await _flushEvents();

    expect(controller.vault!.activities, hasLength(2));
    expect(
      controller
          .activitiesFor(controller.accounts.single)
          .map((activity) => activity.type),
      [WalletActivityType.messageSignatureRequested],
    );
    controller.dispose();
  });

  test('rebroadcasts the exact persisted transaction after restart', () async {
    final runtime = _FakeRoastRuntime()..snapshotGroupKey = 'expected-key';
    final operations = MemoryRoastSigningOperationRepository();
    final operation = RoastSigningOperation(
      setupId: 'setup',
      accountId: 'shared',
      requestIdHex: 'request',
      proposalHex: 'proposal',
      expectedInternalKeyHex: 'internal-key',
      derivationPath: const [0, 6, 0, 0, 0, 0],
      thresholdTransaction: const {},
      reservedOutpoints: const ['funding:0'],
      expiry: DateTime.now().add(const Duration(minutes: 1)),
      state: RoastSigningOperationState.broadcastUnknown,
      updatedAt: DateTime.now(),
      rawTransactionHex: 'persisted-raw-transaction',
      transactionId: 'local-txid',
    );
    await operations.putSigningOperation(operation);
    final electrumx = _FakeElectrumxService();
    final controller = _controller(
      runtime: runtime,
      operationRepository: operations,
      electrumx: electrumx,
      active: true,
    );
    await controller.load();
    await _flushEvents();

    final restored = controller.recoverableRoastSigningOperations.single;
    final result = await controller.retryRoastBroadcast(restored);

    expect(electrumx.broadcasts, ['persisted-raw-transaction']);
    expect(result.transactionId, 'local-txid');
    expect(
      (await operations.getSigningOperation(operation.storageId))?.state,
      RoastSigningOperationState.broadcasted,
    );

    controller.dispose();
  });

  test('queues signing while quorum is offline', () async {
    final signingKey = ECPrivateKey.fromHex('${'0' * 63}1');
    final destinationKey = ECPrivateKey.fromHex('${'0' * 63}2');
    final derived = const RoastKeyService().deriveAddress(
      groupKeyHex: signingKey.pubkey.hex,
      threshold: 2,
      network: PeercoinNetworks.mainnet,
      accountIndex: 0,
    );
    final sourceAddress = derived.address;
    final destinationAddress = P2TRAddress.fromTweakedKey(
      destinationKey.pubkey,
      hrp: Network.mainnet.bech32Hrp,
    ).toString();
    final operations = MemoryRoastSigningOperationRepository();
    final runtime = _SigningRoastRuntime(operations, signingKey);
    final electrumx = _FakeElectrumxService();
    final repository = MemoryWalletRepository()
      ..value = WalletVault(
        accounts: [
          WalletAccount(
            id: 'shared',
            name: 'Shared wallet',
            accountIndex: 0,
            blockchainId: 'peercoin',
            networkId: 'mainnet',
            derivationState: WalletDerivationState.ready,
            keySource: WalletKeySource.roast,
            sourceId: 'setup',
            keyId: 'setup:generation:1',
            derivationPath: 'R/0/6/0/0/0/0',
            address: sourceAddress,
            createdAt: DateTime.utc(2026),
          ),
        ],
        nextAccountIndex: 0,
        roastSetups: [
          _setup(
            RoastSetupRole.host,
            active: true,
          ).copyWith(groupKeyHex: signingKey.pubkey.hex),
        ],
      );
    final controller = WalletController(
      repository,
      roastRuntime: runtime,
      roastSigningOperations: operations,
      roastKeyService: const RoastKeyService(),
      networkServiceFactory: (_) async => electrumx,
    );
    await controller.load();
    await _flushEvents();
    expect(
      controller.onlineSignerCount(controller.roastSetups.single),
      lessThan(controller.roastSetups.single.threshold),
    );

    final preview = const CoinlibWalletTransactionService().prepare(
      accountId: 'shared',
      network: PeercoinNetworks.mainnet,
      sourceAddress: sourceAddress,
      availableUtxos: [
        ElectrumxUtxo(
          address: sourceAddress,
          txHash: 'd' * 64,
          txPos: 0,
          height: 100,
          value: 2000000,
        ),
      ],
      request: WalletSendRequest(
        destinationAddress: destinationAddress,
        amountSats: 1000000,
        feeRateSatsPerKb: 10000,
        signingMessage: 'Quarterly hosting bill',
      ),
    );
    final result = await controller.sendTransaction(preview);

    final stored = (await operations.loadSigningOperations()).single;
    expect(stored.signaturesHex, isNotEmpty);
    expect(stored.rawTransactionHex, electrumx.broadcasts.single);
    expect(stored.transactionId, result.transactionId);
    expect(stored.state, RoastSigningOperationState.broadcasted);
    expect(runtime.signingMessage, 'Quarterly hosting bill');
    expect(
      controller
          .activitiesFor(controller.accounts.single)
          .map((item) => item.type),
      [
        WalletActivityType.transactionBroadcast,
        WalletActivityType.transactionSigned,
        WalletActivityType.transactionSignatureRequested,
      ],
    );

    controller.dispose();
  });

  for (final scenario in [
    (
      kind: WalletSigningFailureKind.rejected,
      operation: RoastRuntimeOperation.signatures,
      interrupted: false,
      message: 'The previous connection expired; this request was declined.',
      state: RoastSigningOperationState.rejected,
      throwsBeforeSubmit: false,
      reservesUtxos: false,
    ),
    (
      kind: WalletSigningFailureKind.interrupted,
      operation: RoastRuntimeOperation.signatures,
      interrupted: true,
      message: 'Signing request failed.',
      state: RoastSigningOperationState.interrupted,
      throwsBeforeSubmit: false,
      reservesUtxos: true,
    ),
    (
      kind: WalletSigningFailureKind.interrupted,
      operation: RoastRuntimeOperation.signingPersistence,
      interrupted: false,
      message: 'Signing request failed.',
      state: RoastSigningOperationState.interrupted,
      throwsBeforeSubmit: false,
      reservesUtxos: true,
    ),
    (
      kind: WalletSigningFailureKind.expired,
      operation: RoastRuntimeOperation.signatures,
      interrupted: false,
      message: 'No signatures arrived.',
      state: RoastSigningOperationState.expired,
      throwsBeforeSubmit: false,
      reservesUtxos: false,
    ),
    (
      kind: WalletSigningFailureKind.interrupted,
      operation: RoastRuntimeOperation.signatures,
      interrupted: true,
      message: 'Operation could not be completed.',
      state: RoastSigningOperationState.interrupted,
      throwsBeforeSubmit: true,
      reservesUtxos: true,
    ),
  ]) {
    test(
      'classifies ${scenario.operation.name} as ${scenario.state.name} '
      '${scenario.throwsBeforeSubmit ? 'before submission' : 'independently of message text'}',
      () async {
        final signingKey = ECPrivateKey.fromHex('${'0' * 63}1');
        final destinationKey = ECPrivateKey.fromHex('${'0' * 63}2');
        final sourceAddress = P2TRAddress.fromTaproot(
          Taproot(internalKey: signingKey.pubkey),
          hrp: Network.mainnet.bech32Hrp,
        ).toString();
        final destinationAddress = P2TRAddress.fromTweakedKey(
          destinationKey.pubkey,
          hrp: Network.mainnet.bech32Hrp,
        ).toString();
        final operations = MemoryRoastSigningOperationRepository();
        final runtime = _FakeRoastRuntime()
          ..snapshotGroupKey = 'expected-key'
          ..failSigningRequests =
              scenario.kind != WalletSigningFailureKind.expired &&
              !scenario.throwsBeforeSubmit
          ..signatureRequestError = scenario.throwsBeforeSubmit
              ? StateError(scenario.message)
              : null
          ..signingFailureOperation = scenario.operation
          ..signingFailureInterrupted = scenario.interrupted
          ..signingFailureMessage = scenario.message;
        final electrumx = _FakeElectrumxService();
        final controller = _activeController(
          runtime: runtime,
          operations: operations,
          electrumx: electrumx,
          sourceAddress: sourceAddress,
          derived: RoastDerivedAddress(
            path: const [0, 6, 0, 0, 0, 0],
            pathLabel: 'R/0/6/0/0/0/0',
            address: sourceAddress,
            internalKeyHex: signingKey.pubkey.hex,
          ),
        );
        await controller.load();
        await _flushEvents();
        final preview = const CoinlibWalletTransactionService().prepare(
          accountId: 'shared',
          network: PeercoinNetworks.mainnet,
          sourceAddress: sourceAddress,
          availableUtxos: [
            ElectrumxUtxo(
              address: sourceAddress,
              txHash: 'd' * 64,
              txPos: 0,
              height: 100,
              value: 2000000,
            ),
          ],
          request: WalletSendRequest(
            destinationAddress: destinationAddress,
            amountSats: 1000000,
            feeRateSatsPerKb: 10000,
          ),
        );

        await expectLater(
          controller.sendTransaction(
            preview,
            signatureRequestTimeout:
                scenario.kind == WalletSigningFailureKind.expired
                ? const Duration(milliseconds: 50)
                : defaultRoastSigningRequestTimeout,
          ),
          throwsA(
            isA<WalletSigningFailure>()
                .having((error) => error.kind, 'kind', scenario.kind)
                .having(
                  (error) => error.message,
                  'message',
                  scenario.throwsBeforeSubmit
                      ? contains('coordinator')
                      : isNotEmpty,
                ),
          ),
        );

        expect(controller.roastSetups.single.status, RoastSetupStatus.active);
        final failedOperation =
            (await operations.loadSigningOperations()).single;
        expect(failedOperation.state, scenario.state);
        expect(failedOperation.reservesUtxos, scenario.reservesUtxos);
        final restored = RoastSigningOperation.fromJson(
          failedOperation.toJson(),
        );
        expect(restored.state, scenario.state);
        expect(restored.reservesUtxos, failedOperation.reservesUtxos);
        final legacyJson = failedOperation.toJson()
          ..remove('schemaVersion')
          ..['state'] = 'interrupted'
          ..['errorMessage'] = 'Signing request failed.';
        final legacy = RoastSigningOperation.fromJson(legacyJson);
        expect(legacy.state, RoastSigningOperationState.rejected);
        expect(legacy.reservesUtxos, isFalse);
        expect(
          controller.hasDismissibleRoastSigningOperation('shared'),
          scenario.reservesUtxos,
        );
        if (scenario.reservesUtxos) {
          await controller.dismissRoastSigningOperation('shared');
          expect(
            (await operations.getSigningOperation(failedOperation.storageId))!
                .reservesUtxos,
            isFalse,
          );
        }
        controller.dispose();
      },
    );
  }

  test(
    'keeps broadcast UTXOs reserved until sync observes the spend',
    () async {
      final operations = MemoryRoastSigningOperationRepository();
      final operation = RoastSigningOperation(
        setupId: 'setup',
        accountId: 'shared',
        requestIdHex: 'request',
        proposalHex: 'proposal',
        expectedInternalKeyHex: 'internal-key',
        derivationPath: const [0, 6, 0, 0, 0, 0],
        thresholdTransaction: const {},
        reservedOutpoints: const ['funding:0'],
        expiry: DateTime.now().subtract(const Duration(minutes: 1)),
        state: RoastSigningOperationState.broadcasted,
        updatedAt: DateTime.now(),
        rawTransactionHex: 'raw',
        transactionId: 'txid',
      );
      await operations.putSigningOperation(operation);
      final runtime = _FakeRoastRuntime()..snapshotGroupKey = 'expected-key';
      final electrumx = _FakeElectrumxService();
      final controller = _controller(
        runtime: runtime,
        operationRepository: operations,
        electrumx: electrumx,
        active: true,
      );
      await controller.load();
      await _flushEvents();

      electrumx.emit('pc1pshared', const [
        ElectrumxUtxo(
          address: 'pc1pshared',
          txHash: 'funding',
          txPos: 0,
          height: 100,
          value: 2000000,
        ),
      ]);
      await _flushEvents();
      expect(
        controller.confirmedBalanceSatsFor(controller.accounts.single),
        2000000,
      );
      expect(
        controller.reservedBalanceSatsFor(controller.accounts.single),
        2000000,
      );
      expect(controller.availableBalanceSatsFor(controller.accounts.single), 0);
      expect(controller.balanceFor(controller.accounts.single), (
        totalSats: 2000000,
        confirmedSats: 2000000,
        pendingSats: 0,
        availableSats: 0,
        reservedSats: 2000000,
        utxoCount: 1,
      ));
      expect(
        (await operations.getSigningOperation(operation.storageId))
            ?.reservationsReleased,
        isFalse,
      );

      electrumx.emit('pc1pshared', const []);
      await _flushEvents();
      expect(
        (await operations.getSigningOperation(operation.storageId))
            ?.reservationsReleased,
        isTrue,
      );
      controller.dispose();
    },
  );
}

WalletController _coordinatorController(
  _CoordinatorRepository repository,
  _CoordinatorRoastRuntime runtime,
) {
  repository.value ??= WalletVault(
    accounts: [
      WalletAccount(
        id: 'shared',
        name: 'Shared wallet',
        accountIndex: 0,
        blockchainId: 'peercoin',
        networkId: 'mainnet',
        derivationState: WalletDerivationState.ready,
        keySource: WalletKeySource.roast,
        sourceId: 'setup',
        keyId: 'setup:generation:1',
        derivationPath: 'R/0/6/0/0/0/0',
        address: 'pc1pshared',
        createdAt: DateTime.utc(2026),
      ),
    ],
    nextAccountIndex: 0,
    roastSetups: [_setup(RoastSetupRole.host, active: true)],
  );
  return WalletController(
    repository,
    roastRuntime: runtime,
    roastKeyService: _FakeRoastKeyService(),
    networkServiceFactory: (_) async => null,
  );
}

WalletController _activeController({
  required _FakeRoastRuntime runtime,
  required RoastSigningOperationRepository operations,
  required _FakeElectrumxService electrumx,
  required String sourceAddress,
  required RoastDerivedAddress derived,
}) {
  final repository = MemoryWalletRepository()
    ..value = WalletVault(
      accounts: [
        WalletAccount(
          id: 'shared',
          name: 'Shared wallet',
          accountIndex: 0,
          blockchainId: 'peercoin',
          networkId: 'mainnet',
          derivationState: WalletDerivationState.ready,
          keySource: WalletKeySource.roast,
          sourceId: 'setup',
          keyId: 'setup:generation:1',
          derivationPath: derived.pathLabel,
          address: sourceAddress,
          createdAt: DateTime.utc(2026),
        ),
      ],
      nextAccountIndex: 0,
      roastSetups: [_setup(RoastSetupRole.host, active: true)],
    );
  return WalletController(
    repository,
    roastRuntime: runtime,
    roastSigningOperations: operations,
    roastKeyService: _FixedRoastKeyService(derived),
    networkServiceFactory: (_) async => electrumx,
  );
}

WalletController _controller({
  required _FakeRoastRuntime runtime,
  RoastSetupRole role = RoastSetupRole.member,
  _FakeRoastKeyService? keyService,
  RoastSigningOperationRepository? operationRepository,
  _FakeElectrumxService? electrumx,
  bool active = false,
  List<WalletActivity> activities = const [],
  void Function()? onRoastActionRequired,
}) {
  final repository = MemoryWalletRepository()
    ..value = WalletVault(
      accounts: [
        WalletAccount(
          id: 'shared',
          name: 'Shared wallet',
          accountIndex: 0,
          blockchainId: 'peercoin',
          networkId: 'mainnet',
          derivationState: active
              ? WalletDerivationState.ready
              : WalletDerivationState.pending,
          keySource: WalletKeySource.roast,
          sourceId: 'setup',
          keyId: 'setup:generation:1',
          derivationPath: active ? 'R/0/6/0/0/0/0' : null,
          address: active ? 'pc1pshared' : null,
          createdAt: DateTime.utc(2026),
        ),
      ],
      nextAccountIndex: 0,
      roastSetups: [_setup(role, active: active)],
      activities: activities,
    );
  return WalletController(
    repository,
    roastRuntime: runtime,
    roastKeyService: keyService ?? _FakeRoastKeyService(),
    roastSigningOperations: operationRepository,
    networkServiceFactory: electrumx == null ? null : (_) async => electrumx,
    onRoastActionRequired: onRoastActionRequired,
  );
}

RoastSetup _setup(RoastSetupRole role, {bool active = false}) => RoastSetup(
  id: 'setup',
  groupId: 'group',
  name: 'Family',
  role: role,
  status: active ? RoastSetupStatus.active : RoastSetupStatus.ready,
  threshold: 2,
  participantCount: 2,
  blockchainId: 'peercoin',
  networkId: 'mainnet',
  localCardId: role == RoastSetupRole.host ? 'host-card' : 'member-card',
  localParticipantPrivateKeyHex: '11' * 32,
  participants: [
    RoastParticipant(
      cardId: 'host-card',
      name: 'Host',
      identifierHex: '01',
      publicKeyHex: '02${'22' * 32}',
    ),
    RoastParticipant(
      cardId: 'member-card',
      name: 'Member',
      identifierHex: '02',
      publicKeyHex: '03${'33' * 32}',
    ),
  ],
  keyName: 'setup:generation:1',
  createdAt: DateTime.utc(2026),
  hostParticipantId: '01',
  coordinatorId: 'coordinator',
  groupFingerprintHex: 'fingerprint',
  groupKeyHex: active ? 'expected-key' : null,
);

Future<void> _flushEvents() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

RoastSigningRequest _signingRequest(
  String idHex, {
  String status = 'waiting',
  String stage = 'collecting',
  int threshold = 2,
  List<String> contributingParticipants = const ['01'],
  DateTime? expiry,
}) => RoastSigningRequest(
  idHex: idHex,
  proposalHex: 'dd',
  creator: '01',
  expiry: expiry ?? DateTime.now().add(const Duration(minutes: 5)),
  kind: RoastSigningRequestKind.transaction,
  hasTransactionMetadata: true,
  usesSupportedSighash: true,
  usesExpectedTaprootTweak: true,
  usesUntweakedKey: false,
  status: status,
  progress: RoastSigningProgress(
    threshold: threshold,
    contributingParticipants: contributingParticipants,
    stage: stage,
  ),
  inputSats: 2000000,
  transactionInputCount: 1,
  signedInputIndexes: const [0],
  previousOutputScripts: const ['expected-script'],
  inputOutpoints: const ['funding:0'],
  outputs: [
    RoastSigningOutput(valueSats: 1000000, scriptHex: 'destination-script'),
  ],
  masterGroupKeys: const ['expected-key'],
  derivationPaths: const [
    [0, 6, 0, 0, 0, 0],
  ],
  message: 'Quarterly hosting bill',
);

RoastSigningRequest _messageSigningRequest(
  String idHex, {
  String creator = '01',
  String status = 'waiting',
  String stage = 'collecting',
  int threshold = 2,
  List<String> contributingParticipants = const ['01'],
}) => RoastSigningRequest(
  idHex: idHex,
  proposalHex: 'ee',
  creator: creator,
  expiry: DateTime.now().add(const Duration(minutes: 5)),
  kind: RoastSigningRequestKind.message,
  hasTransactionMetadata: false,
  usesSupportedSighash: false,
  usesExpectedTaprootTweak: false,
  usesUntweakedKey: true,
  status: status,
  progress: RoastSigningProgress(
    threshold: threshold,
    contributingParticipants: contributingParticipants,
    stage: stage,
  ),
  inputSats: 0,
  transactionInputCount: 0,
  signedInputIndexes: const [],
  previousOutputScripts: const [],
  inputOutpoints: const [],
  outputs: const [],
  masterGroupKeys: const ['expected-key'],
  derivationPaths: const [[]],
  message: 'Confirm the release text.',
  signedMessageText: 'Deploy release 1.0',
);

final class _FakeRoastKeyService extends RoastKeyService {
  bool failNextDerivation = false;

  @override
  RoastDerivedAddress deriveAddress({
    required String groupKeyHex,
    required int threshold,
    required network,
    required int accountIndex,
    String? pathLabel,
  }) {
    if (failNextDerivation) {
      failNextDerivation = false;
      throw StateError('injected derivation failure');
    }
    return RoastDerivedAddress(
      path: const [0, 6, 0, 0, 0, 0],
      pathLabel: 'R/0/6/0/0/0/0',
      address: 'pc1pshared',
      internalKeyHex: 'internal-key',
    );
  }

  @override
  String scriptHexForAddress(network, String address) => 'expected-script';

  @override
  String addressForScript(network, String scriptHex) => 'pc1pdestination';
}

final class _RoomRoastKeyService(final List<RoastParticipant> roster)
    extends RoastKeyService {
  @override
  String participantCardFromPublicKey({
    required String name,
    required String publicKeyHex,
  }) => 'participant-card';

  @override
  List<RoastParticipant> finalizeRoster(setup, encodedCards) => roster;

  @override
  String groupFingerprint(setup) => 'fingerprint';
}

final class _EnrollmentRoastKeyService extends RoastKeyService {
  var _nextId = 0;

  @override
  RoastParticipantMaterial generateParticipant() => RoastParticipantMaterial(
    cardId: 'local-card',
    privateKeyHex: '11' * 32,
    publicKeyHex: '02${'22' * 32}',
  );

  @override
  String newSetupId() => 'enrollment-${_nextId++}';

  @override
  RoastInvitation applyInvitation(RoastSetup draft, String encodedInvitation) =>
      RoastInvitation(setup: draft, roomInvite: encodedInvitation);
}

final class _FixedRoastKeyService(final RoastDerivedAddress address)
    extends RoastKeyService {
  @override
  RoastDerivedAddress deriveAddress({
    required String groupKeyHex,
    required int threshold,
    required network,
    required int accountIndex,
    String? pathLabel,
  }) => address;
}

class _FakeRoastRuntime implements RoastRuntime {
  final StreamController<RoastRuntimeEvent> _events =
      StreamController<RoastRuntimeEvent>.broadcast();
  final List<String> requestedDkgSetupIds = [];
  final List<String> rejectedDkgProposalHexes = [];
  final List<String> acceptedSigningRequestIds = [];
  final List<String> rejectedSigningRequestIds = [];
  final List<String> deletedSetupIds = [];
  String? snapshotGroupKey;
  bool failSigningRequests = false;
  RoastRuntimeOperation signingFailureOperation =
      RoastRuntimeOperation.signatures;
  bool signingFailureInterrupted = false;
  String signingFailureMessage = 'Signing request failed.';
  RoastRoomCreation? roomCreation;
  RoastSetup? createdRoomSetup;
  NewDkgDetails? lastApprovedDkgDetails;
  GroupTransitionKeyPlan? lastTransitionKeyPlan;
  RoastRuntimeSnapshot? startSnapshot;
  void Function()? afterRoomPrepared;
  Object? joinRoomError;
  Object? signatureRequestError;
  int joinRoomCalls = 0;
  String? messageText;
  String? messageNote;
  Duration? transactionRequestTimeout;
  Duration? messageRequestTimeout;
  Completer<void>? signatureRequestGate;

  @override
  Stream<RoastRuntimeEvent> get events => _events.stream;

  void emit(RoastRuntimeEvent event) => _events.add(event);

  @override
  Future<RoastRuntimeSnapshot> startSetup(RoastSetup setup) async =>
      startSnapshot ??
      RoastRuntimeSnapshot(
        connected: true,
        signerRunning: true,
        onlineParticipantIds: [setup.role == RoastSetupRole.host ? '02' : '01'],
        coordinatorId: 'coordinator',
        coordinatorRelayUrls: const [],
        coordinatorIpAddrs: const [],
        groupKeyHex: snapshotGroupKey,
        pendingDkgProposalHex: null,
      );

  @override
  Future<RoastRoomCreation> createRoom(
    setup, {
    Future<void> Function(RoastRoomCreation room)? beforeInvitations,
  }) async {
    createdRoomSetup = setup;
    final room = roomCreation ?? (throw UnimplementedError());
    await beforeInvitations?.call(
      RoastRoomCreation(
        invites: const [],
        coordinatorEndpointId: room.coordinatorEndpointId,
        coordinatorId: room.coordinatorId,
        coordinatorRelayUrls: room.coordinatorRelayUrls,
        coordinatorIpAddrs: room.coordinatorIpAddrs,
      ),
    );
    afterRoomPrepared?.call();
    return room;
  }

  @override
  Future<RoastRuntimeSnapshot> joinRoom(setup, String encodedInvite) async {
    joinRoomCalls++;
    final error = joinRoomError;
    if (error != null) throw error;
    throw UnimplementedError();
  }

  @override
  Future<void> requestDkg(
    RoastSetup setup, {
    NewDkgDetails? approvedDetails,
    GroupTransitionKeyPlan? transitionKeyPlan,
  }) async {
    requestedDkgSetupIds.add(setup.id);
    lastApprovedDkgDetails = approvedDetails;
    lastTransitionKeyPlan = transitionKeyPlan;
  }

  @override
  Future<void> acceptDkg(String setupId, String proposalHex) async {}

  @override
  Future<void> rejectDkg(String setupId, String proposalHex) async {
    rejectedDkgProposalHexes.add(proposalHex);
  }

  @override
  RoastSigningProposal createTransactionSigningProposal(
    setup,
    transaction,
    List<int> derivationPath, {
    String message = '',
    Duration timeout = defaultRoastSigningRequestTimeout,
  }) {
    transactionRequestTimeout = timeout;
    return RoastSigningProposal(
      idHex: 'aa' * 16,
      proposalHex: 'bb',
      expiry: DateTime.now().add(timeout),
    );
  }

  @override
  RoastSigningProposal createMessageSigningProposal(
    setup,
    String text, {
    String message = '',
    Duration timeout = defaultRoastSigningRequestTimeout,
  }) {
    messageText = text;
    messageNote = message;
    messageRequestTimeout = timeout;
    return RoastSigningProposal(
      idHex: 'cc' * 16,
      proposalHex: 'dd',
      expiry: DateTime.now().add(timeout),
    );
  }

  @override
  Future<void> requestSignatures(setup, RoastSigningProposal proposal) async {
    if (signatureRequestError case final error?) throw error;
    if (failSigningRequests) {
      _events.add(
        RoastRuntimeFailureEvent(
          setup.id,
          message: signingFailureMessage,
          interrupted: signingFailureInterrupted,
          operation: signingFailureOperation,
        ),
      );
    }
    await signatureRequestGate?.future;
  }

  @override
  Future<void> acceptSignatures(String setupId, String requestIdHex) async {
    acceptedSigningRequestIds.add(requestIdHex);
  }

  @override
  Future<void> rejectSignatures(String setupId, String requestIdHex) async {
    rejectedSigningRequestIds.add(requestIdHex);
  }

  @override
  Future<void> stopSetup(String setupId) async {}

  @override
  Future<void> deleteSetup(String setupId) async {
    deletedSetupIds.add(setupId);
  }

  @override
  Future<void> close() => _events.close();
}

final class _CoordinatorRoastRuntime extends _FakeRoastRuntime
    implements RoastCoordinatorRuntime {
  int switchCalls = 0;
  int addressUpdateCalls = 0;
  final List<String?> startedCoordinatorIds = [];
  RoastCoordinatorSwitchFailure? switchFailure;
  Completer<void>? switchGate;
  bool failBeforePersistenceSettles = false;
  Object? startFailure;

  @override
  Future<RoastRuntimeSnapshot> startSetup(RoastSetup setup) async {
    startedCoordinatorIds.add(setup.coordinatorId);
    final error = startFailure;
    if (error != null) throw error;
    return _snapshotFor(setup.coordinatorId, groupKeyHex: setup.groupKeyHex);
  }

  @override
  Future<RoastRuntimeSnapshot> switchCoordinator(
    RoastSetup setup, {
    required RoastCoordinatorAddress newCoordinator,
    required Future<void> Function(RoastCoordinatorAddress address) persist,
  }) async {
    switchCalls++;
    final failure = switchFailure;
    if (failure?.kind ==
        RoastCoordinatorSwitchFailureKind.pendingSigningOperations) {
      throw failure!;
    }
    final persistence = persist(newCoordinator);
    if (failBeforePersistenceSettles) {
      unawaited(persistence);
      throw RoastCoordinatorSwitchFailure(
        kind: RoastCoordinatorSwitchFailureKind.persistence,
        code: 'host_timeout',
        cause: TimeoutException('host persistence timed out'),
      );
    }
    try {
      await persistence;
    } catch (error) {
      throw RoastCoordinatorSwitchFailure(
        kind: RoastCoordinatorSwitchFailureKind.persistence,
        code: 'host_state',
        cause: error,
      );
    }
    await switchGate?.future;
    if (failure != null) throw failure;
    return _snapshotFor(
      newCoordinator.id,
      groupKeyHex: setup.groupKeyHex,
      relayUrls: newCoordinator.relayUrls,
      ipAddrs: newCoordinator.ipAddrs,
    );
  }

  @override
  Future<RoastRuntimeSnapshot> updateCoordinatorAddress(
    RoastSetup setup,
    RoastCoordinatorAddress coordinator,
  ) async {
    addressUpdateCalls++;
    return _snapshotFor(
      coordinator.id,
      groupKeyHex: setup.groupKeyHex,
      relayUrls: coordinator.relayUrls,
      ipAddrs: coordinator.ipAddrs,
    );
  }

  static RoastRuntimeSnapshot _snapshotFor(
    String? coordinatorId, {
    required String? groupKeyHex,
    List<String> relayUrls = const [],
    List<String> ipAddrs = const [],
  }) => RoastRuntimeSnapshot(
    connected: true,
    signerRunning: true,
    onlineParticipantIds: const ['01', '02'],
    coordinatorId: coordinatorId,
    coordinatorRelayUrls: relayUrls,
    coordinatorIpAddrs: ipAddrs,
    groupKeyHex: groupKeyHex,
    pendingDkgProposalHex: null,
  );
}

enum _CoordinatorSaveFailure { none, beforeCommit, afterCommit }

final class _CoordinatorRepository extends MemoryWalletRepository {
  _CoordinatorSaveFailure failure = _CoordinatorSaveFailure.none;
  Completer<void>? coordinatorWriteGate;
  Completer<void>? saveStarted;
  Completer<void>? saveGate;
  int saveCount = 0;

  @override
  Future<void> save(WalletVault vault) async {
    saveCount++;
    final started = saveStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
      await saveGate!.future;
    }
    final previousId = value?.roastSetups.singleOrNull?.coordinatorId;
    final nextId = vault.roastSetups.singleOrNull?.coordinatorId;
    final coordinatorChanged = previousId != nextId;
    if (!coordinatorChanged) {
      value = vault;
      return;
    }
    await coordinatorWriteGate?.future;
    if (failure == _CoordinatorSaveFailure.beforeCommit) {
      throw StateError('storage failed before commit');
    }
    value = vault;
    if (failure == _CoordinatorSaveFailure.afterCommit) {
      throw StateError('storage failed after commit');
    }
  }
}

final class _FakeElectrumxService implements ElectrumxService {
  final List<String> broadcasts = [];
  final StreamController<PeercoinElectrumxUtxoSnapshot> _snapshots =
      StreamController<PeercoinElectrumxUtxoSnapshot>.broadcast();

  void emit(String address, List<ElectrumxUtxo> utxos) {
    _snapshots.add(
      PeercoinElectrumxUtxoSnapshot(address: address, utxos: utxos),
    );
  }

  @override
  Future<String> broadcastTransaction(String rawTransactionHex) async {
    broadcasts.add(rawTransactionHex);
    return 'server-txid';
  }

  @override
  Future<List<ElectrumxUtxo>> fetchUtxos(String address) async => const [];

  @override
  Stream<PeercoinElectrumxUtxoSnapshot> watchUtxosForAddresses(
    Iterable<String> addresses,
  ) => _snapshots.stream.where(
    (snapshot) => addresses.contains(snapshot.address),
  );

  @override
  Future<void> close() => _snapshots.close();
}

final class _SigningRoastRuntime(
  final RoastSigningOperationRepository operations,
  final ECPrivateKey signingKey,
) implements RoastRuntime {
  final StreamController<RoastRuntimeEvent> _events =
      StreamController<RoastRuntimeEvent>.broadcast();
  ThresholdWalletTransaction? _transaction;
  List<int>? _derivationPath;
  String? signingMessage;
  Duration? signingRequestTimeout;

  @override
  Stream<RoastRuntimeEvent> get events => _events.stream;

  @override
  Future<RoastRuntimeSnapshot> startSetup(RoastSetup setup) async =>
      RoastRuntimeSnapshot(
        connected: true,
        signerRunning: true,
        onlineParticipantIds: const [],
        coordinatorId: 'coordinator',
        coordinatorRelayUrls: const [],
        coordinatorIpAddrs: const [],
        groupKeyHex: signingKey.pubkey.hex,
        pendingDkgProposalHex: null,
      );

  @override
  Future<RoastRoomCreation> createRoom(
    setup, {
    Future<void> Function(RoastRoomCreation room)? beforeInvitations,
  }) => throw UnimplementedError();

  @override
  Future<RoastRuntimeSnapshot> joinRoom(setup, String encodedInvite) =>
      throw UnimplementedError();

  @override
  RoastSigningProposal createTransactionSigningProposal(
    RoastSetup setup,
    ThresholdWalletTransaction transaction,
    List<int> derivationPath, {
    String message = '',
    Duration timeout = defaultRoastSigningRequestTimeout,
  }) {
    _transaction = transaction;
    _derivationPath = List.unmodifiable(derivationPath);
    signingMessage = message;
    signingRequestTimeout = timeout;
    return RoastSigningProposal(
      idHex: 'aa' * 16,
      proposalHex: 'bb',
      expiry: DateTime.now().add(timeout),
    );
  }

  @override
  RoastSigningProposal createMessageSigningProposal(
    RoastSetup setup,
    String text, {
    String message = '',
    Duration timeout = defaultRoastSigningRequestTimeout,
  }) => throw UnimplementedError();

  @override
  Future<void> requestSignatures(
    RoastSetup setup,
    RoastSigningProposal proposal,
  ) async {
    final transaction = _transaction!;
    var privateKey = signingKey;
    var groupKey = ECCompressedPublicKey.fromPubkey(signingKey.pubkey);
    var hdInfo = HDKeyInfo.master;
    for (final index in _derivationPath!) {
      final (tweak, nextInfo) = hdInfo.deriveTweakAndInfo(groupKey, index);
      privateKey = privateKey.tweak(tweak)!;
      groupKey = groupKey.tweak(tweak)!;
      hdInfo = nextInfo;
    }
    final tweaked = Taproot(internalKey: groupKey).tweakPrivateKey(privateKey);
    final signatures = [
      for (final hash in transaction.signatureHashes)
        SchnorrSignature.sign(tweaked, hash).data,
    ];
    await operations.recordSigningResult(
      '${setup.id}:${proposal.idHex}',
      proposalHex: proposal.proposalHex,
      signaturesHex: [
        for (final signature in signatures) bytesToHex(signature),
      ],
    );
    _events.add(
      RoastRuntimeSigningResultEvent(
        setup.id,
        requestIdHex: proposal.idHex,
        proposalHex: proposal.proposalHex,
        signatures: signatures,
        creator: setup.localParticipant.identifierHex,
      ),
    );
  }

  @override
  Future<void> requestDkg(
    RoastSetup setup, {
    NewDkgDetails? approvedDetails,
    GroupTransitionKeyPlan? transitionKeyPlan,
  }) async {}

  @override
  Future<void> acceptDkg(String setupId, String proposalHex) async {}

  @override
  Future<void> rejectDkg(String setupId, String proposalHex) async {}

  @override
  Future<void> acceptSignatures(String setupId, String requestIdHex) async {}

  @override
  Future<void> rejectSignatures(String setupId, String requestIdHex) async {}

  @override
  Future<void> stopSetup(String setupId) async {}

  @override
  Future<void> deleteSetup(String setupId) async {}

  @override
  Future<void> close() => _events.close();
}
