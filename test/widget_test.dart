import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/main.dart';
import 'package:sygnature_ng/models/electrumx_utxo.dart';
import 'package:sygnature_ng/models/mnemonic_seed.dart';
import 'package:sygnature_ng/models/wallet_network.dart';
import 'package:sygnature_ng/services/electrumx_service.dart';
import 'package:sygnature_ng/services/peercoin_network_service.dart';
import 'package:sygnature_ng/services/wallet_key_service.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';

void main() {
  Future<WalletController> createController() async {
    final controller = WalletController(
      MemoryWalletRepository(),
      keyService: _FakeWalletKeyService(),
    );
    await controller.load();
    return controller;
  }

  testWidgets('creates a derived wallet and supports derived sub-wallets', (
    tester,
  ) async {
    await tester.pumpWidget(SygnatureApp(controllerFactory: createController));
    await tester.pumpAndSettle();

    expect(find.text('Mnemonic'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Peercoin mainnet'), findsOneWidget);
    expect(find.text('Wordlist: English, 2048 words'), findsOneWidget);

    await tester.tap(find.byKey(const Key('wallet-network-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Peercoin testnet').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Generate recovery phrase'));
    await tester.tap(find.text('Generate recovery phrase'));
    await tester.pumpAndSettle();
    expect(find.text('Back up your wallet'), findsOneWidget);
    expect(find.text('Peercoin testnet'), findsOneWidget);
    expect(find.text('1. abandon'), findsOneWidget);
    expect(find.text("m/86'/1'/0'/0/0"), findsOneWidget);

    await tester.ensureVisible(
      find.text('I wrote down these recovery words in order.'),
    );
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Create wallet'));
    await tester.tap(find.text('Create wallet'));
    await tester.pumpAndSettle();

    expect(find.text('Main wallet'), findsWidgets);
    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.text('Ready'), findsNothing);
    expect(find.text('Peercoin testnet'), findsOneWidget);

    await tester.tap(find.byTooltip('Add sub-wallet'));
    await tester.pumpAndSettle();
    expect(find.text('New sub-wallet'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add'), findsOneWidget);
    final addButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Add'),
    );
    expect(addButton.onPressed, isNotNull);
    expect(find.text('Peercoin mainnet'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sub-wallet-network-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Peercoin mainnet').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('Wallet 2'), findsWidgets);
    expect(find.text('Account index'), findsOneWidget);
    expect(find.text('Peercoin mainnet'), findsOneWidget);

    await tester.tap(find.byTooltip('Wallet settings'));
    await tester.pumpAndSettle();
    expect(find.text('Delete wallet'), findsOneWidget);

    await tester.tap(find.text('Delete wallet'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Wallet 2?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete wallet'));
    await tester.pumpAndSettle();

    expect(find.text('Wallet 2'), findsNothing);
    expect(find.text('Main wallet'), findsWidgets);
  });

  testWidgets('does not show Ready while ElectrumX is synchronizing', (
    tester,
  ) async {
    final electrumx = _PendingElectrumxService();
    final controller = WalletController(
      MemoryWalletRepository(),
      keyService: _FakeWalletKeyService(),
      networkServiceFactory: (_) async => electrumx,
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);

    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pump();

    expect(find.text('Synchronizing'), findsOneWidget);
    expect(find.text('Ready'), findsNothing);

    electrumx.emitEmpty(controller.accounts.single.address!);
    await tester.pump();

    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Synchronizing'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await electrumx.close();
  });

  testWidgets('uses the desktop sidebar at wide breakpoints', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repository = MemoryWalletRepository();
    final controller = WalletController(
      repository,
      keyService: _FakeWalletKeyService(),
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);

    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();

    expect(find.text('WALLETS'), findsOneWidget);
    expect(find.text('Recent activity'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

const _mnemonic = MnemonicSession(
  words: [
    'abandon',
    'ability',
    'able',
    'about',
    'above',
    'absent',
    'absorb',
    'abstract',
    'absurd',
    'abuse',
    'access',
    'accident',
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

class _PendingElectrumxService implements ElectrumxService {
  final StreamController<PeercoinElectrumxUtxoSnapshot> _snapshots =
      StreamController<PeercoinElectrumxUtxoSnapshot>.broadcast();

  @override
  Stream<PeercoinElectrumxUtxoSnapshot> watchUtxosForAddresses(
    Iterable<String> addresses,
  ) => _snapshots.stream;

  void emitEmpty(String address) {
    _snapshots.add(
      PeercoinElectrumxUtxoSnapshot(address: address, utxos: const []),
    );
  }

  @override
  Future<List<ElectrumxUtxo>> fetchUtxos(String address) async => const [];

  @override
  Future<String> broadcastTransaction(String rawTransactionHex) async =>
      'transaction-id';

  @override
  Future<void> close() async {
    if (!_snapshots.isClosed) await _snapshots.close();
  }
}
