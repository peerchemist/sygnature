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

    expect(find.text('Review recovery phrase'), findsOneWidget);
    expect(find.text('Network'), findsNothing);
    expect(find.text('Derivation path'), findsNothing);
    expect(find.text('1. abandon'), findsNothing);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    final importButton = find.byKey(const Key('wallet-create-button'));
    await tester.ensureVisible(importButton);
    await tester.tap(importButton);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Add wallet'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Add wallet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Personal wallet'));
    await tester.pumpAndSettle();
    expect(find.text('New personal wallet'), findsOneWidget);
    await tester.tap(find.text('Add'));
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
  language: MnemonicLanguage.english,
  createdInApp: false,
);

class _ImportWalletKeyService implements WalletKeyService {
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
    address: 'pc1pimported',
    privateKeyHex: 'private-key-$accountIndex',
  );
}
