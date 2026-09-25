import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/models/electrumx_utxo.dart';
import 'package:sygnature_ng/models/mnemonic_seed.dart';
import 'package:sygnature_ng/models/wallet_network.dart';
import 'package:sygnature_ng/models/wallet_transaction.dart';
import 'package:sygnature_ng/services/electrumx_service.dart';
import 'package:sygnature_ng/services/peercoin_network_service.dart';
import 'package:sygnature_ng/services/wallet_key_service.dart';
import 'package:sygnature_ng/services/wallet_transaction_service.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';

void main() {
  test('persists mnemonic and automatically derives every account', () async {
    final repository = MemoryWalletRepository();
    final controller = WalletController(
      repository,
      keyService: _FakeWalletKeyService(),
    );
    await controller.load();

    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);
    await controller.addAccount('Savings', network: PeercoinNetworks.testnet);

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
    expect(controller.vault?.nextAccountIndex, 2);
    expect(repository.value?.accounts, hasLength(1));
    expect(services['peercoin:testnet']!.closed, isTrue);
    expect(services['peercoin:mainnet']!.watchedAddresses.last, {
      'pc1paccount0',
    });

    controller.dispose();
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
    await expectLater(
      controller.sendTransaction(preview),
      throwsA(isA<WalletTransactionRejected>()),
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
  language: MnemonicLanguage(
    id: 'english',
    label: 'English',
    assetPath: 'assets/wordlists/english.txt',
  ),
  createdInApp: true,
);

class _FakeWalletKeyService implements WalletKeyService {
  @override
  MnemonicSession generateMnemonic({
    required MnemonicLanguage language,
    required int wordCount,
    required List<String> wordlist,
  }) => _mnemonic;

  @override
  MnemonicValidationResult validateMnemonic({
    required String mnemonic,
    required MnemonicLanguage language,
    required List<String> wordlist,
  }) => mnemonic.trim() == _mnemonic.phrase
      ? MnemonicValidationResult.valid(_mnemonic.words)
      : const MnemonicValidationResult.invalid('Invalid recovery phrase.');

  @override
  DerivedWalletMaterial deriveAccount({
    required WalletNetwork network,
    required String mnemonic,
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
    return 'transaction-id';
  }

  @override
  Future<void> close() async {
    closed = true;
    await snapshots.close();
  }
}

class _FakeWalletTransactionService implements WalletTransactionService {
  List<ElectrumxUtxo> preparedUtxos = const [];
  String? signedPrivateKey;

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
    );
  }

  @override
  SignedWalletTransaction sign({
    required WalletNetwork network,
    required WalletTransactionPreview preview,
    required String privateKeyHex,
  }) {
    signedPrivateKey = privateKeyHex;
    return const SignedWalletTransaction(
      transactionId: 'local-transaction-id',
      rawTransactionHex: 'signed-transaction',
    );
  }
}
