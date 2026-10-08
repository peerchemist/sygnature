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
import 'package:sygnature_ng/ui/about_screen.dart';
import 'package:sygnature_ng/ui/wallet_home.dart';
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
    expect(find.text('Wordlist: English, 2048 words'), findsOneWidget);
    expect(find.byKey(const Key('wallet-network-field')), findsNothing);

    await tester.ensureVisible(find.text('Generate recovery phrase'));
    await tester.tap(find.text('Generate recovery phrase'));
    await tester.pumpAndSettle();
    expect(find.text('Back up recovery phrase'), findsOneWidget);
    expect(find.text('1. abandon'), findsOneWidget);
    expect(find.text('Network'), findsNothing);
    expect(find.text('Derivation path'), findsNothing);

    await tester.ensureVisible(
      find.text('I wrote down these recovery words in order.'),
    );
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save recovery phrase'));
    await tester.tap(find.text('Save recovery phrase'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Add wallet'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Add wallet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Personal wallet'));
    await tester.pumpAndSettle();
    expect(find.text('New personal wallet'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sub-wallet-network-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Peercoin testnet').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('Main wallet'), findsWidgets);
    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.text('Ready'), findsNothing);
    expect(find.text('Peercoin testnet'), findsOneWidget);

    await tester.tap(find.byTooltip('Add sub-wallet'));
    await tester.pumpAndSettle();
    expect(find.text('Watch-only wallet'), findsOneWidget);
    await tester.tap(find.text('Personal wallet'));
    await tester.pumpAndSettle();
    expect(find.text('New personal wallet'), findsOneWidget);
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

  testWidgets('shows a busy failure when switching wallets during an update', (
    tester,
  ) async {
    final gate = Completer<ElectrumxService?>();
    var delayConnection = false;
    final controller = WalletController(
      MemoryWalletRepository(),
      keyService: _FakeWalletKeyService(),
      networkServiceFactory: (_) async => delayConnection ? gate.future : null,
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);
    await controller.addAccount('Savings', network: PeercoinNetworks.mainnet);
    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();
    delayConnection = true;
    final adding = controller.addAccount(
      'Third',
      network: PeercoinNetworks.mainnet,
    );
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(null);
    });
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Main wallet'));
    await tester.pumpAndSettle();

    expect(
      find.text('Another wallet operation is in progress. Try again.'),
      findsOneWidget,
    );
    expect(controller.selectedAccount!.name, 'Savings');
    expect(tester.takeException(), isNull);
    gate.complete(null);
    await adding;
    await tester.pumpAndSettle();
    expect(controller.selectedAccount!.name, 'Third');
  });

  testWidgets(
    'updates wallet sections only when their displayed data changes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final electrumx = _PendingElectrumxService();
      var connect = false;
      final controller = WalletController(
        MemoryWalletRepository(),
        keyService: _FakeWalletKeyService(),
        networkServiceFactory: (_) async => connect ? electrumx : null,
      );
      await controller.load();
      await controller.createWallet(
        _mnemonic,
        network: PeercoinNetworks.mainnet,
      );
      await controller.addAccount('Savings', network: PeercoinNetworks.mainnet);
      connect = true;
      await controller.reconnectElectrumx();
      final background = controller.accounts.first;
      final selected = controller.selectedAccount!;
      electrumx.emitBalance(background.address!, 1000000);
      electrumx.emitBalance(selected.address!, 2000000);
      await tester.pumpWidget(
        SygnatureApp(controllerFactory: () async => controller),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      Finder balance() => find.byWidgetPredicate(
        (widget) => widget is Text && widget.style?.fontSize == 34,
      );
      final amount = tester.widget<Text>(balance());
      final activityTitle = tester.widget<Text>(find.text('Recent activity'));
      expect(amount.data, '2.00 PPC');
      expect(find.text('1.00 PPC'), findsOneWidget);

      electrumx.emitBalance(background.address!, 3000000);
      await tester.pumpAndSettle();
      expect(find.text('3.00 PPC'), findsOneWidget);
      expect(tester.widget<Text>(balance()), same(amount));
      expect(
        tester.widget<Text>(find.text('Recent activity')),
        same(activityTitle),
      );

      electrumx.emitBalance(selected.address!, 4000000);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(balance()).data, '4.00 PPC');
      expect(
        tester.widget<Text>(find.text('Recent activity')),
        same(activityTitle),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await electrumx.close();
    },
  );

  testWidgets('imports a watch-only wallet without private material', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const address =
        'pc1pmfr3p9j00pfxjh0zmgp99y8zftmd3s5pmedqhyptwy6lm87hf5ssntx2jm';
    final controller = await createController();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);
    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add sub-wallet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Watch-only wallet'));
    await tester.pumpAndSettle();
    expect(find.text('Add watch-only wallet'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('watch-only-address-field')),
      address,
    );
    await tester.enterText(
      find.byKey(const Key('watch-only-name-field')),
      'Observer',
    );
    await tester.tap(find.byKey(const Key('watch-only-add-button')));
    await tester.pumpAndSettle();

    final account = controller.accounts.firstWhere(
      (account) => account.name == 'Observer',
    );
    expect(account.name, 'Observer');
    expect(account.address, address);
    expect(account.keySource, WalletKeySource.watchOnly);
    expect(account.derivationState, WalletDerivationState.watchOnly);
    expect(account.privateKeyHex, isNull);
    expect(find.text('Observer'), findsWidgets);
    expect(find.text('WATCH ONLY'), findsOneWidget);
    expect(find.text('Watch-only · 0.00 PPC'), findsOneWidget);
    final sendButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Send'),
    );
    expect(sendButton.onPressed, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
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
    final home = tester.widget<WalletHome>(find.byType(WalletHome));

    electrumx.emitEmpty(controller.accounts.single.address!);
    await tester.pump();

    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Synchronizing'), findsNothing);
    expect(tester.widget<WalletHome>(find.byType(WalletHome)), same(home));

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
    expect(find.text('Signing requests'), findsOneWidget);
    final primaryColumn = find.byKey(const Key('desktop-primary-column'));
    final contextColumn = find.byKey(const Key('desktop-context-column'));
    expect(primaryColumn, findsOneWidget);
    expect(contextColumn, findsOneWidget);
    expect(
      tester.getTopLeft(primaryColumn).dx,
      lessThan(tester.getTopLeft(contextColumn).dx),
    );
    expect(
      tester.getTopLeft(primaryColumn).dy,
      tester.getTopLeft(contextColumn).dy,
    );

    await tester.tap(find.text('Signing requests'));
    await tester.pumpAndSettle();

    expect(find.text('No pending requests.'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byKey(const Key('desktop-modal-panel')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses a single content column at medium desktop widths', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = await createController();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);
    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();

    expect(find.text('WALLETS'), findsOneWidget);
    expect(find.byKey(const Key('desktop-wallet-overview')), findsNothing);
    expect(find.text('RECEIVE ADDRESS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('archives and restores a wallet from settings', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await createController();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);
    await controller.addAccount('Savings', network: PeercoinNetworks.mainnet);
    final savingsId = controller.selectedAccount!.id;

    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Wallet settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive wallet'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-archive-wallet')));
    await tester.pumpAndSettle();

    expect(controller.accounts.map((account) => account.name), ['Main wallet']);
    expect(controller.archivedAccounts.single.id, savingsId);

    await tester.binding.setSurfaceSize(const Size(800, 800));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('archived-wallets-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('restore-wallet-$savingsId')));
    await tester.pumpAndSettle();

    expect(controller.archivedAccounts, isEmpty);
    expect(controller.selectedAccount?.id, savingsId);
  });

  testWidgets('configures notifications and opens the about screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = WalletController(
      MemoryWalletRepository(),
      keyService: _FakeWalletKeyService(),
    );
    await controller.load();
    await controller.createWallet(_mnemonic, network: PeercoinNetworks.mainnet);

    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
    expect(find.text('Desktop notifications'), findsOneWidget);
    expect(find.text('Electrum endpoints'), findsOneWidget);
    expect(find.text('Notification sound'), findsOneWidget);
    expect(find.text('Volume'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('Send test notification'), findsOneWidget);
    expect(find.byKey(const Key('settings-version')), findsOneWidget);
    expect(find.text('Version $sygnatureVersionString'), findsOneWidget);

    await tester.tap(find.byKey(const Key('notification-sound-toggle')));
    await tester.pump();

    expect(
      tester
          .widget<Slider>(find.byKey(const Key('notification-volume-slider')))
          .onChanged,
      isNull,
    );

    await tester.ensureVisible(find.byKey(const Key('about-button')));
    await tester.tap(find.byKey(const Key('about-button')));
    await tester.pumpAndSettle();

    expect(find.text('About'), findsOneWidget);
    expect(find.textContaining('Peercoin light wallet'), findsOneWidget);
    expect(find.byKey(const Key('about-version')), findsOneWidget);
    expect(find.text('Version $sygnatureVersionString'), findsOneWidget);
    expect(find.byKey(const Key('licenses-button')), findsOneWidget);
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
            derivationState: WalletDerivationState.ready,
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
      derivationState: WalletDerivationState.ready,
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
            id: 'message-signature-requested:message-request',
            accountId: account.id,
            type: WalletActivityType.messageSignatureRequested,
            occurredAt: DateTime.now()
                .subtract(const Duration(days: 2))
                .toUtc(),
            reference: 'message-request',
            details: 'Expired message',
          ),
          WalletActivity(
            id: 'broadcast:txid',
            accountId: account.id,
            type: WalletActivityType.transactionBroadcast,
            occurredAt: DateTime.now().toUtc(),
            reference: 'transaction-id',
            transactionStatus: WalletTransactionStatus.confirmed,
            blockHeight: 123,
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
    expect(find.text('Transaction confirmed'), findsOneWidget);
    expect(find.textContaining('Transaction transa'), findsOneWidget);
    expect(find.text('EXPIRED'), findsOneWidget);
    expect(
      find.byKey(
        const Key(
          'activity-expired-message-signature-requested:message-request',
        ),
      ),
      findsOneWidget,
    );
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
  language: MnemonicLanguage.english,
  createdInApp: true,
);

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
  }) => MnemonicValidationResult.valid(_mnemonic.words);

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

  void emitBalance(String address, int value) {
    _snapshots.add(
      PeercoinElectrumxUtxoSnapshot(
        address: address,
        utxos: [
          ElectrumxUtxo(
            address: address,
            txHash: 'funding',
            txPos: 0,
            height: 1,
            value: value,
          ),
        ],
      ),
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
