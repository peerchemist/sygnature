import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/main.dart';
import 'package:sygnature_ng/models/mnemonic_seed.dart';
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
    expect(find.text('Wordlist: English, 2048 words'), findsOneWidget);

    await tester.ensureVisible(find.text('Generate recovery phrase'));
    await tester.tap(find.text('Generate recovery phrase'));
    await tester.pumpAndSettle();
    expect(find.text('Back up your wallet'), findsOneWidget);
    expect(find.text('1. abandon'), findsOneWidget);
    expect(find.text("m/86'/6'/0'/0/0"), findsOneWidget);

    await tester.ensureVisible(
      find.text('I wrote down these recovery words in order.'),
    );
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Create wallet'));
    await tester.tap(find.text('Create wallet'));
    await tester.pumpAndSettle();

    expect(find.text('Main wallet'), findsWidgets);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Encrypted'), findsOneWidget);

    await tester.tap(find.byTooltip('Add sub-wallet'));
    await tester.pumpAndSettle();
    expect(find.text('New sub-wallet'), findsOneWidget);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('Wallet 2'), findsWidgets);
    expect(find.text('Account index'), findsOneWidget);
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
    await controller.createWallet(_mnemonic);

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
    required String mnemonic,
    required int accountIndex,
  }) => DerivedWalletMaterial(
    derivationPath: "m/86'/6'/$accountIndex'/0/0",
    address: 'pc1paccount$accountIndex',
    privateKeyHex: 'private-key-$accountIndex',
  );
}
