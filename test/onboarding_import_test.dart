import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/main.dart';
import 'package:sygnature_ng/models/mnemonic_seed.dart';
import 'package:sygnature_ng/models/wallet_network.dart';
import 'package:sygnature_ng/services/wallet_key_service.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';

void main() {
  testWidgets('imports an existing recovery phrase', (tester) async {
    final controller = WalletController(
      MemoryWalletRepository(),
      keyService: _ImportWalletKeyService(),
    );
    await controller.load();

    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Import existing'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recovery-phrase-field')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('recovery-phrase-field')),
      _mnemonic.phrase,
    );
    final reviewButton = find.byKey(const Key('mnemonic-continue-button'));
    await tester.ensureVisible(reviewButton);
    await tester.tap(reviewButton);
    await tester.pumpAndSettle();

    expect(find.text('Review imported wallet'), findsOneWidget);
    expect(find.text("m/86'/6'/0'/0/0"), findsOneWidget);
    expect(find.text('1. abandon'), findsNothing);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    final importButton = find.byKey(const Key('wallet-create-button'));
    await tester.ensureVisible(importButton);
    await tester.tap(importButton);
    await tester.pumpAndSettle();

    expect(find.text('Main wallet'), findsWidgets);
    expect(find.text('Peercoin mainnet'), findsOneWidget);
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
  createdInApp: false,
);

class _ImportWalletKeyService implements WalletKeyService {
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
    address: 'pc1pimported',
    privateKeyHex: 'private-key-$accountIndex',
  );
}
