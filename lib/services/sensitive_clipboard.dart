import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const sensitiveClipboardExpiration = Duration(minutes: 5);

final sensitiveClipboard = SensitiveClipboard();

/// Copies capability-bearing text and removes it without overwriting newer
/// clipboard content.
///
/// Apple platforms provide stronger native behavior: iOS attaches a system
/// expiry to the pasteboard item, while macOS tracks pasteboard ownership and
/// also clears the item when the app terminates.
final class SensitiveClipboard {
  static const _channel = MethodChannel(
    'network.noosphere.sygnature/clipboard',
  );

  Timer? _expirationTimer;

  Future<void> copy(
    String text, {
    Duration expiration = sensitiveClipboardExpiration,
  }) async {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      await _channel.invokeMethod<void>('setSensitiveText', {
        'text': text,
        'expirationMilliseconds': expiration.inMilliseconds,
      });
      return;
    }

    await Clipboard.setData(ClipboardData(text: text));
    _expirationTimer?.cancel();
    _expirationTimer = Timer(expiration, () => unawaited(_clearIfOwned(text)));
  }

  Future<void> _clearIfOwned(String text) async {
    try {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == text) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    } on Object {
      // Clipboard access is best-effort on platforms that require a user
      // gesture. Never surface an asynchronous cleanup failure to the user.
    }
  }

  void dispose() {
    _expirationTimer?.cancel();
    _expirationTimer = null;
  }
}
