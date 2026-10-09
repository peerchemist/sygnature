import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/storage/vault_protection.dart';
import 'package:sygnature_ng/ui/app_theme.dart';
import 'package:sygnature_ng/ui/vault_protection_screen.dart';

void main() {
  group('vault password protection', () {
    const config = VaultProtectionConfig(
      mode: VaultProtectionMode.password,
      salt: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      iterations: 1,
      memoryPowerOfTwo: 8,
    );

    test('derives stable, domain-separated keys', () {
      final first = deriveVaultKeyMaterialSync('correct horse', config);
      final second = deriveVaultKeyMaterialSync('correct horse', config);
      final different = deriveVaultKeyMaterialSync('wrong horse', config);

      expect(first.walletKey, orderedEquals(second.walletKey));
      expect(first.roastKey, orderedEquals(second.roastKey));
      expect(first.walletKey, isNot(orderedEquals(first.roastKey)));
      expect(first.walletKey, isNot(orderedEquals(different.walletKey)));
      expect(first.walletKey, hasLength(32));
      expect(first.roastKey, hasLength(32));
      final configured = config.withVerifier(first.verifier);
      expect(configured.matchesVerifier(second.verifier), isTrue);
      expect(configured.matchesVerifier(different.verifier), isFalse);
    });

    test('serializes its non-secret KDF settings', () {
      final configured = config.withVerifier(Uint8List(32));
      final restored = VaultProtectionConfig.fromJson(configured.toJson());

      expect(restored.mode, VaultProtectionMode.password);
      expect(restored.salt, config.salt);
      expect(restored.iterations, config.iterations);
      expect(restored.memoryPowerOfTwo, config.memoryPowerOfTwo);
      expect(base64Url.decode(restored.salt!), hasLength(32));
      expect(restored.matchesVerifier(Uint8List(32)), isTrue);
      expect(
        restored.matchesVerifier(
          Uint8List.fromList([1, ...List.filled(31, 0)]),
        ),
        isFalse,
      );
    });
  });

  test('trusts the system keyring on every desktop platform', () {
    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    ]) {
      expect(desktopVaultAvailable(web: false, platform: platform), isTrue);
    }
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      expect(desktopVaultAvailable(web: false, platform: platform), isFalse);
    }
    expect(
      desktopVaultAvailable(web: true, platform: TargetPlatform.linux),
      isFalse,
    );
  });

  testWidgets('offers password protection while disabling macOS system vault', (
    tester,
  ) async {
    String? password;
    var systemSelections = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: VaultProtectionScreen(
          setup: true,
          systemVaultEnabled: false,
          onSystem: () async {
            systemSelections++;
          },
          onPassword: (value) async {
            password = value;
          },
        ),
      ),
    );

    expect(
      find.text(
        'Unavailable on macOS builds distributed without Keychain access.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('system-vault-option')));
    expect(systemSelections, 0);

    await tester.enterText(find.byKey(const Key('vault-password')), 'eight123');
    await tester.enterText(
      find.byKey(const Key('vault-password-confirmation')),
      'eight123',
    );
    final submit = find.byKey(const Key('vault-protection-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pump();

    expect(password, 'eight123');
  });
}
