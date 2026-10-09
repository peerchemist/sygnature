import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:sygnature_ng/main.dart';
import 'package:sygnature_ng/models/wallet_vault.dart';
import 'package:sygnature_ng/storage/vault_protection.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';
import 'package:sygnature_ng/ui/onboarding_screen.dart';
import 'package:sygnature_ng/ui/wallet_home.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const storageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  late Directory directory;
  late Map<String, String> keys;
  late List<MethodCall> storageCalls;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sygnature-startup-');
    keys = {'notifications.desktop_enabled': 'false'};
    storageCalls = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (_) async => directory.path,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(storageChannel, (
      call,
    ) async {
      storageCalls.add(call);
      final args = call.arguments as Map;
      final options = args['options'] as Map;
      final authenticated =
          options['storageNamespace'] == 'sygnature_device_vault_v1';
      expect(
        options['enforceBiometrics'],
        authenticated ? 'true' : isNot('true'),
      );
      expect(options['accessControlFlags'], isNull);
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        // Includes notification preferences as well as vault keyring calls.
        expect(options['usesDataProtectionKeychain'], 'false');
        expect(options['authenticationUIBehavior'], 'u_AuthUIF');
      }
      final key = args['key'] as String;
      final storedKey = authenticated ? 'device:$key' : key;
      switch (call.method) {
        case 'read':
          return keys[storedKey];
        case 'write':
          keys[storedKey] = args['value'] as String;
        case 'delete':
          keys.remove(storedKey);
      }
      return null;
    });
  });

  tearDown(() async {
    await Hive.close();
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathChannel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      storageChannel,
      null,
    );
    await directory.delete(recursive: true);
  });

  Future<void> startApp(WidgetTester tester, Finder destination) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const SygnatureApp());
      for (var attempt = 0; attempt < 100; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (destination.evaluate().isNotEmpty) break;
      }
    });
    expect(destination, findsOneWidget);
    expect(find.text('Protect your vault'), findsNothing);
    expect(tester.takeException(), isNull);
  }

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets(
      '$platform creates a system vault without a protection choice',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await startApp(tester, find.byType(OnboardingScreen));
        final store = await tester.runAsync(VaultProtectionStore.open);
        expect(store!.config!.mode, VaultProtectionMode.system);
        expect(Hive.isBoxOpen('sygnature_roast_private_v1'), isTrue);
        expect(
          storageCalls.where((call) => call.method == 'write'),
          isNotEmpty,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets('$platform opens existing encrypted data automatically', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.runAsync(() async {
        final key = Uint8List.fromList(List.filled(32, 7));
        final repository = await HiveWalletRepository.openWithCipherKey(key);
        await repository.save(
          const WalletVault(accounts: [], nextAccountIndex: 0),
        );
        keys['sygnature_hive_key_v1'] = base64UrlEncode(key);
        await Hive.close();
      });

      await startApp(tester, find.byType(WalletHome));
      expect(Hive.isBoxOpen('sygnature_roast_private_v1'), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('Android creates a device vault without a protection screen', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await startApp(tester, find.byType(OnboardingScreen));
    final store = await tester.runAsync(VaultProtectionStore.open);
    expect(store!.config!.mode, VaultProtectionMode.device);
    expect(
      storageCalls.where((call) {
        final options = (call.arguments as Map)['options'] as Map;
        return options['storageNamespace'] == 'sygnature_device_vault_v1';
      }),
      isNotEmpty,
    );
    expect(find.text('Protect your vault'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });
}
