import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/models/electrumx_utxo.dart';
import 'package:sygnature_ng/services/electrumx_service.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';

void main() {
  test(
    'persists multiple account shells and accepts coinlib material',
    () async {
      final repository = MemoryWalletRepository();
      final controller = WalletController(repository);
      await controller.load();

      await controller.createWalletShell(
        languageId: 'english',
        mnemonicWordCount: 24,
      );
      await controller.addAccount('Savings');
      await controller.attachDerivedMaterial(
        accountIndex: 1,
        address: 'PexampleAddress',
        privateKeyHex: 'deadbeef',
        derivationPath: "m/86'/6'/1'/0/0",
      );

      final restored = WalletController(repository);
      await restored.load();
      expect(restored.accounts, hasLength(2));
      expect(restored.accounts[1].name, 'Savings');
      expect(restored.accounts[1].address, 'PexampleAddress');
      expect(restored.accounts[1].privateKeyHex, 'deadbeef');
      expect(restored.vault?.languageId, 'english');
      expect(restored.vault?.mnemonicWordCount, 24);
    },
  );

  test('streams ElectrumX UTXOs into account balance state', () async {
    final electrumx = _FakeElectrumxService();
    final controller = WalletController(
      MemoryWalletRepository(),
      electrumxService: electrumx,
    );
    await controller.load();
    await controller.createWalletShell();
    await controller.attachDerivedMaterial(
      accountIndex: 0,
      address: 'pc1ptestaddress',
      privateKeyHex: 'deadbeef',
      derivationPath: "m/86'/6'/0'/0/0",
    );

    final account = controller.accounts.single;
    expect(controller.syncStatusFor(account), AccountSyncStatus.syncing);
    expect(electrumx.watchedAddresses.single, {'pc1ptestaddress'});

    electrumx.snapshots.add(
      const PeercoinElectrumxUtxoSnapshot(
        address: 'pc1ptestaddress',
        utxos: [
          ElectrumxUtxo(
            address: 'pc1ptestaddress',
            txHash: 'first',
            txPos: 0,
            height: 10,
            value: 1250000,
          ),
          ElectrumxUtxo(
            address: 'pc1ptestaddress',
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
