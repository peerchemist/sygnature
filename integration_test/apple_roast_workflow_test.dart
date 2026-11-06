// Run through scripts/test_apple_roast.py on dedicated Apple test instances.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:coinlib/coinlib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:integration_test/integration_test.dart';
import 'package:noosphere_flutter/noosphere_flutter.dart';
// Test-only override keeps encrypted Hive state away from real wallets.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sygnature_ng/controllers/wallet_controller.dart';
import 'package:sygnature_ng/main.dart';
import 'package:sygnature_ng/models/roast_setup.dart';
import 'package:sygnature_ng/services/peercoin_network_service.dart';
import 'package:sygnature_ng/services/electrumx_service.dart';
import 'package:sygnature_ng/services/roast_runtime_manager.dart';
import 'package:sygnature_ng/storage/roast_storage.dart';
import 'package:sygnature_ng/storage/wallet_repository.dart';

const _enabled = bool.fromEnvironment('RUN_APPLE_ROAST_WORKFLOW');
const _captureScreenshots = bool.fromEnvironment('CAPTURE_APPLE_SCREENSHOTS');
const _bridge = String.fromEnvironment(
  'APPLE_TEST_BRIDGE',
  defaultValue: 'http://127.0.0.1:8765',
);
const _statement = 'Our shared treasury requires approval from both signers.';

class _IsolatedPaths extends PathProviderPlatform {
  _IsolatedPaths(this.path);
  final String path;
  @override
  Future<String> getApplicationDocumentsPath() async => path;
  @override
  Future<String> getApplicationSupportPath() async => path;
}

Future<dynamic> _exchange(String key, [Object? value]) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.openUrl(
      value == null ? 'GET' : 'POST',
      Uri.parse('$_bridge/$key'),
    );
    if (value != null) {
      final bytes = utf8.encode(jsonEncode(value));
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode != 200) throw StateError(body);
    return jsonDecode(body);
  } finally {
    client.close(force: true);
  }
}

Future<void> _pause(WidgetTester tester, Duration duration) async {
  // A background desktop window may stop receiving vsync frames.
  if (Platform.isMacOS) {
    await Future<void>.delayed(duration);
  } else {
    await tester.pump(duration);
  }
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String phase, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException(phase);
    await _pause(tester, const Duration(milliseconds: 200));
  }
  await _pause(tester, Duration.zero);
  debugPrint('APPLE E2E: $phase');
}

Future<dynamic> _receive(WidgetTester tester, String key) async {
  dynamic value;
  final deadline = DateTime.now().add(const Duration(minutes: 12));
  do {
    value = await _exchange(key);
    if (value != null) return value;
    if (DateTime.now().isAfter(deadline)) throw TimeoutException(key);
    await _pause(tester, const Duration(milliseconds: 500));
  } while (true);
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await _pause(tester, const Duration(milliseconds: 500));
}

