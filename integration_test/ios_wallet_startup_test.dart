// Run only on a dedicated iOS Simulator with no wallet data:
// flutter test integration_test/ios_wallet_startup_test.dart -d <simulator-id> \
//   --dart-define=RUN_IOS_WALLET_STARTUP_TESTS=true
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sygnature_ng/main.dart' as app;

const _runTests = bool.fromEnvironment('RUN_IOS_WALLET_STARTUP_TESTS');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS opens the system vault and creates a testnet wallet',
    (tester) async {
      // This opt-in test runs on a dedicated Simulator. Keep native permission
      // sheets out of the startup/Keychain checks, which use Flutter controls.
      const storage = FlutterSecureStorage();
      await storage.write(key: 'notifications.desktop_enabled', value: 'false');
      await storage.write(
        key: 'notifications.system_preference_set',
        value: 'true',
      );
      await app.main();
      final addWallet = find.widgetWithText(FilledButton, 'Add wallet');
      await _waitFor(tester, addWallet);
      expect(find.text('Unable to open vault'), findsNothing);

      await tester.tap(addWallet);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Personal wallet'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sub-wallet-network-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Peercoin testnet').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await _waitFor(tester, find.text('Personal wallet · Peercoin testnet'));
      expect(find.text('Main wallet'), findsWidgets);

      final qrButton = find.byTooltip('Show address QR code');
      await tester.ensureVisible(qrButton);
      await tester.tap(qrButton);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('share-qr-code')), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('backup-button')));
      await tester.pumpAndSettle();
      expect(find.text('Encrypted wallet backup'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('export-backup')));
      await tester.tap(find.byKey(const Key('export-backup')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Use at least 8 characters and enter the same passphrase twice.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    skip: !_runTests || defaultTargetPlatform != TargetPlatform.iOS,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 150; attempt++) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets);
}
