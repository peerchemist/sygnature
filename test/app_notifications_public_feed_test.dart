import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/services/app_notifications.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const storage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const notifications = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  late List<MethodCall> pluginCalls;
  late List<MethodCall> storageCalls;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    pluginCalls = [];
    storageCalls = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(storage, (
      call,
    ) async {
      storageCalls.add(call);
      final arguments = call.arguments as Map;
      expect(arguments['key'], startsWith('notifications.'));
      expect((arguments['options'] as Map)['enforceBiometrics'], isNot('true'));
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(notifications, (
      call,
    ) async {
      pluginCalls.add(call);
      return true;
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(storage, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      notifications,
      null,
    );
  });

  test('background notification setup never requests permission, keys, biometrics or sounds', () async {
    final delivery = AppNotifications();
    await delivery.initialize(requestPermission: false);
    expect(await delivery.publicFeedRequested(0x40000000, 'signing'), isTrue);
    expect(await delivery.publicFeedRequested(0x40000000, 'signing'), isTrue);
    expect(pluginCalls.map((call) => call.method), [
      'initialize',
      'show',
      'show',
    ]);
    expect(storageCalls.every((call) => call.method == 'read'), isTrue);
    final shows = pluginCalls.where((call) => call.method == 'show');
    for (final call in shows) {
      final args = call.arguments as Map;
      expect(args['id'], 0x40000000);
      expect(args['body'], contains('unlock your wallet'));
      final details = args['platformSpecifics'] as Map;
      expect(details['onlyAlertOnce'], isTrue);
      expect(details['playSound'], isFalse);
    }
    expect(delivery.systemEnabled, isTrue);
    delivery.dispose();
  });

  test(
    'foreground alone can request runtime notification permission',
    () async {
      final delivery = AppNotifications();
      await delivery.initialize();
      expect(
        pluginCalls.map((call) => call.method),
        contains('requestNotificationsPermission'),
      );
      delivery.dispose();
    },
  );

  test('Android accepts notifications that are already enabled', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(storage, (
      call,
    ) async {
      storageCalls.add(call);
      if (call.method == 'read' &&
          (call.arguments as Map)['key'] == 'notifications.desktop_enabled') {
        return 'false';
      }
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(notifications, (
      call,
    ) async {
      pluginCalls.add(call);
      return switch (call.method) {
        'requestNotificationsPermission' => false,
        'areNotificationsEnabled' => true,
        _ => true,
      };
    });

    final delivery = AppNotifications();
    await delivery.initialize();
    expect(await delivery.setSystemEnabled(true), isTrue);
    expect(delivery.systemEnabled, isTrue);
    expect(pluginCalls.map((call) => call.method), [
      'initialize',
      'requestNotificationsPermission',
      'areNotificationsEnabled',
    ]);
    delivery.dispose();
  });

  test(
    'macOS requests permission after initialization returns false',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      MacOSFlutterLocalNotificationsPlugin.registerWith();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(notifications, (
        call,
      ) async {
        pluginCalls.add(call);
        return call.method != 'initialize';
      });

      final delivery = AppNotifications();
      await delivery.initialize();
      expect(delivery.systemEnabled, isTrue);
      expect(pluginCalls.map((call) => call.method), [
        'initialize',
        'requestPermissions',
      ]);
      expect((pluginCalls.last.arguments as Map)['alert'], isTrue);
      delivery.dispose();
    },
  );

  test(
    'macOS can enable a previously disabled notification preference',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      MacOSFlutterLocalNotificationsPlugin.registerWith();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(storage, (
        call,
      ) async {
        storageCalls.add(call);
        return call.method == 'read' &&
                (call.arguments as Map)['key'] ==
                    'notifications.desktop_enabled'
            ? 'false'
            : null;
      });
      binding.defaultBinaryMessenger.setMockMethodCallHandler(notifications, (
        call,
      ) async {
        pluginCalls.add(call);
        return call.method != 'initialize';
      });

      final delivery = AppNotifications();
      await delivery.initialize();
      expect(delivery.systemEnabled, isFalse);
      expect(pluginCalls, isEmpty);
      expect(await delivery.setSystemEnabled(true), isTrue);
      expect(delivery.systemEnabled, isTrue);
      delivery.setSoundEnabled(false);
      expect(await delivery.sendTest(), isTrue);
      expect(pluginCalls.map((call) => call.method), [
        'initialize',
        'requestPermissions',
        'show',
      ]);
      delivery.dispose();
    },
  );

  test('macOS denied permission keeps notifications disabled', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    MacOSFlutterLocalNotificationsPlugin.registerWith();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(notifications, (
      call,
    ) async {
      pluginCalls.add(call);
      return false;
    });

    final delivery = AppNotifications();
    await delivery.initialize();
    expect(delivery.systemEnabled, isFalse);
    expect(await delivery.setSystemEnabled(true), isFalse);
    expect(delivery.systemEnabled, isFalse);
    expect(pluginCalls.map((call) => call.method), [
      'initialize',
      'requestPermissions',
      'requestPermissions',
    ]);
    delivery.dispose();
  });

  test('macOS background initialization does not request permission', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    MacOSFlutterLocalNotificationsPlugin.registerWith();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(notifications, (
      call,
    ) async {
      pluginCalls.add(call);
      return call.method != 'initialize';
    });

    final delivery = AppNotifications();
    await delivery.initialize(requestPermission: false);
    expect(pluginCalls.map((call) => call.method), ['initialize']);
    expect(delivery.systemEnabled, isTrue);
    delivery.dispose();
  });

  test('background plugin failure propagates without persisting a disabled preference', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      notifications,
      (_) async => throw PlatformException(code: 'unavailable'),
    );
    final delivery = AppNotifications();
    await expectLater(
      delivery.initialize(requestPermission: false),
      throwsStateError,
    );
    expect(storageCalls.every((call) => call.method == 'read'), isTrue);
    expect(delivery.systemEnabled, isTrue);
    delivery.dispose();
  });
}
