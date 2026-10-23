import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/services/app_notifications.dart';
import 'package:sygnature_ng/services/public_feed_notifications.dart';
import 'package:sygnature_ng/services/ui_sounds.dart';

class _RecordingUiSounds extends UiSounds {
  final cues = <UiSoundCue>[];

  @override
  void coinsReceived({double volume = 0.5}) =>
      cues.add(UiSoundCue.coinsReceived);

  @override
  void signingRequest({double volume = 0.5}) =>
      cues.add(UiSoundCue.signingRequest);

  @override
  void dkgRequest({double volume = 0.5}) => cues.add(UiSoundCue.dkgRequest);

  @override
  void roastGroupCreated({double volume = 0.5}) =>
      cues.add(UiSoundCue.roastGroupCreated);

  @override
  void notificationTest({double volume = 0.5}) =>
      cues.add(UiSoundCue.notificationTest);

  @override
  Future<void> dispose() async {}
}

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

  test(
    'locked background notification delivery never opens secure storage',
    () async {
      final foreground = AppNotifications();
      await foreground.initialize();
      foreground.dispose();

      pluginCalls.clear();
      storageCalls.clear();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(storage, (
        call,
      ) async {
        storageCalls.add(call);
        throw PlatformException(
          code: 'device_locked',
          message: 'Failed to unwrap key',
        );
      });

      final background = PublicFeedNotifications();
      await background.initialize();
      expect(
        await background.publicFeedRequested(0x40000000, 'signing'),
        isTrue,
      );
      expect(
        await background.publicFeedRequested(0x40000000, 'signing'),
        isTrue,
      );
      expect(pluginCalls.map((call) => call.method), [
        'initialize',
        'show',
        'show',
      ]);
      expect(storageCalls, isEmpty);
      final shows = pluginCalls.where((call) => call.method == 'show');
      for (final call in shows) {
        final args = call.arguments as Map;
        expect(args['id'], 0x40000000);
        expect(args['body'], contains('unlock your wallet'));
        expect(args['payload'], 'public-feed:signing');
        final details = args['platformSpecifics'] as Map;
        expect(details['onlyAlertOnce'], isTrue);
        expect(details['playSound'], isFalse);
      }
    },
  );

  test('foreground wallet events use distinct generated sound cues', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(storage, (
      call,
    ) async {
      storageCalls.add(call);
      return switch ((call.arguments as Map)['key']) {
        'notifications.desktop_enabled' => 'false',
        'notifications.system_preference_set' => 'true',
        _ => null,
      };
    });
    final sounds = _RecordingUiSounds();
    final delivery = AppNotifications(sounds: sounds);
    await delivery.initialize();

    delivery.coinsReceived();
    delivery.roastSigningRequest();
    delivery.dkgRequest();
    delivery.roastGroupCreated();
    expect(await delivery.sendTest(), isFalse);

    expect(sounds.cues, UiSoundCue.values);
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

  test('notification launch suppresses its matching runtime alert once', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(notifications, (
      call,
    ) async {
      pluginCalls.add(call);
      if (call.method == 'getNotificationAppLaunchDetails') {
        return {
          'notificationLaunchedApp': true,
          'notificationResponse': {
            'notificationId': 1,
            'notificationResponseType': 0,
            'payload': 'public-feed:signing',
          },
        };
      }
      return true;
    });
    final categories = <String>[];
    final sounds = _RecordingUiSounds();
    final delivery = AppNotifications(
      sounds: sounds,
      onPublicFeedOpened: categories.add,
    );

    await delivery.initialize();
    delivery.roastSigningRequest();
    delivery.dkgRequest();
    delivery.roastSigningRequest();

    expect(categories, ['signing']);
    expect(sounds.cues, [UiSoundCue.dkgRequest, UiSoundCue.signingRequest]);
    expect(pluginCalls.map((call) => call.method), [
      'initialize',
      'getNotificationAppLaunchDetails',
      'requestNotificationsPermission',
    ]);
    delivery.dispose();
  });

  test(
    'Android restores an automatically disabled notification setting',
    () async {
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
      expect(delivery.systemEnabled, isTrue);
      expect(pluginCalls.map((call) => call.method), [
        'initialize',
        'areNotificationsEnabled',
      ]);
      delivery.dispose();
    },
  );

  test('Android notices permission granted while the app was paused', () async {
    var notificationsEnabled = false;
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
      return call.method == 'areNotificationsEnabled'
          ? notificationsEnabled
          : true;
    });

    final delivery = AppNotifications();
    await delivery.initialize();
    expect(delivery.systemEnabled, isFalse);
    expect(await delivery.systemPermissionGranted(), isFalse);

    notificationsEnabled = true;
    await delivery.refreshSystemPermission();
    expect(delivery.systemEnabled, isTrue);
    expect(await delivery.systemPermissionGranted(), isTrue);
    expect(pluginCalls.map((call) => call.method), [
      'initialize',
      'areNotificationsEnabled',
      'areNotificationsEnabled',
      'areNotificationsEnabled',
      'areNotificationsEnabled',
    ]);
    delivery.dispose();
  });

  test(
    'Android preserves a notification setting disabled by the user',
    () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(storage, (
        call,
      ) async {
        storageCalls.add(call);
        return switch ((call.arguments as Map)['key']) {
          'notifications.desktop_enabled' => 'false',
          'notifications.system_preference_set' => 'true',
          _ => null,
        };
      });

      final delivery = AppNotifications();
      await delivery.initialize();
      expect(delivery.systemEnabled, isFalse);
      expect(pluginCalls, isEmpty);
      delivery.dispose();
    },
  );

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
