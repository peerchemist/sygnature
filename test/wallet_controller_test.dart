import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/models/electrumx_utxo.dart';
import 'package:sygnature_ng/models/mnemonic_seed.dart';
import 'package:sygnature_ng/models/wallet_account.dart';
import 'package:sygnature_ng/models/wallet_activity.dart';
import 'package:sygnature_ng/models/wallet_network.dart';
import 'package:sygnature_ng/models/wallet_transaction.dart';
import 'package:sygnature_ng/models/wallet_vault.dart';
import 'package:sygnature_ng/services/electrumx_service.dart';
import 'package:sygnature_ng/services/peercoin_network_service.dart';
import 'package:sygnature_ng/services/wallet_key_service.dart';
import 'package:sygnature_ng/services/wallet_transaction_service.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';

void main() {
  test('preserves account edits overlapping transaction activity', () async {
    final repository = _ControlledWalletRepository();
    final controller = WalletController(
      repository,
      keyService: _FakeWalletKeyService(),
      transactionService: _FakeWalletTransactionService(),
      networkServiceFactory: (_) async => _FakeElectrumxService(),
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);
    final preview = controller.prepareSend(
      const WalletSendRequest(
        destinationAddress: 'pc1pdestination',
        amountSats: 1000000,
        feeRateSatsPerKb: 10000,
      ),
    );
    repository.saveStarted = Completer<void>();
    repository.saveGate = Completer<void>();
    final renaming = controller.renameAccount(
      controller.accounts.single.id,
      'Savings',
    );
    await repository.saveStarted!.future;
    final sending = controller.sendTransaction(preview);
    await Future<void>.delayed(Duration.zero);
    repository.saveGate!.complete();
    await renaming;
    await sending;

    expect(controller.accounts.single.name, 'Savings');
    expect(repository.value!.accounts.single.name, 'Savings');
    expect(
      repository.value!.activities.map((activity) => activity.type),
      containsAll([
        WalletActivityType.transactionSigned,
        WalletActivityType.transactionBroadcast,
      ]),
    );
    expect(controller.vault!.activities, repository.value!.activities);
    controller.dispose();
  });

  test('continues vault mutations after a failed save', () async {
    final repository = _ControlledWalletRepository();
    final controller = WalletController(
      repository,
      keyService: _FakeWalletKeyService(),
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);
    final accountId = controller.accounts.single.id;
    repository.saveError = StateError('storage unavailable');
    await expectLater(
      controller.renameAccount(accountId, 'Unsaved'),
      throwsStateError,
    );
    expect(controller.accounts.single.name, 'Main wallet');
    expect(repository.value!.accounts.single.name, 'Main wallet');

    await controller.renameAccount(accountId, 'Saved');
    expect(controller.accounts.single.name, 'Saved');
    expect(repository.value!.accounts.single.name, 'Saved');
    controller.dispose();
  });

  test('reloads an uncertain write before applying another mutation', () async {
    final repository = _ControlledWalletRepository();
    final controller = WalletController(
      repository,
      keyService: _FakeWalletKeyService(),
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);
    final accountId = controller.accounts.single.id;
    repository.commitBeforeError = true;
    repository.saveError = StateError('write outcome unknown');
    await expectLater(
      controller.renameAccount(accountId, 'Committed'),
      throwsStateError,
    );
    await controller.addAccount('Second', network: PeercoinNetworks.mainnet);
    expect(controller.accounts.map((account) => account.name), [
      'Committed',
      'Second',
    ]);
    expect(repository.value!.accounts.map((account) => account.name), [
      'Committed',
      'Second',
    ]);
    controller.dispose();
  });

  test('stores the recovery phrase before a network is selected', () async {
    final repository = MemoryWalletRepository();
    final controller = WalletController(
      repository,
      keyService: _FakeWalletKeyService(),
    );
    await controller.load();

    await controller.createVault(_mnemonic);

    expect(controller.hasWallet, isTrue);
    expect(controller.accounts, isEmpty);
    expect(controller.vault?.mnemonic, _mnemonic.phrase);
    expect(controller.vault?.nextAccountIndex, 0);

    await controller.addAccount(
      'Main wallet',
      network: PeercoinNetworks.testnet,
    );
    expect(controller.accounts.single.networkId, 'testnet');
    expect(controller.accounts.single.accountIndex, 0);
    expect(controller.vault?.nextAccountIndex, 1);
  });

  test('adds and synchronizes a watch-only Taproot address', () async {
    const address =
        'pc1pmfr3p9j00pfxjh0zmgp99y8zftmd3s5pmedqhyptwy6lm87hf5ssntx2jm';
    final repository = MemoryWalletRepository();
    final electrumx = _FakeElectrumxService();
    final controller = WalletController(
      repository,
      networkServiceFactory: (_) async => electrumx,
    );
    await controller.load();

    await controller.addWatchOnlyAccount(
      'Treasury observer',
      network: PeercoinNetworks.mainnet,
      address: '  $address  ',
    );

    final account = controller.accounts.single;
    expect(account.name, 'Treasury observer');
    expect(account.keySource, WalletKeySource.watchOnly);
    expect(account.derivationState, WalletDerivationState.watchOnly);
    expect(account.address, address);
    expect(account.derivationPath, isNull);
    expect(account.privateKeyHex, isNull);
    expect(controller.vault?.mnemonic, isNull);
    expect(controller.vault?.nextAccountIndex, 0);
    expect(electrumx.watchedAddresses.single, {address});

    await expectLater(
      controller.addWatchOnlyAccount(
        'Duplicate',
        network: PeercoinNetworks.mainnet,
        address: address,
      ),
      throwsA(
        isA<WatchOnlyWalletFailure>().having(
          (error) => error.message,
          'message',
          'This address is already in the wallet.',
        ),
      ),
    );
    await expectLater(
      controller.addWatchOnlyAccount(
        'Wrong network',
        network: PeercoinNetworks.testnet,
        address: address,
      ),
      throwsA(isA<WatchOnlyWalletFailure>()),
    );

    controller.dispose();
  });

  test('persists mnemonic and automatically derives every account', () async {
    final repository = MemoryWalletRepository();
    final controller = WalletController(
      repository,
      keyService: _FakeWalletKeyService(),
    );
    await controller.load();

    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);
    await controller.addAccount('Savings', network: PeercoinNetworks.testnet);
    await controller.selectAccount(0);

    expect(repository.value?.selectedAccountId, controller.accounts.first.id);

    final restored = WalletController(
      repository,
      keyService: _FakeWalletKeyService(),
    );
    await restored.load();
    expect(restored.accounts, hasLength(2));
    expect(restored.accounts[1].name, 'Savings');
    expect(restored.accounts[1].address, 'tpc1paccount1');
    expect(restored.accounts[1].privateKeyHex, 'private-key-1');
    expect(restored.accounts[1].derivationPath, "m/86'/1'/1'/0/0");
    expect(restored.vault?.mnemonic, _mnemonic.phrase);
    expect(restored.vault?.languageId, 'english');
    expect(restored.vault?.mnemonicWordCount, 12);
    expect(restored.accounts[0].networkId, 'mainnet');
    expect(restored.accounts[1].networkId, 'testnet');
    expect(restored.selectedAccount?.name, 'Main wallet');
  });

  test('streams ElectrumX UTXOs into account balance state', () async {
    final electrumx = _FakeElectrumxService();
    var receivedSoundCount = 0;
    final controller = WalletController(
      MemoryWalletRepository(),
      keyService: _FakeWalletKeyService(),
      networkServiceFactory: (_) async => electrumx,
      onCoinsReceived: () => receivedSoundCount++,
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);

    final account = controller.accounts.single;
    expect(controller.syncStatusFor(account), AccountSyncStatus.syncing);
    expect(electrumx.watchedAddresses.single, {'pc1paccount0'});

    electrumx.snapshots.add(
      const PeercoinElectrumxUtxoSnapshot(
        address: 'pc1paccount0',
        utxos: [
          ElectrumxUtxo(
            address: 'pc1paccount0',
            txHash: 'first',
            txPos: 0,
            height: 10,
            value: 1250000,
          ),
          ElectrumxUtxo(
            address: 'pc1paccount0',
            txHash: 'second',
            txPos: 1,
            height: 0,
            value: 500000,
          ),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.balanceSatsFor(account), 1750000);
    expect(controller.confirmedBalanceSatsFor(account), 1250000);
    expect(controller.pendingBalanceSatsFor(account), 500000);
    expect(controller.spendableUtxosFor(account), hasLength(1));
    expect(controller.utxosFor(account), hasLength(2));
    expect(controller.syncStatusFor(account), AccountSyncStatus.synced);
    expect(receivedSoundCount, 0);

    final receivedSnapshot = PeercoinElectrumxUtxoSnapshot(
      address: 'pc1paccount0',
      utxos: [
        ...controller.utxosFor(account),
        const ElectrumxUtxo(
          address: 'pc1paccount0',
          txHash: 'received',
          txPos: 0,
          height: 0,
          value: 250000,
        ),
      ],
    );
    electrumx.snapshots.add(receivedSnapshot);
    await Future<void>.delayed(Duration.zero);

    expect(controller.balanceSatsFor(account), 2000000);
    expect(receivedSoundCount, 1);

    electrumx.snapshots.add(receivedSnapshot);
    await Future<void>.delayed(Duration.zero);
    expect(receivedSoundCount, 1);

    electrumx.snapshots.addError(StateError('offline'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.syncStatusFor(account), AccountSyncStatus.error);

    await controller.refreshBalances();
    expect(controller.syncStatusFor(account), AccountSyncStatus.syncing);
    expect(electrumx.watchedAddresses, hasLength(2));

    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(electrumx.closed, isTrue);
  });

  test('configures services for the selected blockchain network', () async {
    final requestedNetworks = <WalletNetwork>[];
    final repository = MemoryWalletRepository();
    final controller = WalletController(
      repository,
      keyService: _FakeWalletKeyService(),
      networkServiceFactory: (network) async {
        requestedNetworks.add(network);
        return null;
      },
    );
    await controller.load();

    await controller.createWallet(_mnemonic, network: PeercoinNetworks.testnet);

    expect(requestedNetworks.single.storageId, 'peercoin:testnet');
    expect(controller.accounts.single.networkId, 'testnet');
    expect(controller.accounts.single.address, 'tpc1paccount0');

    requestedNetworks.clear();
    final restored = WalletController(
      repository,
      keyService: _FakeWalletKeyService(),
      networkServiceFactory: (network) async {
        requestedNetworks.add(network);
        return null;
      },
    );
    await restored.load();
    expect(requestedNetworks.single.storageId, 'peercoin:testnet');
  });

  test('synchronizes accounts on different networks independently', () async {
    final services = <String, _FakeElectrumxService>{};
    final controller = WalletController(
      MemoryWalletRepository(),
      keyService: _FakeWalletKeyService(),
      networkServiceFactory: (network) async =>
          services.putIfAbsent(network.storageId, _FakeElectrumxService.new),
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);
    await controller.addAccount(
      'Test wallet',
      network: PeercoinNetworks.testnet,
    );

    expect(services['peercoin:mainnet']!.watchedAddresses.last, {
      'pc1paccount0',
    });
    expect(services['peercoin:testnet']!.watchedAddresses.single, {
      'tpc1paccount1',
    });

    controller.dispose();
  });

  test('recreates Electrum services after endpoint settings change', () async {
    final services = <_FakeElectrumxService>[];
    final controller = WalletController(
      MemoryWalletRepository(),
      keyService: _FakeWalletKeyService(),
      networkServiceFactory: (_) async {
        final service = _FakeElectrumxService();
        services.add(service);
        return service;
      },
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);
    final original = services.single;

    await controller.reconnectElectrumx();

    expect(original.closed, isTrue);
    expect(services, hasLength(2));
    expect(services.last.watchedAddresses.single, {'pc1paccount0'});
    controller.dispose();
  });

  test('waits for an active sync cancellation before restarting', () async {
    final cancellationStarted = Completer<void>();
    final releaseCancellation = Completer<void>();
    final electrumx = _DelayedCancellationElectrumxService(
      cancellationStarted,
      releaseCancellation,
    );
    final controller = WalletController(
      MemoryWalletRepository(),
      keyService: _FakeWalletKeyService(),
      networkServiceFactory: (_) async => electrumx,
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);

    final firstRefresh = controller.refreshBalances();
    await cancellationStarted.future;
    final secondRefresh = controller.refreshBalances();
    await Future<void>.delayed(Duration.zero);

    expect(electrumx.watchedAddresses, hasLength(1));

    releaseCancellation.complete();
    await Future.wait([firstRefresh, secondRefresh]);

    expect(electrumx.watchedAddresses, hasLength(2));
    controller.dispose();
  });

  test('deletes an account without reusing its derivation index', () async {
    final repository = MemoryWalletRepository();
    final services = <String, _FakeElectrumxService>{};
    final controller = WalletController(
      repository,
      keyService: _FakeWalletKeyService(),
      networkServiceFactory: (network) async =>
          services.putIfAbsent(network.storageId, _FakeElectrumxService.new),
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);
    await controller.addAccount('Savings', network: PeercoinNetworks.testnet);

    await controller.deleteAccount(controller.accounts.last.id);

    expect(controller.accounts.map((account) => account.name), ['Main wallet']);
    expect(controller.selectedAccount?.name, 'Main wallet');
    expect(repository.value?.selectedAccountId, controller.selectedAccount?.id);
    expect(controller.vault?.nextAccountIndex, 2);
    expect(repository.value?.accounts, hasLength(1));
    expect(services['peercoin:testnet']!.closed, isTrue);
    expect(services['peercoin:mainnet']!.watchedAddresses.last, {
      'pc1paccount0',
    });

    controller.dispose();
  });

  test('archives and restores an account without reusing its index', () async {
    final repository = MemoryWalletRepository();
    final services = <String, List<_FakeElectrumxService>>{};
    final controller = WalletController(
      repository,
      keyService: _FakeWalletKeyService(),
      networkServiceFactory: (network) async {
        final service = _FakeElectrumxService();
        services.putIfAbsent(network.storageId, () => []).add(service);
        return service;
      },
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);
    await controller.addAccount('Savings', network: PeercoinNetworks.testnet);
    final savingsId = controller.selectedAccount!.id;

    await controller.archiveAccount(savingsId);

    expect(controller.accounts.map((account) => account.name), ['Main wallet']);
    expect(controller.archivedAccounts.single.name, 'Savings');
    expect(controller.selectedAccount?.name, 'Main wallet');
    expect(repository.value?.selectedAccountId, controller.selectedAccount?.id);
    expect(repository.value?.accounts, hasLength(2));
    expect(repository.value?.activities, isEmpty);
    expect(repository.value?.nextAccountIndex, 2);
    expect(services['peercoin:testnet']!.single.closed, isTrue);

    await controller.restoreAccount(savingsId);

    expect(controller.accounts.map((account) => account.name), [
      'Main wallet',
      'Savings',
    ]);
    expect(controller.archivedAccounts, isEmpty);
    expect(controller.selectedAccount?.name, 'Savings');
    expect(repository.value?.selectedAccountId, savingsId);
    expect(services['peercoin:testnet'], hasLength(2));
    expect(services['peercoin:testnet']!.last.watchedAddresses.last, {
      'tpc1paccount1',
    });

    await controller.addAccount('Later', network: PeercoinNetworks.mainnet);
    expect(controller.selectedAccount?.accountIndex, 2);
    expect(controller.vault?.nextAccountIndex, 3);
    controller.dispose();
  });

  test('keeps selection stable when another account is archived', () async {
    final controller = WalletController(
      MemoryWalletRepository(),
      keyService: _FakeWalletKeyService(),
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);
    await controller.addAccount('Savings', network: PeercoinNetworks.mainnet);
    final mainId = controller.accounts.first.id;
    final savingsId = controller.accounts.last.id;
    expect(controller.selectedAccount?.id, savingsId);

    await controller.archiveAccount(mainId);

    expect(controller.selectedAccount?.id, savingsId);
    expect(controller.selectedAccountIndex, 0);
  });

  test('renames an account and persists the new name', () async {
    final repository = MemoryWalletRepository();
    final controller = WalletController(
      repository,
      keyService: _FakeWalletKeyService(),
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);

    await controller.renameAccount(controller.accounts.single.id, 'Daily');

    expect(controller.accounts.single.name, 'Daily');
    expect(repository.value?.accounts.single.name, 'Daily');
  });

  test(
    'deleting the last account keeps the vault and recovery phrase',
    () async {
      final repository = MemoryWalletRepository();
      final controller = WalletController(
        repository,
        keyService: _FakeWalletKeyService(),
      );
      await controller.load();
      await controller.createWallet(
        _mnemonic,
        network: PeercoinNetworks.mainnet,
      );

      await controller.deleteAccount(controller.accounts.single.id);

      expect(controller.hasWallet, isTrue);
      expect(controller.accounts, isEmpty);
      expect(repository.value?.mnemonic, _mnemonic.phrase);
      expect(repository.value?.nextAccountIndex, 1);

      await controller.addAccount(
        'Replacement',
        network: PeercoinNetworks.mainnet,
      );
      expect(controller.accounts.single.accountIndex, 1);
    },
  );

  test('previews, signs and broadcasts a send exactly once', () async {
    final electrumx = _FakeElectrumxService();
    final transactions = _FakeWalletTransactionService();
    final controller = WalletController(
      MemoryWalletRepository(),
      keyService: _FakeWalletKeyService(),
      transactionService: transactions,
      networkServiceFactory: (_) async => electrumx,
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);
    electrumx.snapshots.add(
      const PeercoinElectrumxUtxoSnapshot(
        address: 'pc1paccount0',
        utxos: [
          ElectrumxUtxo(
            address: 'pc1paccount0',
            txHash: 'funding',
            txPos: 0,
            height: 10,
            value: 2000000,
          ),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final preview = controller.prepareSend(
      const WalletSendRequest(
        destinationAddress: 'pc1pdestination',
        amountSats: 1000000,
        feeRateSatsPerKb: 10000,
      ),
    );
    final result = await controller.sendTransaction(preview);

    expect(transactions.preparedUtxos, hasLength(1));
    expect(transactions.signedPrivateKey, 'private-key-0');
    expect(electrumx.broadcastedTransactions, ['signed-transaction']);
    expect(result.transactionId, 'local-transaction-id');
    expect(result.serverTransactionId, 'transaction-id');
    expect(
      controller
          .activitiesFor(controller.accounts.single)
          .first
          .transactionStatus,
      WalletTransactionStatus.broadcast,
    );
    expect(
      controller
          .activitiesFor(controller.accounts.single)
          .map((item) => item.type),
      [
        WalletActivityType.transactionBroadcast,
        WalletActivityType.transactionSigned,
      ],
    );

    electrumx.snapshots.add(
      const PeercoinElectrumxUtxoSnapshot(
        address: 'pc1paccount0',
        utxos: [],
        history: [
          ElectrumxTransactionHistoryEntry(
            transactionId: 'local-transaction-id',
            height: 0,
          ),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(
      controller
          .activitiesFor(controller.accounts.single)
          .first
          .transactionStatus,
      WalletTransactionStatus.mempool,
    );

    electrumx.snapshots.add(
      const PeercoinElectrumxUtxoSnapshot(
        address: 'pc1paccount0',
        utxos: [],
        history: [
          ElectrumxTransactionHistoryEntry(
            transactionId: 'local-transaction-id',
            height: 123,
          ),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final confirmed = controller
        .activitiesFor(controller.accounts.single)
        .first;
    expect(confirmed.transactionStatus, WalletTransactionStatus.confirmed);
    expect(confirmed.blockHeight, 123);

    electrumx.snapshots.add(
      const PeercoinElectrumxUtxoSnapshot(
        address: 'pc1paccount0',
        utxos: [],
        history: [
          ElectrumxTransactionHistoryEntry(
            transactionId: 'local-transaction-id',
            height: 0,
          ),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final unconfirmed = controller
        .activitiesFor(controller.accounts.single)
        .first;
    expect(unconfirmed.transactionStatus, WalletTransactionStatus.mempool);
    expect(unconfirmed.blockHeight, isNull);

    electrumx.snapshots.add(
      const PeercoinElectrumxUtxoSnapshot(address: 'pc1paccount0', utxos: []),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final missing = controller.activitiesFor(controller.accounts.single).first;
    expect(missing.transactionStatus, WalletTransactionStatus.broadcast);
    expect(missing.blockHeight, isNull);
    await expectLater(
      controller.sendTransaction(preview),
      throwsA(isA<WalletTransactionRejected>()),
    );

    controller.dispose();
  });

  test('rejects sends unless derivation state is ready', () async {
    for (final state in [
      WalletDerivationState.pending,
      WalletDerivationState.watchOnly,
      WalletDerivationState.locked,
      WalletDerivationState.error,
    ]) {
      final repository = MemoryWalletRepository()
        ..value = WalletVault(
          accounts: [
            WalletAccount(
              id: state.name,
              name: state.name,
              accountIndex: 0,
              blockchainId: 'peercoin',
              networkId: 'mainnet',
              derivationState: state,
              address: 'pc1paccount0',
              createdAt: DateTime.utc(2026),
            ),
          ],
          nextAccountIndex: 1,
        );
      final controller = WalletController(
        repository,
        networkServiceFactory: (_) async => null,
      );
      await controller.load();

      expect(
        () => controller.prepareSend(
          const WalletSendRequest(
            destinationAddress: 'pc1pdestination',
            amountSats: 1,
            feeRateSatsPerKb: 10000,
          ),
        ),
        throwsA(isA<WalletSigningUnavailable>()),
        reason: state.name,
      );
      controller.dispose();
    }
  });

  test(
    'surfaces the ElectrumX rejection reason when broadcast fails',
    () async {
      final electrumx = _FakeElectrumxService()
        ..broadcastError = const ElectrumxException(
          'All ElectrumX servers failed.',
          cause: ElectrumxException(
            'ElectrumX request failed.',
            cause: ElectrumxRpcException(-26, 'bad-txns-inputs-missingorspent'),
          ),
        );
      final controller = WalletController(
        MemoryWalletRepository(),
        keyService: _FakeWalletKeyService(),
        transactionService: _FakeWalletTransactionService(),
        networkServiceFactory: (_) async => electrumx,
      );
      await controller.load();
      await controller.createWallet(
        _mnemonic,
        network: PeercoinNetworks.mainnet,
      );
      electrumx.snapshots.add(
        const PeercoinElectrumxUtxoSnapshot(
          address: 'pc1paccount0',
          utxos: [
            ElectrumxUtxo(
              address: 'pc1paccount0',
              txHash: 'funding',
              txPos: 0,
              height: 10,
              value: 2000000,
            ),
          ],
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final preview = controller.prepareSend(
        const WalletSendRequest(
          destinationAddress: 'pc1pdestination',
          amountSats: 1000000,
          feeRateSatsPerKb: 10000,
        ),
      );

      await expectLater(
        controller.sendTransaction(preview),
        throwsA(
          isA<WalletBroadcastFailure>()
              .having(
                (error) => error.kind,
                'kind',
                WalletBroadcastFailureKind.rejected,
              )
              .having((error) => error.rpcCode, 'RPC code', -26)
              .having(
                (error) => error.cause,
                'cause',
                same(electrumx.broadcastError),
              )
              .having(
                (error) => error.message,
                'message',
                'ElectrumX rejected the transaction: '
                    'bad-txns-inputs-missingorspent (code -26)',
              ),
        ),
      );
      expect(electrumx.broadcastedTransactions, ['signed-transaction']);
      final activity = controller
          .activitiesFor(controller.accounts.single)
          .first;
      expect(activity.transactionStatus, WalletTransactionStatus.failed);
      expect(activity.details, contains('bad-txns-inputs-missingorspent'));

      controller.dispose();
    },
  );

  test('reports when no ElectrumX service is available for broadcast', () async {
    final controller = WalletController(
      MemoryWalletRepository(),
      keyService: _FakeWalletKeyService(),
      transactionService: _FakeWalletTransactionService(),
      networkServiceFactory: (_) async => null,
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);

    final preview = controller.prepareSend(
      const WalletSendRequest(
        destinationAddress: 'pc1pdestination',
        amountSats: 1000000,
        feeRateSatsPerKb: 10000,
      ),
    );

    await expectLater(
      controller.sendTransaction(preview),
      throwsA(
        isA<WalletBroadcastFailure>()
            .having(
              (error) => error.kind,
              'kind',
              WalletBroadcastFailureKind.unavailable,
            )
            .having(
              (error) => error.message,
              'message',
              'ElectrumX is unavailable for this wallet. Reconnect and retry.',
            ),
      ),
    );

    controller.dispose();
  });

  for (final (error, kind) in [
    (
      ElectrumxException(
        'All servers failed.',
        cause: TimeoutException('request timed out'),
      ),
      WalletBroadcastFailureKind.timeout,
    ),
    (
      const ElectrumxException('Connection closed.'),
      WalletBroadcastFailureKind.connection,
    ),
    (
      StateError('Unexpected local failure.'),
      WalletBroadcastFailureKind.unexpected,
    ),
  ]) {
    test('preserves the cause of a ${kind.name} broadcast failure', () async {
      final electrumx = _FakeElectrumxService()..broadcastError = error;
      final controller = WalletController(
        MemoryWalletRepository(),
        keyService: _FakeWalletKeyService(),
        transactionService: _FakeWalletTransactionService(),
        networkServiceFactory: (_) async => electrumx,
      );
      await controller.load();
      await controller.createWallet(
        _mnemonic,
        network: PeercoinNetworks.mainnet,
      );
      final preview = controller.prepareSend(
        const WalletSendRequest(
          destinationAddress: 'pc1pdestination',
          amountSats: 1000000,
          feeRateSatsPerKb: 10000,
        ),
      );

      await expectLater(
        controller.sendTransaction(preview),
        throwsA(
          isA<WalletBroadcastFailure>()
              .having((failure) => failure.kind, 'kind', kind)
              .having((failure) => failure.cause, 'cause', same(error)),
        ),
      );
      controller.dispose();
    });
  }

  test('maps and logs an unexpected signing failure', () async {
    final transactions = _FakeWalletTransactionService()
      ..signingError = StateError('signer exploded');
    final controller = WalletController(
      MemoryWalletRepository(),
      keyService: _FakeWalletKeyService(),
      transactionService: transactions,
      networkServiceFactory: (_) async => _FakeElectrumxService(),
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);

    final preview = controller.prepareSend(
      const WalletSendRequest(
        destinationAddress: 'pc1pdestination',
        amountSats: 1000000,
        feeRateSatsPerKb: 10000,
      ),
    );

    await expectLater(
      controller.sendTransaction(preview),
      throwsA(
        isA<WalletSubmissionFailure>()
            .having(
              (error) => error.cause,
              'cause',
              same(transactions.signingError),
            )
            .having(
              (error) => error.message,
              'message',
              'Transaction submission failed: signer exploded',
            ),
      ),
    );

    controller.dispose();
  });
}

const _mnemonic = MnemonicSession(
  words: [
    'abandon',
    'abandon',
    'abandon',
    'abandon',
    'abandon',
    'abandon',
    'abandon',
    'abandon',
    'abandon',
    'abandon',
    'abandon',
    'about',
  ],
  language: MnemonicLanguage.english,
  createdInApp: true,
);

class _ControlledWalletRepository extends MemoryWalletRepository {
  Completer<void>? saveStarted;
  Completer<void>? saveGate;
  Object? saveError;
  bool commitBeforeError = false;

  @override
  Future<void> save(WalletVault vault) async {
    final started = saveStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
      await saveGate!.future;
    }
    final error = saveError;
    saveError = null;
    if (commitBeforeError) await super.save(vault);
    if (error != null) throw error;
    await super.save(vault);
  }
}

class _FakeWalletKeyService implements WalletKeyService {
  @override
  MnemonicSession generateMnemonic({
    required MnemonicLanguage language,
    required int wordCount,
  }) => _mnemonic;

  @override
  MnemonicValidationResult validateMnemonic({
    required String mnemonic,
    required MnemonicLanguage language,
  }) => mnemonic.trim() == _mnemonic.phrase
      ? MnemonicValidationResult.valid(_mnemonic.words)
      : const MnemonicValidationResult.invalid('Invalid recovery phrase.');

  @override
  DerivedWalletMaterial deriveAccount({
    required WalletNetwork network,
    required String mnemonic,
    required MnemonicLanguage language,
    required int accountIndex,
  }) => DerivedWalletMaterial(
    derivationPath: network.derivationPathForAccount(accountIndex),
    address:
        '${network.networkId == 'testnet' ? 'tpc' : 'pc'}1paccount$accountIndex',
    privateKeyHex: 'private-key-$accountIndex',
  );
}

class _FakeElectrumxService implements ElectrumxService {
  final StreamController<PeercoinElectrumxUtxoSnapshot> snapshots =
      StreamController<PeercoinElectrumxUtxoSnapshot>.broadcast();
  final List<Set<String>> watchedAddresses = [];
  bool closed = false;
  final List<String> broadcastedTransactions = [];
  Object? broadcastError;

  @override
  Stream<PeercoinElectrumxUtxoSnapshot> watchUtxosForAddresses(
    Iterable<String> addresses,
  ) {
    watchedAddresses.add(addresses.toSet());
    return snapshots.stream;
  }

  @override
  Future<List<ElectrumxUtxo>> fetchUtxos(String address) async => const [];

  @override
  Future<String> broadcastTransaction(String rawTransactionHex) async {
    broadcastedTransactions.add(rawTransactionHex);
    final error = broadcastError;
    if (error != null) throw error;
    return 'transaction-id';
  }

  @override
  Future<void> close() async {
    closed = true;
    await snapshots.close();
  }
}

class _DelayedCancellationElectrumxService(
  final Completer<void> cancellationStarted,
  final Completer<void> releaseCancellation,
) implements ElectrumxService {
  final List<Set<String>> watchedAddresses = [];
  final List<StreamController<PeercoinElectrumxUtxoSnapshot>> _controllers = [];

  @override
  Stream<PeercoinElectrumxUtxoSnapshot> watchUtxosForAddresses(
    Iterable<String> addresses,
  ) {
    watchedAddresses.add(addresses.toSet());
    final controller = StreamController<PeercoinElectrumxUtxoSnapshot>(
      onCancel: () async {
        if (!cancellationStarted.isCompleted) {
          cancellationStarted.complete();
        }
        await releaseCancellation.future;
      },
    );
    _controllers.add(controller);
    return controller.stream;
  }

  @override
  Future<List<ElectrumxUtxo>> fetchUtxos(String address) async => const [];

  @override
  Future<String> broadcastTransaction(String rawTransactionHex) async =>
      'transaction-id';

  @override
  Future<void> close() async {
    for (final controller in _controllers) {
      await controller.close();
    }
  }
}

class _FakeWalletTransactionService implements WalletTransactionService {
  List<ElectrumxUtxo> preparedUtxos = const [];
  String? signedPrivateKey;
  Object? signingError;

  @override
  WalletTransactionPreview prepare({
    required String accountId,
    required WalletNetwork network,
    required String sourceAddress,
    required List<ElectrumxUtxo> availableUtxos,
    required WalletSendRequest request,
  }) {
    preparedUtxos = availableUtxos;
    return WalletTransactionPreview(
      accountId: accountId,
      sourceAddress: sourceAddress,
      destinationAddress: request.destinationAddress,
      amountSats: request.amountSats,
      feeSats: 1000,
      changeSats: 999000,
      feeRateSatsPerKb: request.feeRateSatsPerKb,
      selectedUtxos: availableUtxos,
      signingMessage: request.signingMessage,
    );
  }

  @override
  SignedWalletTransaction sign({
    required WalletNetwork network,
    required WalletTransactionPreview preview,
    required String privateKeyHex,
  }) {
    signedPrivateKey = privateKeyHex;
    final error = signingError;
    if (error != null) throw error;
    return const SignedWalletTransaction(
      transactionId: 'local-transaction-id',
      rawTransactionHex: 'signed-transaction',
    );
  }

  @override
  ThresholdWalletTransaction prepareThresholdSigning({
    required WalletNetwork network,
    required WalletTransactionPreview preview,
  }) => throw UnimplementedError();

  @override
  SignedWalletTransaction completeThresholdSigning({
    required ThresholdWalletTransaction transaction,
    required List<Uint8List> signatures,
    required String expectedInternalKeyHex,
  }) => throw UnimplementedError();
}
