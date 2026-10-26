import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:sygnature_ng/services/app_logger.dart';

void main() {
  test('redacts supported secret encodings from diagnostic messages', () {
    const mnemonic =
        'abandon abandon abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon about';
    const privateKey =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    const extendedKey =
        'xprv9s21ZrQH143K3abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ123456789';
    const importKey = 'Kx123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqr';
    const invitation = 'sygnature-roast-v1:SECRET-INVITATION';
    const appLink = 'https://noosphere.network/roast#SECRET-HTTPS-INVITATION';

    final redacted = AppLogger.redact(
      'mnemonic="$mnemonic", private_key=$privateKey; '
      '$extendedKey $importKey $invitation $appLink '
      'wss://alice:secret@example.test/socket?token=SECRET-TOKEN',
    );

    expect(redacted, contains('mnemonic=<redacted>'));
    expect(redacted, contains('private_key=<redacted>'));
    expect(redacted, contains('wss://<redacted>@example.test'));
    expect(redacted, contains('token=<redacted>'));
    expect(redacted, isNot(contains(mnemonic)));
    expect(redacted, isNot(contains(privateKey)));
    expect(redacted, isNot(contains(extendedKey)));
    expect(redacted, isNot(contains(importKey)));
    expect(redacted, isNot(contains(invitation)));
    expect(redacted, isNot(contains('SECRET-HTTPS-INVITATION')));
    expect(redacted, isNot(contains('SECRET-TOKEN')));
  });

  test('logger never forwards exception contents or stack traces', () {
    const secret = 'SECRET-EXCEPTION-CONTENTS-MUST-NOT-ESCAPE';
    LogEvent? captured;
    void listener(LogEvent event) => captured = event;
    Logger.addLogListener(listener);
    addTearDown(() => Logger.removeLogListener(listener));

    AppLogger.error(
      'Synthetic failure',
      error: StateError(secret),
      stackTrace: StackTrace.fromString(secret),
    );

    expect(captured, isNotNull);
    expect(captured!.message, contains('failure: StateError'));
    expect(captured!.message.toString(), isNot(contains(secret)));
    expect(captured!.error, isNull);
    expect(captured!.stackTrace, isNull);
  });
}
