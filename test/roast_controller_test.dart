import 'dart:async';

import 'package:coinlib/coinlib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/models/electrumx_utxo.dart';
import 'package:sygnature_ng/models/roast_setup.dart';
import 'package:sygnature_ng/models/roast_signing_operation.dart';
import 'package:sygnature_ng/models/wallet_account.dart';
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
        description: 'Sygnature Family shared wallet',
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
        description: 'Sygnature Family shared wallet',
        rejected: false,
      ),
    );
    await _flushEvents();

    final setup = controller.roastSetups.single;
    expect(setup.status, RoastSetupStatus.awaitingDkgApproval);
    expect(setup.pendingDkgProposalHex, 'valid-proposal');
    expect(setup.pendingDkgThreshold, 2);

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

  test('persists signatures and signed bytes before broadcasting', () async {
    final signingKey = ECPrivateKey.fromHex('${'0' * 63}1');
    final destinationKey = ECPrivateKey.fromHex('${'0' * 63}2');
    final taproot = Taproot(internalKey: signingKey.pubkey);
    final sourceAddress = P2TRAddress.fromTaproot(
      taproot,
      hrp: Network.mainnet.bech32Hrp,
    ).toString();
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
      roastKeyService: _FixedRoastKeyService(
        RoastDerivedAddress(
          path: const [0, 6, 0, 0, 0, 0],
          pathLabel: 'R/0/6/0/0/0/0',
          address: sourceAddress,
          internalKeyHex: signingKey.pubkey.hex,
        ),
      ),
      networkServiceFactory: (_) async => electrumx,
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
    final result = await controller.sendTransaction(preview);

    final stored = (await operations.loadSigningOperations()).single;
    expect(stored.signaturesHex, isNotEmpty);
    expect(stored.rawTransactionHex, electrumx.broadcasts.single);
    expect(stored.transactionId, result.transactionId);
    expect(stored.state, RoastSigningOperationState.broadcasted);

    controller.dispose();
  });
}

WalletController _controller({
  required _FakeRoastRuntime runtime,
  RoastSetupRole role = RoastSetupRole.member,
  _FakeRoastKeyService? keyService,
  RoastSigningOperationRepository? operationRepository,
  _FakeElectrumxService? electrumx,
  bool active = false,
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
  String? snapshotGroupKey;

  @override
  Stream<RoastRuntimeEvent> get events => _events.stream;

  void emit(RoastRuntimeEvent event) => _events.add(event);

  @override
  Future<RoastRuntimeSnapshot> startSetup(RoastSetup setup) async =>
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
    List<int> derivationPath,
  ) => throw UnimplementedError();

  @override
  Future<void> requestTransactionSignatures(
    setup,
    RoastSigningProposal proposal,
  ) => throw UnimplementedError();

  @override
  Future<void> acceptSignatures(String setupId, String requestIdHex) =>
      throw UnimplementedError();

  @override
  Future<void> rejectSignatures(String setupId, String requestIdHex) =>
      throw UnimplementedError();

  @override
  Future<void> stopSetup(String setupId) async {}

  @override
  Future<void> close() => _events.close();
}

final class _FakeElectrumxService implements ElectrumxService {
  final List<String> broadcasts = [];

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
  ) => const Stream.empty();

  @override
  Future<void> close() async {}
}

final class _SigningRoastRuntime(
  final RoastSigningOperationRepository operations,
  final ECPrivateKey signingKey,
) implements RoastRuntime {
  final StreamController<RoastRuntimeEvent> _events =
      StreamController<RoastRuntimeEvent>.broadcast();
  ThresholdWalletTransaction? _transaction;

  @override
  Stream<RoastRuntimeEvent> get events => _events.stream;

  @override
  Future<RoastRuntimeSnapshot> startSetup(RoastSetup setup) async =>
      RoastRuntimeSnapshot(
        connected: true,
        signerRunning: true,
        onlineParticipantIds: const ['02'],
        coordinatorId: 'coordinator',
        coordinatorRelayUrls: const [],
        coordinatorIpAddrs: const [],
        groupKeyHex: signingKey.pubkey.hex,
        pendingDkgProposalHex: null,
      );

  @override
  RoastSigningProposal createTransactionSigningProposal(
    RoastSetup setup,
    ThresholdWalletTransaction transaction,
    List<int> derivationPath,
  ) {
    _transaction = transaction;
    return RoastSigningProposal(
      idHex: 'aa' * 16,
      proposalHex: 'bb',
      expiry: DateTime.now().add(const Duration(minutes: 1)),
    );
  }

  @override
  Future<void> requestTransactionSignatures(
    RoastSetup setup,
    RoastSigningProposal proposal,
  ) async {
    final transaction = _transaction!;
    final tweaked = Taproot(internalKey: signingKey.pubkey)
        .tweakPrivateKey(signingKey);
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
  Future<void> close() => _events.close();
}