Future<void> _capture(
  WidgetTester tester,
  String name, {
  String? section,
}) async {
  if (!_captureScreenshots) return;
  // Approvals can move the dashboard's scroll offset. Frame each release image
  // deliberately instead of retaining the offset used to reach a button.
  if (section != null) {
    final card = find
        .ancestor(of: find.text(section), matching: find.byType(Card))
        .first;
    await tester.ensureVisible(card);
  } else if (name != '05-receive') {
    for (final scrollable in tester.stateList<ScrollableState>(
      find.byType(Scrollable),
    )) {
      if (scrollable.position.axis == Axis.vertical) {
        scrollable.position.jumpTo(0);
      }
    }
  }
  await tester.pump(const Duration(milliseconds: 800));
  await _exchange('capture/$name', {'capture': true});
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Headless macOS can suspend native vsync, including the test framework's
  // final cleanup pump. Warm-up frames keep the desktop test runner responsive.
  final desktopFrames = _enabled && Platform.isMacOS
      ? Timer.periodic(const Duration(milliseconds: 100), (_) {
          binding.scheduleWarmUpFrame();
        })
      : null;
  tearDownAll(() => desktopFrames?.cancel());
  testWidgets(
    'macOS coordinator and iOS signer complete DKG and ROAST',
    (tester) async {
      expect(Platform.isMacOS || Platform.isIOS, isTrue);
      final directory = await Directory.systemTemp.createTemp(
        'sygnature-apple-e2e-',
      );
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _IsolatedPaths(directory.path);
      RoastRuntimeManager? cleanupRuntime;
      WalletController? cleanupController;
      var appMounted = false;
      const storage = FlutterSecureStorage();
      final savedPreferences = <String, String?>{};
      try {
        await NoosphereFlutter.initialize();
        await loadCoinlib();
        final repository = MemoryWalletRepository();
        final persistence = RoastPersistenceFactory(
          cipherKey: Uint8List.fromList(Hive.generateSecureKey()),
        );
        final runtime = cleanupRuntime = RoastRuntimeManager(
          persistence,
          getWalletSeed: () => hexToBytes(repository.value!.rootSeedHex),
        );
        final controller = cleanupController = WalletController(
          repository,
          roastRuntime: runtime,
          roastSigningOperations: persistence,
          networkServiceFactory: (network) =>
              PeercoinElectrumxService.createForPreset(
                PeercoinNetworks.fromWalletNetwork(network),
              ),
        );
        await controller.load();
        if (Platform.isIOS) {
          // Dedicated simulator only: prevent native permission sheets from
          // blocking Flutter controls, then restore the original preferences.
          for (final key in [
            'appearance.theme_mode',
            'notifications.desktop_enabled',
            'notifications.system_preference_set',
          ]) {
            savedPreferences[key] = await storage.read(key: key);
          }
          await storage.write(key: 'appearance.theme_mode', value: 'light');
          await storage.write(
            key: 'notifications.desktop_enabled',
            value: 'false',
          );
          await storage.write(
            key: 'notifications.system_preference_set',
            value: 'true',
          );
        }
        appMounted = true;
        await tester.pumpWidget(
          SygnatureApp(controllerFactory: () async => controller),
        );
        await tester.pump(const Duration(seconds: 1));
        final host = Platform.isMacOS;
        final setupId = await controller.createRoastSetupDraft(
          role: host ? RoastSetupRole.host : RoastSetupRole.member,
          walletName: 'Shared treasury',
          participantName: host ? 'Desktop signer' : 'Mobile signer',
          threshold: 2,
          participantCount: 2,
          network: PeercoinNetworks.testnet,
        );
        RoastSetup setup() => controller.roastSetups.single;
        if (host) {
          await _exchange('mac-ready', true);
          final publicKey = await _receive(tester, 'ios-public-key') as String;
          final invites = await controller.createHostedRoastInvitations(
            setupId,
            [(name: 'Mobile signer', publicKeyHex: publicKey)],
          );
          await _exchange('invitation', invites.single.encoded);
          await _until(
            tester,
            () => controller.onlineSignerCount(setup()) == 2,
            'both signers connected',
          );
          await _exchange('fingerprint', setup().groupFingerprintHex!);
          await controller.startRoastDkg(
            setupId,
            confirmedGroupFingerprintHex: setup().groupFingerprintHex!,
          );
          await _until(tester, () => setup().isActive, 'macOS DKG active');
          await _exchange('group-key', setup().groupKeyHex!);
          await _exchange(
            'group-address',
            controller.selectedAccount!.address!,
          );
          await _receive(tester, 'ios-active');
          final signedFuture = controller.signRoastMessage(
            controller.selectedAccount!,
            text: _statement,
            message: 'Shared treasury policy',
          );
          signedFuture.ignore();
          final signed = await signedFuture;
          final decoded = SignedMessage.fromJsonString(signed.encoded);
          expect(decoded.verify(), isTrue);
          expect(decoded.text, _statement);
          await _exchange('signed-message', jsonDecode(signed.encoded));
          await _receive(tester, 'ios-done');
          await _exchange('mac-passed', true);
        } else {
          await _exchange(
            'ios-public-key',
            controller.participantPublicKey(setupId),
          );
          final invite = await _receive(tester, 'invitation') as String;
          await controller.joinRoastSetup(setupId, invite);
          await _until(
            tester,
            () => setup().pendingDkgProposalHex != null,
            'iOS received DKG proposal',
          );
          expect(
            setup().groupFingerprintHex,
            await _receive(tester, 'fingerprint'),
          );
          await _capture(tester, '01-key-generation');
          await _tap(tester, find.text('Review group manifest'));
          expect(
            find.byKey(const Key('roast-manifest-confirmation')),
            findsOneWidget,
          );
          await _tap(tester, find.byKey(const Key('confirm-roast-manifest')));
          await _until(tester, () => setup().isActive, 'iOS DKG active');
          expect(setup().groupKeyHex, await _receive(tester, 'group-key'));
          expect(controller.selectedAccount!.address, startsWith('tpc1p'));
          expect(
            controller.selectedAccount!.address,
            await _receive(tester, 'group-address'),
          );
          await _capture(tester, '02-shared-wallet');
          await _exchange('ios-active', true);
          await _until(
            tester,
            () => controller.roastSigningRequests.isNotEmpty,
            'iOS received signing request',
          );
          expect(
            controller.roastSigningRequests.single.request.signedMessageText,
            _statement,
          );
          await _capture(tester, '03-signing-request');
          await _tap(tester, find.text('Approve and sign'));
          final encoded = await _receive(tester, 'signed-message');
          expect(
            SignedMessage.fromJson(encoded as Map<String, dynamic>).verify(),
            isTrue,
          );
          await _until(
            tester,
            () => controller.roastSigningRequests.isEmpty,
            'completed request removed',
          );
          await _capture(
            tester,
            '04-recent-activity',
            section: 'Recent activity',
          );
          await _capture(tester, '08-wallet-balance', section: 'BALANCE');
          await _tap(tester, find.byTooltip('Show address QR code'));
          expect(find.byKey(const Key('share-qr-code')), findsOneWidget);
          await _capture(tester, '05-receive');
          await _tap(tester, find.text('Close'));
          final settings = find.byTooltip('Settings');
          await _tap(
            tester,
            settings.evaluate().isNotEmpty ? settings : find.text('Settings'),
          );
          await _capture(tester, '06-settings');
          await _tap(tester, find.text('Dark'));
          await _tap(tester, find.byTooltip('Back'));
          await _capture(tester, '07-dark-wallet', section: 'BALANCE');
          await _exchange('ios-done', true);
        }
        expect(tester.takeException(), isNull);
      } finally {
        try {
          // Await native shutdown before closing the encrypted Hive boxes.
          // Disposing the app afterwards may close the already-stopped runtime.
          await cleanupRuntime?.close();
        } finally {
          try {
            if (appMounted) {
              await tester.pumpWidget(const SizedBox.shrink());
              await _pause(tester, Duration.zero);
            } else {
              cleanupController?.dispose();
            }
          } finally {
            try {
              await Hive.close();
            } finally {
              PathProviderPlatform.instance = previousPaths;
              try {
                if (await directory.exists()) {
                  await directory.delete(recursive: true);
                }
              } finally {
                for (final entry in savedPreferences.entries) {
                  if (entry.value == null) {
                    await storage.delete(key: entry.key);
                  } else {
                    await storage.write(key: entry.key, value: entry.value);
                  }
                }
              }
            }
          }
        }
      }
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 18)),
  );
}
