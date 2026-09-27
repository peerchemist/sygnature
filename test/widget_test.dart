import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/main.dart';
import 'package:sygnature_ng/models/electrumx_utxo.dart';
import 'package:sygnature_ng/models/mnemonic_seed.dart';
import 'package:sygnature_ng/models/wallet_account.dart';
import 'package:sygnature_ng/models/wallet_activity.dart';
import 'package:sygnature_ng/models/wallet_network.dart';
import 'package:sygnature_ng/models/wallet_vault.dart';
import 'package:sygnature_ng/services/electrumx_service.dart';
import 'package:sygnature_ng/services/peercoin_network_service.dart';
import 'package:sygnature_ng/services/wallet_key_service.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';
import 'package:sygnature_ng/ui/widgets/middle_ellipsis_text.dart';

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
    await tester.tap(find.text('Personal wallet'));
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
    expect(find.text('LOCAL'), findsOneWidget);
    expect(find.text('ROAST'), findsNothing);
    expect(find.text('Recent activity'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows both ends of a long receive address', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const address =
        'pc1pczy4pf46yjt8ukyg1gsyxhquvx7vjhlgqjpux8ahcxv3870example';
    final repository = MemoryWalletRepository()
      ..value = WalletVault(
        accounts: [
          WalletAccount(
            id: 'main',
            name: 'Main wallet',
            accountIndex: 0,
            blockchainId: 'peercoin',
            networkId: 'mainnet',
            address: address,
            privateKeyHex: 'private-key-0',
            createdAt: DateTime.utc(2026),
          ),
        ],
        nextAccountIndex: 1,
      );
    final controller = WalletController(
      repository,
      keyService: _FakeWalletKeyService(),
    );
    await controller.load();

    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();

    final addressText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('receive-address-value')),
        matching: find.byType(Text),
      ),
    );
    expect(addressText.data, contains('…'));
    expect(addressText.data, startsWith(address.substring(0, 8)));
    expect(addressText.data, endsWith(address.substring(address.length - 8)));
    expect(addressText.semanticsLabel, address);
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapses an unfocused address field without changing it', (
    tester,
  ) async {
    const address =
        'pc1pczy4pf46yjt8ukyg1gsyxhquvx7vjhlgqjpux8ahcxv3870example';
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: Column(
              children: [
                MiddleEllipsisTextFormField(
                  controller: controller,
                  fieldKey: const Key('address-field'),
                  collapsedTextKey: const Key('collapsed-address'),
                  decoration: const InputDecoration(labelText: 'Address'),
                ),
                const TextField(key: Key('next-field')),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('address-field')), address);
    await tester.tap(find.byKey(const Key('next-field')));
    await tester.pump();

    final addressText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('collapsed-address')),
        matching: find.byType(Text),
      ),
    );
    expect(addressText.data, contains('…'));
    expect(addressText.data, startsWith(address.substring(0, 8)));
    expect(addressText.data, endsWith(address.substring(address.length - 8)));
    expect(controller.text, address);

    await tester.tap(find.byKey(const Key('address-field')));
    await tester.pump();
    expect(find.byKey(const Key('collapsed-address')), findsNothing);
  });

  testWidgets('shows persisted events in recent activity', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final account = WalletAccount(
      id: 'main',
      name: 'Main wallet',
      accountIndex: 0,
      blockchainId: 'peercoin',
      networkId: 'mainnet',
      address: 'pc1paccount0',
      privateKeyHex: 'private-key-0',
      createdAt: DateTime.utc(2026),
    );
    final repository = MemoryWalletRepository()
      ..value = WalletVault(
        accounts: [account],
        nextAccountIndex: 1,
        activities: [
          WalletActivity(
            id: 'broadcast:txid',
            accountId: account.id,
            type: WalletActivityType.transactionBroadcast,
            occurredAt: DateTime.now().toUtc(),
            reference: 'transaction-id',
          ),
        ],
      );
    final controller = WalletController(
      repository,
      keyService: _FakeWalletKeyService(),
    );
    await controller.load();

    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recent activity'), findsOneWidget);
    expect(find.text('Transaction broadcast'), findsOneWidget);
    expect(find.textContaining('Transaction transa'), findsOneWidget);
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
  MnemonicValidationResult validateMnemonic({
    required String mnemonic,
    required MnemonicLanguage language,
    required List<String> wordlist,
  }) => MnemonicValidationResult.valid(_mnemonic.words);

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
