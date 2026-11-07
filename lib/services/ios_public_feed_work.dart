import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../storage/public_feed_store.dart';
import 'android_public_feed_work.dart'
    show PublicFeedBackgroundTask, publicFeedWorkTaskName;
import 'app_logger.dart';
import 'public_feed_poller.dart';

const iosPublicFeedWorkId = 'network.noosphere.sygnature.public-feed';
const iosPublicFeedBudget = Duration(seconds: 18);

/// Workmanager retains this dispatcher for release AOT builds and invokes it in
/// a selectively registered headless engine. Task input contains no feed data.
@pragma('vm:entry-point')
void iosPublicFeedWorkDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask((task, input) {
    if (task != iosPublicFeedWorkId) return Future<bool>.value(true);
    return iosPublicFeedWorker(input);
  });
}

@pragma('vm:entry-point')
Future<bool> iosPublicFeedWorker(Map<String, dynamic>? _) async {
  final elapsed = Stopwatch()..start();
  final result = await PublicFeedBackgroundTask(
    registerDartPlugins: false,
    initializationBudget: iosPublicFeedBudget,
    poll: (store, notify) async {
      final remaining = iosPublicFeedBudget - elapsed.elapsed;
      if (remaining <= Duration.zero) return;
      await PublicFeedPoller(
        store,
        notify: notify,
        source: PublicFeedPollSource.background,
        maxDuration: remaining,
        maxPages: 3,
        maxPagesPerFeed: 1,
        connectionTimeout: const Duration(seconds: 5),
        closeTimeout: const Duration(milliseconds: 500),
      ).run();
    },
  ).execute(publicFeedWorkTaskName);
  return result;
}

/// Small injectable adapter around the plugin's static API.
class IosPublicFeedScheduler({Workmanager? workmanager}) {
  final Workmanager _workmanager = workmanager ?? Workmanager();
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    await _workmanager.initialize(iosPublicFeedWorkDispatcher);
    _initialized = true;
  }

  Future<void> schedule() async {
    await _workmanager.registerPeriodicTask(
      iosPublicFeedWorkId,
      publicFeedWorkTaskName,
      frequency: const Duration(hours: 1),
      initialDelay: const Duration(minutes: 15),
    );
  }

  Future<void> cancel() => _workmanager.cancelByUniqueName(iosPublicFeedWorkId);
}

final _scheduler = IosPublicFeedScheduler();
Future<void> _scheduling = Future<void>.value();

/// Re-read subscriptions within the queue so concurrent edits cannot restore a
/// stale schedule. The OS chooses the actual launch time, including no launch.
Future<void> syncIosPublicFeedWork(
  PublicFeedStore store, {
  TargetPlatform? platform,
  bool? isWeb,
  IosPublicFeedScheduler? scheduler,
}) async {
  if ((isWeb ?? kIsWeb) ||
      (platform ?? defaultTargetPlatform) != TargetPlatform.iOS) {
    return;
  }
  final manager = scheduler ?? _scheduler;
  final operation = _scheduling.then((_) async {
    await manager.initialize();
    if (((await store.snapshot())['bindings'] as Map).isEmpty) {
      await manager.cancel();
    } else {
      await manager.schedule();
    }
  });
  // A scheduling failure must not undo a committed subscription or poison the
  // next update. No error payloads: they may contain transport credentials.
  _scheduling = operation.catchError((Object _) {
    AppLogger.warn('Unable to schedule iOS public feed background work');
  });
  await _scheduling;
}

Future<void> initializeIosPublicFeedWork({
  TargetPlatform? platform,
  bool? isWeb,
}) async {
  if ((isWeb ?? kIsWeb) ||
      (platform ?? defaultTargetPlatform) != TargetPlatform.iOS) {
    return;
  }
  final directory = await getApplicationSupportDirectory();
  final store = await PublicFeedStore.open(directory.path);
  try {
    await syncIosPublicFeedWork(store, platform: platform, isWeb: isWeb);
  } finally {
    await store.close();
  }
}
