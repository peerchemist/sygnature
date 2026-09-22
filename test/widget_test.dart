import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/main.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';

void main() {
  Future<WalletController> createController() async {
    final controller = WalletController(MemoryWalletRepository());
    await controller.load();
    return controller;
  }

  testWidgets('creates the wallet shell and supports sub-wallets', (
    tester,
  ) async {
    await tester.pumpWidget(SygnatureApp(controllerFactory: createController));
    await tester.pumpAndSettle();

    expect(find.text('Mnemonic'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Wordlist: English, 2048 words'), findsOneWidget);

    await tester.ensureVisible(find.text('Review derivation'));
    await tester.tap(find.text('Review derivation'));
    await tester.pumpAndSettle();
    expect(find.text('Taproot account'), findsOneWidget);
    expect(find.text("m/86'/6'/0'/0/0"), findsOneWidget);

    await tester.ensureVisible(find.text('Open wallet shell'));
    await tester.tap(find.text('Open wallet shell'));
    await tester.pumpAndSettle();

    expect(find.text('Main wallet'), findsWidgets);
    expect(find.text('Pending coinlib'), findsOneWidget);

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
    final controller = WalletController(repository);
    await controller.load();
    await controller.createWalletShell(
      languageId: 'english',
      mnemonicWordCount: 12,
    );

    await tester.pumpWidget(
      SygnatureApp(controllerFactory: () async => controller),
    );
    await tester.pumpAndSettle();

    expect(find.text('WALLETS'), findsOneWidget);
    expect(find.text('Recent activity'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
