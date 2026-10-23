import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/services/android_public_feed_work.dart';
import 'package:sygnature_ng/services/public_feed_notifications.dart';
import 'package:sygnature_ng/services/public_feed_poller.dart';
import 'package:sygnature_ng/storage/public_feed_store.dart';
import 'package:workmanager/workmanager.dart';

import 'public_feed_poller_test.dart' show FakeConnection, feedId, page, entry;

class RecordingNotifications extends PublicFeedNotifications {
  var initializations = 0;
  bool fail = false;
  bool interruptDelivery = false;
  final shown = <int>[];

  @override
  Future<bool> publicFeedRequested(int id, String category) async {
    shown.add(id);
    if (interruptDelivery) throw StateError('Worker interrupted after display');
    return true;
  }

  @override
  Future<void> initialize() async {
    initializations++;
    if (fail) throw MissingPluginException();
  }
}

class RecordingWorkmanager implements Workmanager {
  final calls = <Invocation>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation);
    return Future<void>.value();
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late RecordingNotifications notifications;
  late List<String> calls;

  PublicFeedBackgroundTask task({
    Future<void> Function()? plugins,
    Future<void> Function()? native,
    Future<PublicFeedStore> Function(String)? open,
    PublicFeedNotifications Function()? notificationFactory,
    PublicFeedBackgroundPoll? poll,
  }) => PublicFeedBackgroundTask(
    initializePlugins:
        plugins ??
        () async {
          calls.add('plugins');
        },
    initializeNative:
        native ??
        () async {
          calls.add('native');
        },
    supportDirectory: () async => directory,
    openStore: open ?? PublicFeedStore.open,
    notifications: notificationFactory ?? () => notifications,
    poll:
        poll ??
        (store, notify) => PublicFeedPoller(
          store,
          notify: notify,
          source: PublicFeedPollSource.background,
        ).run(),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('public-feed-worker-');
    notifications = RecordingNotifications();
    calls = [];
  });
  tearDown(() => directory.delete(recursive: true));

  test('known background task initializes public dependencies and invokes one bounded run', () async {
    var runs = 0;
    expect(
      await task(
        poll: (store, notify) async {
          runs++;
          final poller = PublicFeedPoller(store, notify: notify);
          expect(poller.maxDuration, const Duration(seconds: 45));
          expect(poller.maxPages, 5);
          await poller.run();
        },
      ).execute(publicFeedWorkTaskName),
      isTrue,
    );
    expect(runs, 1);
    expect(calls, ['plugins', 'native']);
    expect(notifications.initializations, 1);
    final reopened = await PublicFeedStore.open(directory.path);
    expect((await reopened.snapshot())['pollingLease'], isNull);
    await reopened.close();
    final source = File('lib/services/android_public_feed_work.dart')
        .readAsStringSync();
    for (final forbidden in [
      'WalletController',
      'RoastRuntimeManager',
      'NoosphereFlutter',
      'vault_protection',
      'wallet_repository',
      'roast_storage',
      'mnemonic',
      'runApp(',
    ]) {
      expect(source, isNot(contains(forbidden)));
    }
    expect(source, contains("@pragma('vm:entry-point')"));
    expect(source, contains('DartPluginRegistrant.ensureInitialized()'));
    expect(source, contains('loadCoinlib()'));
    expect(source, contains('initializePublicFeedNative()'));
  });

  test('unknown names are successful no-ops without plugin or store initialization', () async {
    expect(
      await task(open: (_) => throw StateError('must not open'))
          .execute('unknown'),
      isTrue,
    );
    expect(calls, isEmpty);
    expect(notifications.initializations, 0);
  });

  test('no subscriptions is a successful no-op', () async {
    expect(await task().execute(publicFeedWorkTaskName), isTrue);
    final store = await PublicFeedStore.open(directory.path);
    expect((await store.snapshot())['polls']['background'], isNotNull);
    await store.close();
  });

  test(
    'locked worker reads the public feed, posts its notification and completes',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      const storage = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      const notificationPlugin = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      final storageCalls = <MethodCall>[];
      final pluginCalls = <MethodCall>[];

      binding.defaultBinaryMessenger.setMockMethodCallHandler(storage, (
        call,
      ) async {
        storageCalls.add(call);
        throw PlatformException(
          code: 'device_locked',
          message: 'Failed to unwrap key',
        );
      });
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        notificationPlugin,
        (call) async {
          pluginCalls.add(call);
          return true;
        },
      );
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        binding.defaultBinaryMessenger.setMockMethodCallHandler(storage, null);
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          notificationPlugin,
          null,
        );
      });

      final store = await PublicFeedStore.open(directory.path);
      final key = await store.subscribe(
        groupId: 'g',
        address: 'address',
        pin: 'pin',
        feedId: feedId.hex,
      );
      await store.commitPage(key, page(0, 0), DateTime.now());
      await store.close();

      final worker = task(
        notificationFactory: PublicFeedNotifications.new,
        poll: (store, notify) => PublicFeedPoller(
          store,
          notify: notify,
          connect: (_) async => FakeConnection(
            (cursor) async => page(cursor, 1, entries: [entry(1)]),
          ),
        ).run(),
      );

      expect(await worker.execute(publicFeedWorkTaskName), isTrue);
      expect(storageCalls, isEmpty);
      expect(pluginCalls.map((call) => call.method), ['initialize', 'show']);
    },
  );

  for (final stage in ['plugins', 'native', 'store', 'notifications', 'poll']) {
    test('$stage infrastructure failure requests retry', () async {
      Future<void> fail() async => throw MissingPluginException();
      notifications.fail = stage == 'notifications';
      expect(
        await task(
          plugins: stage == 'plugins' ? fail : null,
          native: stage == 'native' ? fail : null,
          open: stage == 'store'
              ? (_) async => throw const FileSystemException()
              : null,
          poll: stage == 'poll' ? (_, _) => fail() : null,
        ).execute(publicFeedWorkTaskName),
        isFalse,
      );
    });
  }

  test('expected transport failure persists backoff and returns success without a retry storm', () async {
    final store = await PublicFeedStore.open(directory.path);
    final key = await store.subscribe(
      groupId: 'g',
      address: 'address',
      pin: 'pin',
      feedId: feedId.hex,
    );
    await store.close();
    var connections = 0;
    final worker = task(
      poll: (store, notify) => PublicFeedPoller(
        store,
        notify: notify,
        connect: (_) async {
          connections++;
          throw const SocketException(
            'sensitive capability must never be logged',
          );
        },
      ).run(),
    );
    expect(await worker.execute(publicFeedWorkTaskName), isTrue);
    expect(await worker.execute(publicFeedWorkTaskName), isTrue);
    expect(connections, 1);
    final inspect = await PublicFeedStore.open(directory.path);
    final feed = ((await inspect.snapshot())['feeds'] as Map)[key] as Map;
    expect(feed['cursor'], 0);
    expect(feed['failures'], 1);
    expect(feed['retryAt'], isNotNull);
    await inspect.close();
  });

  test(
    'worker interruption reuses the committed outbox notification ID',
    () async {
      var store = await PublicFeedStore.open(directory.path);
      final key = await store.subscribe(
        groupId: 'g',
        address: 'address',
        pin: 'pin',
        feedId: feedId.hex,
      );
      await store.commitPage(key, page(0, 0), DateTime.now());
      await store.commitPage(
        key,
        page(0, 1, entries: [entry(1)]),
        DateTime.now(),
      );
      await store.close();
      PublicFeedBackgroundTask worker() => task(
        poll: (store, notify) => PublicFeedPoller(
          store,
          notify: notify,
          connect: (_) async => throw const SocketException('offline'),
        ).run(),
      );
      notifications.interruptDelivery = true;
      expect(await worker().execute(publicFeedWorkTaskName), isTrue);
      final firstId = notifications.shown.single;
      store = await PublicFeedStore.open(directory.path);
      expect((await store.snapshot())['feeds'][key]['outbox'].length, 1);
      await store.retry(key);
      await store.close();
      notifications = RecordingNotifications();
      expect(await worker().execute(publicFeedWorkTaskName), isTrue);
      expect(notifications.shown, [firstId]);
      store = await PublicFeedStore.open(directory.path);
      expect((await store.snapshot())['feeds'][key]['outbox'], isEmpty);
      await store.close();
    },
  );

  test('an occupied global lease is success without connecting', () async {
    final store = await PublicFeedStore.open(directory.path);
    final owner = await store.acquirePollingLease();
    expect(
      await task(
        poll: (store, notify) => PublicFeedPoller(
          store,
          notify: notify,
          connect: (_) async => throw StateError('lease is held'),
        ).run(),
      ).execute(publicFeedWorkTaskName),
      isTrue,
    );
    expect((await store.snapshot())['pollingLease'], isNotNull);
    await store.releasePollingLease(owner!);
    await store.close();
  });

  test('Android startup updates one unique connected periodic task without inputData', () async {
    final manager = RecordingWorkmanager();
    for (var launch = 0; launch < 2; launch++) {
      await initializeAndroidPublicFeedWork(
        platform: TargetPlatform.android,
        isWeb: false,
        workmanager: manager,
      );
    }
    expect(manager.calls.map((call) => call.memberName), [
      #initialize,
      #registerPeriodicTask,
      #initialize,
      #registerPeriodicTask,
    ]);
    for (final call in manager.calls.where(
      (call) => call.memberName == #registerPeriodicTask,
    )) {
      expect(call.positionalArguments, [
        publicFeedWorkUniqueName,
        publicFeedWorkTaskName,
      ]);
      expect(call.namedArguments[#frequency], const Duration(minutes: 15));
      expect(
        call.namedArguments[#existingWorkPolicy],
        ExistingPeriodicWorkPolicy.update,
      );
      final constraints = call.namedArguments[#constraints] as Constraints;
      expect(constraints.networkType, NetworkType.connected);
      expect(constraints.requiresCharging, isNot(true));
      expect(constraints.requiresDeviceIdle, isNot(true));
      expect(call.namedArguments[#inputData], isNull);
      expect(call.namedArguments[#foregroundServiceConfig], isNull);
    }
  });

  test('all non-Android platforms and web register no work', () async {
    final manager = RecordingWorkmanager();
    for (final platform in TargetPlatform.values) {
      if (platform == TargetPlatform.android) continue;
      await initializeAndroidPublicFeedWork(
        platform: platform,
        isWeb: false,
        workmanager: manager,
      );
    }
    await initializeAndroidPublicFeedWork(
      platform: TargetPlatform.android,
      isWeb: true,
      workmanager: manager,
    );
    expect(manager.calls, isEmpty);
  });
}
