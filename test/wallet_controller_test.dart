import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/models/electrumx_utxo.dart';
import 'package:sygnature_ng/models/mnemonic_seed.dart';
import 'package:sygnature_ng/services/electrumx_service.dart';
import 'package:sygnature_ng/services/wallet_key_service.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';

void main() {
  test('persists mnemonic and automatically derives every account', () async {
    final repository = MemoryWalletRepository();
    final controller = WalletController(
      repository,
      keyService: _FakeWalletKeyService(),
    );
    await controller.load();

    await controller.createWallet(_mnemonic);
    await controller.addAccount('Savings');

    final restored = WalletController(
      repository,
      keyService: _FakeWalletKeyService(),
    );
    await restored.load();
    expect(restored.accounts, hasLength(2));
    expect(restored.accounts[1].name, 'Savings');
    expect(restored.accounts[1].address, 'pc1paccount1');
    expect(restored.accounts[1].privateKeyHex, 'private-key-1');
    expect(restored.accounts[1].derivationPath, "m/86'/6'/1'/0/0");
    expect(restored.vault?.mnemonic, _mnemonic.phrase);
    expect(restored.vault?.languageId, 'english');
    expect(restored.vault?.mnemonicWordCount, 12);
  });

  test('streams ElectrumX UTXOs into account balance state', () async {
    final electrumx = _FakeElectrumxService();
    final controller = WalletController(
      MemoryWalletRepository(),
      electrumxService: electrumx,
      keyService: _FakeWalletKeyService(),
    );
    await controller.load();
    await controller.createWallet(_mnemonic);

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
    expect(controller.utxosFor(account), hasLength(2));
    expect(controller.syncStatusFor(account), AccountSyncStatus.synced);

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
  DerivedWalletMaterial deriveAccount({
    required String mnemonic,
    required int accountIndex,
  }) => DerivedWalletMaterial(
    derivationPath: "m/86'/6'/$accountIndex'/0/0",
    address: 'pc1paccount$accountIndex',
    privateKeyHex: 'private-key-$accountIndex',
  );
}

class _FakeElectrumxService implements ElectrumxService {
  final StreamController<PeercoinElectrumxUtxoSnapshot> snapshots =
      StreamController<PeercoinElectrumxUtxoSnapshot>.broadcast();
  final List<Set<String>> watchedAddresses = [];
  bool closed = false;

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
    return 'transaction-id';
  }

  @override
  Future<void> close() async {
    closed = true;
    await snapshots.close();
  }
}
