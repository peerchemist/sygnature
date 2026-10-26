import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/services/roast_runtime_manager.dart';

void main() {
  test('ROAST invitation app links round trip through the verified domain', () {
    const invitation = 'sygnature-roast-v1:invite_payload';
    const appLink = 'https://noosphere.network/roast#invite_payload';

    expect(sygnatureRoomInviteLink(invitation), appLink);
    expect(normalizeSygnatureRoomInvite(appLink), invitation);
    expect(normalizeSygnatureRoomInvite(invitation), invitation);
  });

  test('ROAST invitation app links require the exact HTTPS endpoint', () {
    for (final invalid in [
      'http://noosphere.network/roast#payload',
      'https://example.com/roast#payload',
      'https://noosphere.network/other#payload',
      'https://noosphere.network/roast?invite=payload',
      'https://noosphere.network/roast',
    ]) {
      expect(
        () => normalizeSygnatureRoomInvite(invalid),
        throwsFormatException,
        reason: invalid,
      );
    }
  });
}
