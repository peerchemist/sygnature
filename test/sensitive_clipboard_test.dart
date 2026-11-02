import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/services/sensitive_clipboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const nativeChannel = MethodChannel('network.noosphere.sygnature/clipboard');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  String? current;

  setUp(() {
    current = null;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': current};
      if (call.method == 'Clipboard.setData') {
        current = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(nativeChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('uses native expiration on Apple platforms', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    MethodCall? invocation;
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      invocation = call;
      return null;
    });
    final clipboard = SensitiveClipboard();
    addTearDown(clipboard.dispose);

    await clipboard.copy(
      'sensitive invitation',
      expiration: const Duration(minutes: 3),
    );

    expect(invocation?.method, 'setSensitiveText');
    expect(invocation?.arguments, {
      'text': 'sensitive invitation',
      'expirationMilliseconds': 180000,
    });
  });

  test('clears an owned invitation when its timer expires', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final clipboard = SensitiveClipboard();
    addTearDown(clipboard.dispose);

    await clipboard.copy('sensitive invitation', expiration: Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(current, isEmpty);
  });

  test('does not erase newer clipboard content', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final clipboard = SensitiveClipboard();
    addTearDown(clipboard.dispose);

    await clipboard.copy('sensitive invitation', expiration: Duration.zero);
    current = 'newer clipboard value';
    await Future<void>.delayed(Duration.zero);

    expect(current, 'newer clipboard value');
  });
}
