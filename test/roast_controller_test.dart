import 'dart:async';

import 'package:coinlib/coinlib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart'
    show
        Expiry,
        HDKeyInfo,
        MessageSignatureMetadata,
        NewDkgDetails,
        SignaturesRequestDetails;
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/models/electrumx_utxo.dart';
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
  setUpAll(loadCoinlib);

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
    final runtime = RoastRuntimeManager(RoastPersistenceFactory());
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
    );
    final messageDetails = SignaturesRequestDetails.fromHex(
      messageProposal.proposalHex,
    );
    final messageMetadata = messageDetails.metadata as MessageSignatureMetadata;
    expect(messageProposal.expiry, messageDetails.expiry.time);
    expect(messageProposal.idHex, bytesToHex(messageDetails.id.toBytes()));
    expect(
      messageMetadata.payload.text,
      'Exact message\nwith preserved whitespace ',
    );
    expect(messageDetails.message, 'Please verify the release note.');
    expect(messageDetails.requiredSigs.single.groupKey, signingKey.pubkey);
    expect(messageDetails.requiredSigs.single.hdDerivation, isEmpty);
    expect(messageDetails.requiredSigs.single.signDetails.mastHash, isNull);
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
            onlineParticipantIds: const [],
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
    controller.dispose();
  });

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

    final rejected = _signingRequest('bb' * 16);
    runtime.emit(RoastRuntimeSigningRequestEvent('setup', request: rejected));
    await _flushEvents();
    expect(notificationCount, 2);
    await controller.rejectRoastSigningRequest(
      controller.roastSigningRequests.single,
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
      ],
    );

    controller.dispose();
  });

  test('signing failure completes the send without disabling setup', () async {
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
      ..failSigningRequests = true;
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
      controller.sendTransaction(preview),
      throwsA(isA<WalletTransactionRejected>()),
    );

    expect(controller.roastSetups.single.status, RoastSetupStatus.active);
    final failedOperation = (await operations.loadSigningOperations()).single;
    expect(failedOperation.state, RoastSigningOperationState.rejected);
    expect(failedOperation.reservesUtxos, isFalse);
    expect(
      failedOperation
          .copyWith(state: RoastSigningOperationState.interrupted)
          .reservesUtxos,
      isFalse,
      reason: 'legacy rejected attempts must release their UTXOs too',
    );
    controller.dispose();
  });

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
  onlineParticipantIds: const [],
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

RoastSigningRequest _signingRequest(String idHex) => RoastSigningRequest(
  idHex: idHex,
  proposalHex: 'dd',
  creator: '01',
  expiry: DateTime.now().add(const Duration(minutes: 5)),
  kind: RoastSigningRequestKind.transaction,
  hasTransactionMetadata: true,
  usesSupportedSighash: true,
  usesExpectedTaprootTweak: true,
  usesUntweakedKey: false,
  status: 'waiting',
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

RoastSigningRequest _messageSigningRequest(String idHex) => RoastSigningRequest(
  idHex: idHex,
  proposalHex: 'ee',
  creator: '01',
  expiry: DateTime.now().add(const Duration(minutes: 5)),
  kind: RoastSigningRequestKind.message,
  hasTransactionMetadata: false,
  usesSupportedSighash: false,
  usesExpectedTaprootTweak: false,
  usesUntweakedKey: true,
  status: 'waiting',
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

final class _FixedRoastKeyService(final RoastDerivedAddress address)
    extends RoastKeyService {
  @override
  RoastDerivedAddress deriveAddress({
    required String groupKeyHex,
    required int threshold,
    required network,
    required int accountIndex,
  }) => address;
}

final class _FakeRoastRuntime implements RoastRuntime {
  final StreamController<RoastRuntimeEvent> _events =
      StreamController<RoastRuntimeEvent>.broadcast();
  final List<String> requestedDkgSetupIds = [];
  final List<String> rejectedDkgProposalHexes = [];
  final List<String> acceptedSigningRequestIds = [];
  final List<String> rejectedSigningRequestIds = [];
  final List<String> deletedSetupIds = [];
  String? snapshotGroupKey;
  bool failSigningRequests = false;
  RoastRoomCreation? roomCreation;
  RoastSetup? createdRoomSetup;
  RoastRuntimeSnapshot? startSnapshot;
  String? messageText;
  String? messageNote;
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
  Future<RoastRoomCreation> createRoom(setup) async {
    createdRoomSetup = setup;
    return roomCreation ?? (throw UnimplementedError());
  }

  @override
  Future<RoastRuntimeSnapshot> joinRoom(setup, String encodedInvite) =>
      throw UnimplementedError();

  @override
  Future<void> requestDkg(RoastSetup setup) async {
    requestedDkgSetupIds.add(setup.id);
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
  }) => RoastSigningProposal(
    idHex: 'aa' * 16,
    proposalHex: 'bb',
    expiry: DateTime.now().add(const Duration(minutes: 1)),
  );

  @override
  RoastSigningProposal createMessageSigningProposal(
    setup,
    String text, {
    String message = '',
  }) {
    messageText = text;
    messageNote = message;
    return RoastSigningProposal(
      idHex: 'cc' * 16,
      proposalHex: 'dd',
      expiry: DateTime.now().add(const Duration(minutes: 1)),
    );
  }

  @override
  Future<void> requestSignatures(setup, RoastSigningProposal proposal) async {
    if (failSigningRequests) {
      _events.add(
        RoastRuntimeFailureEvent(
          setup.id,
          message: 'Signing request failed.',
          interrupted: false,
          operation: 'signatures',
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
  Future<RoastRoomCreation> createRoom(setup) => throw UnimplementedError();

  @override
  Future<RoastRuntimeSnapshot> joinRoom(setup, String encodedInvite) =>
      throw UnimplementedError();

  @override
  RoastSigningProposal createTransactionSigningProposal(
    RoastSetup setup,
    ThresholdWalletTransaction transaction,
    List<int> derivationPath, {
    String message = '',
  }) {
    _transaction = transaction;
    _derivationPath = List.unmodifiable(derivationPath);
    signingMessage = message;
    return RoastSigningProposal(
      idHex: 'aa' * 16,
      proposalHex: 'bb',
      expiry: DateTime.now().add(const Duration(minutes: 1)),
    );
  }

  @override
  RoastSigningProposal createMessageSigningProposal(
    RoastSetup setup,
    String text, {
    String message = '',
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
  Future<void> requestDkg(RoastSetup setup) async {}

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
